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
    /// extends decoded note ends to where the audio actually stops sounding;
    /// the backbone undershoots short and mid-length notes by hundreds of ms
    private let refiner = NoteLengthRefiner()
    /// finds the bass notes the model is blind to, from the signal itself
    private let bassDetector = LowRegisterDetector()
    /// Off by default, and measured off: with recorded piano samples the
    /// model finds a lone C1, a G1 at v40 and at v90, C2, D2 and low chords
    /// without help (15 of 16 notes, F1 0.938), so the fallback is not needed
    /// for real timbre and it costs a fifth of a second per window. It stays
    /// behind CDZ_LOW=1 for material whose bass the model really does drop,
    /// which so far is only the harness synth's bare harmonic stacks.
    /// Measured cost of leaving it on: the attribute stage runs 0.18 s per
    /// window against 0.16 s without, so this is about tidiness and trust,
    /// not latency.
    private static let detectsBass = ProcessInfo.processInfo.environment["CDZ_LOW"] == "1"
    /// CDZ_REFINER=0 turns the audio-evidence length pass off, for A/B runs
    private static let refinesLengths = ProcessInfo.processInfo.environment["CDZ_REFINER"] != "0"

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
    /// Onset-score bias for threshold studies, in logit units; nil (unset)
    /// leaves the model's own calibration alone.
    static let onsetBias: Float? = ProcessInfo.processInfo.environment["CADENZA_ONSET_BIAS"]
        .flatMap { Float($0) }

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
        // A study knob, not a product setting: shifting every diagonal of the
        // score tensor moves the semi-CRF's own onset decision without
        // touching the model, which is exactly what a threshold study needs.
        // Unset means the model's own calibration.
        if let bias = Self.onsetBias, bias != 0 {
            let mutable = UnsafeMutableBufferPointer(
                start: UnsafeMutablePointer(mutating: score.baseAddress!), count: score.count)
            for frame in 0..<t {
                let base = (frame * t + frame) * symbolCount
                for symbol in 0..<symbolCount {
                    mutable[base + symbol] += bias
                }
            }
        }
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
        if Self.refinesLengths {
            events = Self.refinedByAudio(events, samples: at44100, windowBegin: beginTime,
                                         frameDuration: plan.frameDuration, refiner: refiner)
        }
        if Self.detectsBass {
            events = Self.bassNotes(events, samples: at44100, windowBegin: beginTime,
                                    detector: bassDetector)
        }
        let headsWall = CACurrentMediaTime() - decodeStart - melWall - predWall - crfWall
        print("[inference] window \(windowIndex): \(events.count) events decoded in \(String(format: "%.2f", CACurrentMediaTime() - decodeStart)) s "
            + "(mel \(String(format: "%.2f", melWall)), model \(String(format: "%.2f", predWall)), crf \(String(format: "%.2f", crfWall)), heads \(String(format: "%.2f", headsWall)), units \(Self.computeUnits))")
        return WindowResult(windowIndex: windowIndex, beginSeconds: beginTime, events: events, lastP: lastP)
    }

    /// Runs the audio-evidence length refiner over one window's events.
    /// Continuations (intervals that start at the window edge because the
    /// note began earlier) are left alone: their attack is not in this audio,
    /// so there is no peak to measure a tail against.
    private static func refinedByAudio(
        _ events: [WindowResult.Event],
        samples: [Float],
        windowBegin: Double,
        frameDuration: Double,
        refiner: NoteLengthRefiner
    ) -> [WindowResult.Event] {
        guard !events.isEmpty else { return events }
        let spans = events.map { event in
            NoteLengthRefiner.Span(pitch: event.pitch, onset: event.onsetSeconds,
                                   offset: event.offsetSeconds, hasOffset: event.hasOffset)
        }
        let refined = refiner.refine(spans, samples: samples, windowBegin: windowBegin)
        guard refined.count == events.count else { return events }
        var result = events
        for index in events.indices where refined[index].offset > events[index].offsetSeconds + 1e-6 {
            let event = events[index]
            guard event.hasOnset else { continue }
            result[index] = WindowResult.Event(
                pitch: event.pitch,
                velocity: event.velocity,
                startFrame: event.startFrame,
                endFrame: event.endFrame,
                onsetSeconds: event.onsetSeconds,
                offsetSeconds: refined[index].offset,
                hasOnset: event.hasOnset,
                hasOffset: true
            )
        }
        return result
    }

    /// Adds the notes the signal holds below C2, but only in a window where
    /// the model itself reports no bass at all.
    ///
    /// Measured with recorded piano samples (Tools/render_midi_samples.py),
    /// the model does hear that register: on real timbre it finds a lone G1
    /// at v60 and C2 at v100 without help. It went blind only on the harness
    /// synth's bare harmonic stacks, whose low notes carry neither the attack
    /// transient nor the inharmonicity of a string. So the detector is a
    /// fallback for a window the model left empty down there, not a second
    /// opinion that competes with it.
    private static func bassNotes(
        _ events: [WindowResult.Event],
        samples: [Float],
        windowBegin: Double,
        detector: LowRegisterDetector
    ) -> [WindowResult.Event] {
        // the model already hears bass in this window: leave it alone
        guard !events.contains(where: { $0.pitch <= 45 }) else { return events }
        let existing = events.map { event in
            LowRegisterDetector.Span(pitch: event.pitch, onset: event.onsetSeconds,
                                     offset: event.offsetSeconds, velocity: event.velocity)
        }
        let found = detector.detect(samples: samples, windowBegin: windowBegin, existing: existing)
        guard !found.isEmpty else { return events }
        var result = events
        for span in found {
            let startFrame = max(0, Int(((span.onset - windowBegin) / (1.0 / 100)).rounded()))
            result.append(WindowResult.Event(
                pitch: span.pitch,
                velocity: span.velocity,
                startFrame: startFrame,
                endFrame: startFrame,
                onsetSeconds: span.onset,
                offsetSeconds: span.offset,
                hasOnset: true,
                hasOffset: true
            ))
        }
        result.sort { a, b in
            if a.onsetSeconds != b.onsetSeconds { return a.onsetSeconds < b.onsetSeconds }
            if a.offsetSeconds != b.offsetSeconds { return a.offsetSeconds < b.offsetSeconds }
            return a.pitch < b.pitch
        }
        return result
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
