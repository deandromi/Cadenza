import Accelerate
import CadenzaCore
import CoreML
import Foundation
import QuartzCore

/// Everything the background inference needs, built once and then only read.
final class InferenceContext: @unchecked Sendable {
    private let model: MLModel
    private let mel: MelFrontEnd
    private let heads: AttributeHeads

    init(tensorsDir: URL, modelURL: URL) throws {
        mel = try MelFrontEnd(tensorsDir: tensorsDir)
        heads = try AttributeHeads(tensorsDir: tensorsDir)
        let compiled = try MLModel.compileModel(at: modelURL)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = Self.computeUnits
        model = try MLModel(contentsOf: compiled, configuration: configuration)
    }

    /// The compute-unit choice for the backbone, measured with the replay
    /// harness on this machine: gpu median 0,73 s per window versus 1,02 s
    /// cpuOnly, and the neural engine is slower still and returns phantom
    /// onsets in bulk. GPU is the default; CADENZA_COMPUTE_UNITS overrides
    /// (cpuOnly, cpuAndNE, all).
    static var computeUnits: MLComputeUnits {
        switch ProcessInfo.processInfo.environment["CADENZA_COMPUTE_UNITS"] {
        case "cpuOnly": return .cpuOnly
        case "cpuAndNE": return .cpuAndNeuralEngine
        case "all": return .all
        default: return .cpuAndGPU
        }
    }

    /// Decodes one window ending at `edgeSeconds` content time: resamples to
    /// exactly one segment, computes mel features, runs the backbone, walks
    /// the forced-start viterbi and refines every interval with the attribute
    /// heads. Events come back sorted by (onset, offset, pitch). The plan
    /// picks the tier's geometry and its matching model output shapes.
    func run(windowIndex: Int, edgeSeconds: Double, samples: [Float], deviceRate: Double, forcedStartPos: [Int], plan: WindowPlan) -> WindowResult? {
        let decodeStart = CACurrentMediaTime()
        let at44100: [Float]
        if abs(deviceRate - WindowGeometry.sampleRate) < 1 {
            at44100 = samples
        } else if let converted = Resampler.convert(samples, from: deviceRate, to: WindowGeometry.sampleRate) {
            at44100 = converted
        } else {
            return nil
        }
        if at44100.count < MelFrontEnd.hopSize { return nil }
        let melStart = CACurrentMediaTime()
        let frames = mel.compute(Self.alignToSegment(at44100, plan: plan))
        let melWall = CACurrentMediaTime() - melStart
        let t = frames.count / (MelFrontEnd.nMels * MelFrontEnd.nChannels)
        guard t > 1 else { return nil }

        guard let features = try? MLMultiArray(
            shape: [1, t, MelFrontEnd.nMels, MelFrontEnd.nChannels] as [NSNumber],
            dataType: .float32) else { return nil }
        let destination = features.dataPointer.assumingMemoryBound(to: Float.self)
        frames.withUnsafeBufferPointer { pointer in
            destination.update(from: pointer.baseAddress!, count: frames.count)
        }
        let predStart = CACurrentMediaTime()
        guard let prediction = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["mel": features])),
              let scoreArray = prediction.featureValue(for: "S")?.multiArrayValue,
              let skipArray = prediction.featureValue(for: "S_skip")?.multiArrayValue,
              let contextArray = prediction.featureValue(for: "ctx")?.multiArrayValue else { return nil }
        let predWall = CACurrentMediaTime() - predStart

        let symbolCount = WindowGeometry.symbols.count
        // the score tensor is 172 MB for a 16 s window: read it in place
        // rather than copying it once per decode
        let score = UnsafeBufferPointer(
            start: scoreArray.dataPointer.assumingMemoryBound(to: Float.self),
            count: scoreArray.count)
        let skip = UnsafeBufferPointer(
            start: skipArray.dataPointer.assumingMemoryBound(to: Float.self),
            count: skipArray.count)
        let context = UnsafeBufferPointer(
            start: contextArray.dataPointer.assumingMemoryBound(to: Float.self),
            count: contextArray.count)
        let crfStart = CACurrentMediaTime()
        // every symbol's suffix DP is independent: spread them over the cores
        var intervals = [[FrameInterval]](repeating: [], count: symbolCount)
        DispatchQueue.concurrentPerform(iterations: symbolCount) { symbol in
            intervals[symbol] = SemiCRFDecoder.decodeSymbol(
                score: score, skip: skip, T: t, P: symbolCount,
                p: symbol, start: forcedStartPos[symbol])
        }
        let crfWall = CACurrentMediaTime() - crfStart

        let beginTime = edgeSeconds - plan.segmentSeconds
        var lastP = [Int](repeating: 0, count: symbolCount)
        var perSymbolEvents = [[WindowResult.Event]](repeating: [], count: symbolCount)
        DispatchQueue.concurrentPerform(iterations: symbolCount) { symbol in
            let pitch = WindowGeometry.symbols[symbol]
            guard (21...108).contains(pitch) else { return }
            var events: [WindowResult.Event] = []
            var symbolLastP = 0
            var lastEnd = 0.0
            for interval in intervals[symbol] {
                var attributes = [Float](repeating: 0, count: 768)
                let aBase = (symbol * t + interval.start) * 256
                let bBase = (symbol * t + interval.end) * 256
                for d in 0..<256 {
                    let a = context[aBase + d]
                    let b = context[bBase + d]
                    attributes[d] = a
                    attributes[256 + d] = b
                    attributes[512 + d] = a * b
                }
                let velocityLogits = heads.velocityLogits(attributes)
                var velocity = 0
                var best: Float = -.infinity
                for i in 0..<128 where velocityLogits[i] > best {
                    best = velocityLogits[i]
                    velocity = i
                }
                let refined = heads.refinedOF(attributes)
                let onsetShift = Self.offsetValue(refined[0]) * plan.frameDuration
                let offsetShift = Self.offsetValue(refined[1]) * plan.frameDuration
                let presenceOnset = refined[2] > 0
                let presenceOffset = refined[3] > 0

                var onset = beginTime + Double(interval.start) * plan.frameDuration + onsetShift
                var offset = beginTime + Double(interval.end) * plan.frameDuration + offsetShift
                onset = max(onset, lastEnd)
                offset = max(offset, onset + 1e-8)
                lastEnd = offset

                events.append(WindowResult.Event(
                    pitch: pitch, velocity: velocity,
                    startFrame: interval.start, endFrame: interval.end,
                    onsetSeconds: onset, offsetSeconds: offset,
                    hasOnset: interval.start > 0 || presenceOnset,
                    hasOffset: interval.end < plan.lastFrameIdx || presenceOffset))
                if interval.end < plan.lastFrameIdx || presenceOffset {
                    symbolLastP = interval.end
                }
            }
            perSymbolEvents[symbol] = events
            lastP[symbol] = symbolLastP
        }
        var events = perSymbolEvents.flatMap { $0 }
        events.sort { a, b in
            if a.onsetSeconds != b.onsetSeconds { return a.onsetSeconds < b.onsetSeconds }
            if a.offsetSeconds != b.offsetSeconds { return a.offsetSeconds < b.offsetSeconds }
            return a.pitch < b.pitch
        }
        let headsWall = CACurrentMediaTime() - decodeStart - melWall - predWall - crfWall
        print("[inference] window \(windowIndex): \(events.count) events decoded in \(String(format: "%.2f", CACurrentMediaTime() - decodeStart)) s "
            + "(mel \(String(format: "%.2f", melWall)), model \(String(format: "%.2f", predWall)), crf \(String(format: "%.2f", crfWall)), heads \(String(format: "%.2f", headsWall)), units \(Self.computeUnits))")
        return WindowResult(windowIndex: windowIndex, beginSeconds: beginTime, events: events, lastP: lastP)
    }

    private func copy(_ array: MLMultiArray) -> [Float] {
        array.dataPointer.withMemoryRebound(to: Float.self, capacity: array.count) {
            Array(UnsafeBufferPointer(start: $0, count: array.count))
        }
    }

    private static func offsetValue(_ logit: Float) -> Double {
        let value = (AttributeHeads.continuousBernoulliMean(logit: logit) - 0.5) / 0.99
        return Double(max(-0.5, min(0.5, value)))
    }

    private static func alignToSegment(_ input: [Float], plan: WindowPlan) -> [Float] {
        var out = input
        if out.count > plan.segmentSamples {
            out.removeLast(out.count - plan.segmentSamples)
        } else if out.count < plan.segmentSamples {
            out.append(contentsOf: [Float](repeating: 0, count: plan.segmentSamples - out.count))
        }
        return out
    }

    static func resample(_ input: [Float], from: Double, to: Double) -> [Float]? {
        Resampler.convert(input, from: from, to: to)
    }
}
