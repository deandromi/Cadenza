// Assertion-based checks for CadenzaCore, runnable with Xcode Command Line
// Tools via `swift run CadenzaCoreChecks`. Replaces a XCTest/Swift Testing
// target until a full Xcode install is available on this machine.
import Foundation
import Accelerate
import CoreML
import CadenzaCore

setbuf(stdout, nil)

var failures = 0
var checks = 0

@MainActor func expect(_ condition: Bool, _ name: String) {
    checks += 1
    if !condition {
        failures += 1
        print("failed: \(name)")
    }
}

func readF32(_ path: String) -> [Float] {
    let data = try! Data(contentsOf: URL(fileURLWithPath: path))
    return data.withUnsafeBytes { raw in
        Array(UnsafeBufferPointer<Float>(start: raw.bindMemory(to: Float.self).baseAddress!, count: raw.count / 4))
    }
}

func maxAbsDiff(_ a: [Float], _ b: [Float]) -> Float {
    var m: Float = 0
    for i in 0..<min(a.count, b.count) {
        m = max(m, abs(a[i] - b[i]))
    }
    return m
}

// MARK: NoteEvent / Chord (from before)

expect(NoteEvent(pitch: 60, velocity: 64, onset: 0, duration: 1).pitchClass == 0, "pitch class C")
expect(NoteEvent(pitch: 61, velocity: 64, onset: 0, duration: 1).pitchClass == 1, "pitch class C sharp")
expect(NoteEvent(pitch: 108, velocity: 64, onset: 0, duration: 1).pitchClass == 0, "pitch class wraps at C8")

do {
    let notes = [
        NoteEvent(pitch: 60, velocity: 80, onset: 0.00, duration: 1),
        NoteEvent(pitch: 64, velocity: 80, onset: 0.04, duration: 1),
        NoteEvent(pitch: 67, velocity: 80, onset: 0.08, duration: 1),
        NoteEvent(pitch: 72, velocity: 80, onset: 0.20, duration: 1),
    ].assignOnsetGroups()
    expect(notes[0].onsetGroup == notes[1].onsetGroup, "first two notes share a group")
    expect(notes[1].onsetGroup == notes[2].onsetGroup, "chain rule groups third note")
    expect(notes[2].onsetGroup != notes[3].onsetGroup, "gap splits groups")
}

do {
    let notes = [
        NoteEvent(pitch: 64, velocity: 80, onset: 0.0, duration: 1.0),
        NoteEvent(pitch: 48, velocity: 90, onset: 0.01, duration: 1.0),
        NoteEvent(pitch: 55, velocity: 70, onset: 0.02, duration: 1.0),
    ].assignOnsetGroups()
    expect(Chord.identify(in: notes, group: 1)?.symbol == "C", "major triad in any order")
}

do {
    let notes = [
        NoteEvent(pitch: 58, velocity: 80, onset: 0.0, duration: 1.0),
        NoteEvent(pitch: 63, velocity: 80, onset: 0.01, duration: 1.0),
        NoteEvent(pitch: 48, velocity: 90, onset: 0.02, duration: 1.0),
        NoteEvent(pitch: 55, velocity: 80, onset: 0.03, duration: 1.0),
    ].assignOnsetGroups()
    expect(Chord.identify(in: notes, group: 1)?.symbol == "Cm7", "minor seventh from stacked notes")
}

do {
    let notes = [
        NoteEvent(pitch: 55, velocity: 90, onset: 0.0, duration: 1.0),
        NoteEvent(pitch: 59, velocity: 80, onset: 0.01, duration: 1.0),
        NoteEvent(pitch: 62, velocity: 80, onset: 0.02, duration: 1.0),
        NoteEvent(pitch: 65, velocity: 80, onset: 0.03, duration: 1.0),
    ].assignOnsetGroups()
    expect(Chord.identify(in: notes, group: 1)?.symbol == "G7", "dominant seventh prefers bass root")
}

do {
    let notes = [
        NoteEvent(pitch: 60, velocity: 80, onset: 0.0, duration: 1.0),
        NoteEvent(pitch: 64, velocity: 80, onset: 0.01, duration: 1.0),
    ].assignOnsetGroups()
    expect(Chord.identify(in: notes, group: 1) == nil, "fewer than three notes yields nothing")
}

// MARK: Transkun pipeline goldens

let T = 691                 // frames in one 16 s segment
let P = 90                  // symbols: 2 sentinels + 88 pitches
let SEGMENT_SECONDS = 16.0
let STEP_SECONDS = 8.0
let padSeconds = SEGMENT_SECONDS - STEP_SECONDS   // 8 s pre-roll transcribe() pads
let startFrame = Int((padSeconds * 44100) / 1024) // forcedStartPos per symbol = 344
let beginTime = -padSeconds                        // segment begin_time shift
let frameDur = 1024.0 / 44100.0

let audio = readF32("Fixtures/golden/audio_window.f32")
let melGold = readF32("Fixtures/golden/mel_gold.f32")
let SGold = readF32("Fixtures/golden/S_gold.f32")
let skipGold = readF32("Fixtures/golden/S_skip_gold.f32")

let tensorsDir = URL(fileURLWithPath: "Models/tensors")
print("loading mel front end...")
let melFrontEnd = try! MelFrontEnd(tensorsDir: tensorsDir)
print("computing mel for \(audio.count) samples...")
let melOut = melFrontEnd.compute(audio)
print("mel done: \(melOut.count) values")
expect(melOut.count == melGold.count, "mel output length matches gold")
let melDiff = maxAbsDiff(melOut, melGold)
print("mel max |diff| vs gold: \(melDiff)")
var melMeanDiff: Float = 0
for i in 0..<melOut.count { melMeanDiff += melOut[i] - melGold[i] }
melMeanDiff /= Float(melOut.count)
print("mel mean diff vs gold: \(melMeanDiff)")
expect(melDiff < 5e-3, "mel front end matches gold (tol 5e-3)")

// CoreML inference from Swift
let mlpackage = URL(fileURLWithPath: "Models/TranskunBackbone.mlpackage")
do {
    let compiled = try! MLModel.compileModel(at: mlpackage)
    let config = MLModelConfiguration()
    config.computeUnits = .cpuOnly
    let model = try! MLModel(contentsOf: compiled, configuration: config)
    let input = try! MLMultiArray(shape: [1, T, 229, 6] as [NSNumber], dataType: .float32)
    input.dataPointer.withMemoryRebound(to: Float.self, capacity: melOut.count) { ptr in
        ptr.update(from: melOut, count: melOut.count)
    }
    let checkBack = input.dataPointer.withMemoryRebound(to: Float.self, capacity: 8) {
        Array(UnsafeBufferPointer(start: $0, count: 8))
    }
    print("input first 8:", checkBack, "expected:", Array(melOut[0..<8]))
    print("input stats: min/max of first 1000:", melOut[0..<1000].min()!, melOut[0..<1000].max()!)
    let out = try! model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["mel": input]))
    let SOut = out.featureValue(for: "S")!.multiArrayValue!
    let SArr = SOut.dataPointer.withMemoryRebound(to: Float.self, capacity: SOut.count) {
        Array(UnsafeBufferPointer(start: $0, count: SOut.count))
    }
    let d = maxAbsDiff(SArr, SGold)
    let relD = d / max(1.0, SGold.map { abs($0) }.max()!)
    print("coreml S max |diff| vs gold: \(d) (relative \(relD))")
    expect(relD < 1e-3, "coreml S matches gold within fp tolerance")

    // decoder sanity on the GOLD scores directly
    let goldIntervals = SemiCRFDecoder.decode(score: SGold, skip: skipGold, frameCount: T, symbolCount: P)
    print("gold S decode interval counts:", goldIntervals.map { $0.count })
    print("gold S decode non-empty:", goldIntervals.enumerated().filter { !$0.element.isEmpty }.map { ($0.offset, $0.element) })

    // decode with the Swift viterbi (same forcedStartPos as transcribe())
    let skipArr = out.featureValue(for: "S_skip")!.multiArrayValue!.dataPointer
        .withMemoryRebound(to: Float.self, capacity: (T - 1) * P) {
            Array(UnsafeBufferPointer(start: $0, count: (T - 1) * P))
        }
    let intervals = SemiCRFDecoder.decode(score: SArr, skip: skipArr, frameCount: T, symbolCount: P,
                                           forcedStartPos: [Int](repeating: startFrame, count: P))
    let symbols = (try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "Models/tensors/manifest.json"))) as! [[String: Any]])
        .first(where: { $0["name"] as? String == "symbols" })!["value"] as! [Int]
    let ctxArr = out.featureValue(for: "ctx")!.multiArrayValue!.dataPointer
        .withMemoryRebound(to: Float.self, capacity: P * T * 256) {
            Array(UnsafeBufferPointer(start: $0, count: P * T * 256))
        }

    let heads = try! AttributeHeads(tensorsDir: tensorsDir)
    var notes: [NoteEvent] = []
    for s in 0..<P {
        let pitch = symbols[s]
        guard (21...108).contains(pitch) else { continue }
        var lastEnd = 0.0
        for iv in intervals[s] {
            // ctx gather: ctx [1, P, T, 256], flat (s*T + t)*256 + d
            let aBase = (s * T + iv.start) * 256
            let bBase = (s * T + iv.end) * 256
            var attr = [Float](repeating: 0, count: 768)
            for d in 0..<256 {
                let a = ctxArr[aBase + d]
                let b = ctxArr[bBase + d]
                attr[d] = a
                attr[256 + d] = b
                attr[512 + d] = a * b
            }
            let vLogits = heads.velocityLogits(attr)
            var bestV: Float = -Float.infinity
            var bestI = 0
            for i in 0..<128 where vLogits[i] > bestV { bestV = vLogits[i]; bestI = i }
            let of = heads.refinedOF(attr)
            let of0 = max(-0.5, min(0.5, (AttributeHeads.continuousBernoulliMean(logit: of[0]) - 0.5) / 0.99))
            let of1 = max(-0.5, min(0.5, (AttributeHeads.continuousBernoulliMean(logit: of[1]) - 0.5) / 0.99))
            var start = (Double(iv.start) + Double(of0)) * frameDur + beginTime
            var end = (Double(iv.end) + Double(of1)) * frameDur + beginTime
            start = max(start, lastEnd)
            end = max(end, start + 1e-8)
            lastEnd = end
            notes.append(NoteEvent(pitch: pitch, velocity: bestI, onset: start, duration: end - start))
        }
    }
    notes.sort { ($0.onset, $0.pitch) < ($1.onset, $1.pitch) }
    print("swift pipeline notes:", notes.map { "\($0.pitch)@\(String(format: "%.3f", $0.onset))-\(String(format: "%.3f", $0.onset + $0.duration)) v\($0.velocity)" })

    let notesGold = (try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "Fixtures/golden/notes_gold.json")))) as! [[String: Any]]
    expect(notes.count == notesGold.count, "note count matches gold (\(notes.count) vs \(notesGold.count))")
    if notes.count == notesGold.count {
        for (i, g) in notesGold.enumerated() {
            let gn = notes[i]
            expect(gn.pitch == g["pitch"] as! Int, "note \(i) pitch matches")
            expect(abs(gn.onset - (g["start"] as! Double)) < 0.05, "note \(i) onset within 50 ms")
            expect(abs(gn.onset + gn.duration - (g["end"] as! Double)) < 0.05, "note \(i) offset within 50 ms")
            expect(abs(gn.velocity - (g["velocity"] as! Int)) <= 2, "note \(i) velocity within 2")
        }
    }
}

if failures == 0 {
    print("all \(checks) checks passed")
} else {
    print("\(failures) of \(checks) checks failed")
    exit(1)
}
