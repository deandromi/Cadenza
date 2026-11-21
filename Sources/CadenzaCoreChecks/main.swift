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

// MARK: Engraver (sheet music core)

do {
    // a metronome at 120 bpm: one strike per quarter second
    let click = (0..<48).map { i in
        NoteEvent(pitch: 60, velocity: 88, onset: Double(i) * 0.5, duration: 0.25)
    }
    let tempo = Engraver.inferTempo(click)
    expect(abs(tempo - 120) < 4, "tempo reads the click near 120 bpm")

    // key: a C major run
    let runPitches = [60, 64, 67, 72, 67, 64, 59, 62, 65, 60]
    let run = runPitches.enumerated().map { i, p in
        NoteEvent(pitch: p, velocity: 80, onset: Double(i) * 0.5, duration: 0.4)
    }
    let key = Engraver.inferKey(run)
    expect(key.name == "C major", "key reads C major")
    expect(key.fifths == 0, "C major signature has no accidentals")

    // key: A minor
    let minorPitches = [57, 60, 64, 69, 64, 60, 55, 52, 57]
    let minor = minorPitches.enumerated().map { i, p in
        NoteEvent(pitch: p, velocity: 80, onset: Double(i) * 0.5, duration: 0.4)
    }
    let aMinor = Engraver.inferKey(minor)
    expect(aMinor.name == "A minor", "key reads A minor")
    expect(aMinor.fifths == 0, "A minor signature has no accidentals")

    // meter: accented every four quarters reads 4/4
    let four = (0..<32).map { i in
        NoteEvent(
            pitch: i % 4 == 0 ? 60 : 72,
            velocity: i % 4 == 0 ? 110 : 70,
            onset: Double(i) * 0.5,
            duration: 0.3
        )
    }
    let fourMeter = Engraver.inferTimeSignature(four, tempo: 120)
    expect(
        fourMeter == TimeSignature(beatsPerMeasure: 4, beatUnit: 4),
        "meter reads 4/4 from accents every fourth quarter"
    )

    // meter: accented every three quarters reads 3/4
    let waltz = (0..<30).map { i in
        NoteEvent(
            pitch: i % 3 == 0 ? 60 : 72,
            velocity: i % 3 == 0 ? 110 : 70,
            onset: Double(i) * 0.5,
            duration: 0.3
        )
    }
    let threeMeter = Engraver.inferTimeSignature(waltz, tempo: 120)
    expect(
        threeMeter == TimeSignature(beatsPerMeasure: 3, beatUnit: 4),
        "meter reads 3/4 from waltz accents"
    )
}

do {
    // a C major session: a chord on every downbeat, soft single notes
    // between, a chord symbol on beat one, and one quarter past the last
    // full bar so the rest filler has to speak
    var session: [NoteEvent] = []
    for i in 0..<13 {
        let onset = Double(i) * 0.5
        if i % 4 == 0 {
            for pitch in [48, 60, 64, 67] {
                session.append(NoteEvent(
                    pitch: pitch,
                    velocity: 100,
                    onset: onset + Double(pitch % 4) * 0.01,
                    duration: 0.45
                ))
            }
        } else {
            session.append(NoteEvent(pitch: 64, velocity: 70, onset: onset, duration: 0.2))
        }
    }
    let maybeScore = Engraver.engrave(notes: session, chords: [(0.0, "C")])
    expect(maybeScore != nil, "engrave returns a score")
    if let scored = maybeScore {
        expect(
            scored.framing.timeSignature == TimeSignature(beatsPerMeasure: 4, beatUnit: 4),
            "chords every fourth quarter frame as 4/4"
        )
        expect(scored.framing.key.name == "C major", "engraved key is C major")
        expect(scored.measures.count == 4, "thirteen quarters cut into four measures")
        expect(
            scored.measures.first?.notes.count == 7,
            "a full measure carries its chord and three singles"
        )
        expect(scored.measures.last?.notes.count == 4, "the last measure carries only its chord")
        let firstNote = scored.measures.first?.notes.first
        expect(firstNote?.onsetTick == scored.measures.first?.startTick, "first note lands on its downbeat")
        expect(firstNote?.durationTicks == 480, "a 0.45 s note at 120 bpm engraves as a quarter")

        let xml = MusicXML.write(scored)
        expect(xml.contains("<divisions>120</divisions>"), "musicxml writes the division count")
        expect(xml.contains("<fifths>0</fifths>"), "musicxml writes the key signature")
        expect(xml.contains("<beats>4</beats>"), "musicxml writes the meter numerator")
        expect(xml.contains("<chord/>"), "stacked notes carry the chord mark")
        expect(xml.contains("<words>C</words>"), "the chord symbol rides above the staff")
        expect(xml.contains("<rest/>"), "the empty measure tail fills as rest")
        expect(xml.contains("<type>quarter</type>"), "a quarter is labeled a quarter")
        expect(XMLParser(data: Data(xml.utf8)).parse(), "the musicxml document parses")
    }
}

// MARK: NoteLengthRefiner

noteLengthRefiner: do {
    // A held note whose decoded interval collapsed to a blip: the audio says
    // the pitch keeps sounding, so the refiner must move the end out to the
    // release, and must not touch a note the model already measured.
    let rate = 44100.0
    func tone(pitch: Int, start: Double, end: Double, seconds: Double = 3.0) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(seconds * rate))
        let frequency = 440.0 * pow(2.0, Double(pitch - 69) / 12.0)
        let first = Int(start * rate)
        let last = min(samples.count, Int(end * rate))
        for index in first..<last {
            let t = Double(index - first) / rate
            let envelope = exp(-t / 0.8)
            samples[index] = Float(sin(2 * Double.pi * frequency * t) * envelope * 0.4)
        }
        return samples
    }
    let refiner = NoteLengthRefiner(rate: rate)
    let audio = tone(pitch: 69, start: 0.5, end: 1.3)
    let collapsed = [NoteLengthRefiner.Span(pitch: 69, onset: 0.5, offset: 0.55, hasOffset: true)]
    let fixed = refiner.refine(collapsed, samples: audio, windowBegin: 0)
    expect(fixed.count == 1, "the refiner keeps one span per note")
    expect(fixed[0].offset > 0.95, "a blip decoded on a held note grows to the release")
    expect(fixed[0].offset < 1.45, "the refiner does not run past the sound")

    // a note the model already measured is left exactly as it decoded
    let measured = [NoteLengthRefiner.Span(pitch: 69, onset: 0.5, offset: 0.95, hasOffset: true)]
    let untouched = refiner.refine(measured, samples: audio, windowBegin: 0)
    expect(untouched[0].offset == 0.95, "a plausible length is not second-guessed")

    // silence around the note must never invent a tail
    let quiet: [Float] = [Float](repeating: 0, count: Int(3.0 * rate))
    let nothing = refiner.refine(collapsed, samples: quiet, windowBegin: 0)
    expect(nothing[0].offset == 0.55, "silence leaves the decoded length alone")

    // A note held under a chord or the pedal has no release of its own: its
    // band fades instead of dropping. The whole sound damps at 2 s, so that is
    // where the note ends, even though it lies outside the local search.
    func fadingTone(pitch: Int, start: Double, end: Double, seconds: Double) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(seconds * rate))
        let frequency = 440.0 * pow(2.0, Double(pitch - 69) / 12.0)
        let first = Int(start * rate)
        let last = min(samples.count, Int(end * rate))
        for index in first..<last {
            let t = Double(index - first) / rate
            samples[index] = Float(sin(2 * Double.pi * frequency * t) * exp(-t / 1.2) * 0.4)
        }
        return samples
    }
    let held = fadingTone(pitch: 69, start: 0.4, end: 2.0, seconds: 2.6)
    let longBlip = [NoteLengthRefiner.Span(pitch: 69, onset: 0.4, offset: 0.45, hasOffset: true)]
    let damped = refiner.refine(longBlip, samples: held, windowBegin: 0)
    expect(damped[0].offset > 1.5, "a note held with the rest follows the global damping")
    expect(damped[0].offset < 2.1, "the global damping never invents a tail past the sound")

    // The same note cut short and a chord sounding much later: the note is
    // already silent when that chord damps, so nothing extends it.
    var later: [Float] = held
    for index in Int(1.5 * rate)..<Int(2.0 * rate) {
        let t = Double(index - Int(1.5 * rate)) / rate
        later[index] += Float(sin(2 * Double.pi * 523.25 * t) * 0.4)
    }
    let cut = [NoteLengthRefiner.Span(pitch: 69, onset: 0.4, offset: 0.45, hasOffset: true)]
    let unaffected = refiner.refine(cut, samples: later, windowBegin: 0)
    expect(unaffected[0].offset <= 2.1, "a later chord does not stretch an already quiet note")
}

// MARK: SingleStrikes

singleStrikes: do {
    // The same key reported twice within a clock tick is one strike, and the
    // longer interval is the one that was heard.
    let twice = [
        NoteEvent(pitch: 31, velocity: 78, onset: 15.997, duration: 0.709),
        NoteEvent(pitch: 31, velocity: 84, onset: 15.999, duration: 1.033)
    ]
    let merged = SingleStrikes.merge(twice)
    expect(merged.count == 1, "one key struck twice within a tick is one note")
    expect(abs(merged[0].duration - 1.035) < 0.01, "the longer interval survives")
    expect(merged[0].velocity == 84, "the stronger strike sets the velocity")

    // A real repetition is left alone: a bass note every eighth at 120 bpm.
    let repeated = (0..<4).map { index in
        NoteEvent(pitch: 31, velocity: 70, onset: Double(index) * 0.25, duration: 0.24)
    }
    expect(SingleStrikes.merge(repeated).count == 4, "a repeated bass note stays repeated")

    // Different pitches at the same instant are a chord, not a duplicate.
    let chord = [
        NoteEvent(pitch: 60, velocity: 70, onset: 1.0, duration: 0.5),
        NoteEvent(pitch: 64, velocity: 70, onset: 1.0, duration: 0.5),
        NoteEvent(pitch: 67, velocity: 70, onset: 1.0, duration: 0.5)
    ]
    expect(SingleStrikes.merge(chord).count == 3, "a chord is untouched")
}

// MARK: LowRegisterDetector

lowRegisterDetector: do {
    // The model cannot hear below C2, so the signal has to: a struck G1 has
    // to come back with its onset and its length, and a room-tone window has
    // to stay empty.
    let rate = 44100.0
    func bass(_ pitch: Int, start: Double, end: Double, seconds: Double) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(seconds * rate))
        let frequency = 440.0 * pow(2.0, Double(pitch - 69) / 12.0)
        let first = Int(start * rate)
        let last = min(samples.count, Int(end * rate))
        for index in first..<last {
            let t = Double(index - first) / rate
            let envelope = exp(-t / 1.4) * min(1.0, t / 0.004)
            var value = 0.0
            for harmonic in 1...6 {
                value += sin(2 * Double.pi * frequency * Double(harmonic) * t) / Double(harmonic)
            }
            samples[index] = Float(value * envelope * 0.35)
        }
        return samples
    }
    let detector = LowRegisterDetector(rate: rate)
    let solo = bass(31, start: 0.3, end: 1.5, seconds: 2.4)
    let found = detector.detect(samples: solo, windowBegin: 0, existing: [])
    expect(found.contains { $0.pitch == 31 }, "a struck G1 is found in the signal")
    if let note = found.first(where: { $0.pitch == 31 }) {
        expect(abs(note.onset - 0.3) < 0.09, "the bass note keeps its onset")
        expect(note.offset > 1.1 && note.offset < 1.8, "the bass note keeps its length")
        expect(note.velocity > 24 && note.velocity <= 110, "the bass note gets a playable velocity")
    }

    // A note the model already decoded is not added a second time.
    let covered = [LowRegisterDetector.Span(pitch: 31, onset: 0.3, offset: 1.5, velocity: 60)]
    let again = detector.detect(samples: solo, windowBegin: 0, existing: covered)
    expect(!again.contains { $0.pitch == 31 && abs($0.onset - 0.3) < 0.075 },
           "a bass note the model found is not duplicated")

    // Nothing in silence, and nothing in noise: the detector only adds notes
    // where a low fundamental actually holds.
    let silence: [Float] = [Float](repeating: 0, count: Int(2.4 * rate))
    expect(detector.detect(samples: silence, windowBegin: 0, existing: []).isEmpty,
           "silence gives no bass notes")
    var noise = [Float](repeating: 0, count: Int(2.4 * rate))
    var seed: UInt64 = 0x9E3779B97F4A7C15
    for index in noise.indices {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        noise[index] = Float(Double(seed >> 40) / Double(1 << 24) - 0.5) * 0.06
    }
    expect(detector.detect(samples: noise, windowBegin: 0, existing: []).isEmpty,
           "room tone invents no bass notes")

    // Above the detector's own range the model is in charge: a C4 alone is
    // not its business.
    let middle = bass(60, start: 0.3, end: 1.5, seconds: 2.4)
    expect(detector.detect(samples: middle, windowBegin: 0, existing: []).isEmpty,
           "the detector leaves the model's register alone")
}

// MARK: MidiReader

/// Builds a tiny standard MIDI file in memory: format 0, 480 ppqn, one
/// track carrying the given events as (deltaTicks, bytes).
func syntheticMidi(events: [(Int, [UInt8])], division: Int = 480) -> Data {
    var data = Data()
    data.append(contentsOf: Array("MThd".utf8))
    data.append(contentsOf: [0, 0, 0, 6])
    data.append(contentsOf: [0, 0])          // format 0
    data.append(contentsOf: [0, 1])          // one track
    var div = UInt16(division).bigEndian
    data.append(contentsOf: withUnsafeBytes(of: &div) { Array($0) })
    var track = Data()
    for (delta, bytes) in events {
        // VLQ encode the delta
        var value = delta
        var buffer = [UInt8]()
        buffer.append(UInt8(value & 0x7F))
        value >>= 7
        while value > 0 {
            buffer.append(UInt8((value & 0x7F) | 0x80))
            value >>= 7
        }
        track.append(contentsOf: buffer.reversed())
        track.append(contentsOf: bytes)
    }
    data.append(contentsOf: Array("MTrk".utf8))
    var length = UInt32(track.count).bigEndian
    data.append(contentsOf: withUnsafeBytes(of: &length) { Array($0) })
    data.append(track)
    return data
}

midiParse1: do {
    // 4/4, D major (two sharps), 120 bpm; one C4 quarter at 120 bpm is 0.5 s
    let midi = syntheticMidi(events: [
        (0, [0xFF, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08]),   // time 4/4
        (0, [0xFF, 0x59, 0x02, 0x02, 0x00]),               // key: 2 sharps, major
        (0, [0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]),         // 500000 us/qn = 120 bpm
        (0, [0x90, 60, 64]),                              // C4 on
        (480, [60, 0]),                                   // running status off
        (0, [0xFF, 0x2F, 0x00]),                          // end of track
    ])
    let file = try? MidiReader.read(midi)
    expect(file != nil, "synthetic midi parses")
    guard let file else { break midiParse1 }
    expect(file.ticksPerQuarter == 480, "midi reader keeps the division")
    expect(file.notes.count == 1, "one note parsed")
    if let note = file.notes.first {
        expect(note.pitch == 60 && note.velocity == 64, "note pitch and velocity")
        expect(abs(note.onset) < 1e-9, "note onset at zero")
        expect(abs(note.duration - 0.5) < 1e-9, "480 ticks at 120 bpm is half a second")
    }
    expect(file.timeSignatures.first?.signature == TimeSignature(beatsPerMeasure: 4, beatUnit: 4), "midi meta reads 4/4")
    expect(file.keySignatures.first?.key.name == "D major", "midi meta reads D major")
    expect(file.keySignatures.first?.key.fifths == 2, "D major has two sharps")
    expect(abs(file.initialTempo - 120) < 0.01, "midi meta reads 120 bpm")
}

midiParse2: do {
    // a tempo change mid-note: on at 0, halve tempo at 240 ticks, off at
    // 480: duration is 0.25 s at 120 bpm plus 0.5 s at 60 bpm = 0.75 s
    let midi = syntheticMidi(events: [
        (0, [0x90, 60, 100]),
        (240, [0xFF, 0x51, 0x03, 0x0F, 0x42, 0x40]),       // 1000000 us/qn = 60 bpm
        (240, [0x80, 60, 0]),                              // explicit status: meta cancelled running status
        (0, [0xFF, 0x2F, 0x00]),
    ])
    let file = try? MidiReader.read(midi)
    expect(file != nil, "tempo-change midi parses")
    guard let file else { break midiParse2 }
    if let note = file.notes.first {
        expect(abs(note.duration - 0.75) < 1e-9, "tempo change mid-note stretches the duration")
    } else {
        expect(false, "tempo-change midi parsed a note")
    }
    expect(file.tempoChanges.count == 1 && abs(file.tempoChanges[0].bpm - 60) < 0.01, "tempo change recorded")
}

// MARK: ScoreLayout and the choices step

expect(ScoreLayout.diatonicStep(60) == 28, "C4 is diatonic step 28")
expect(ScoreLayout.diatonicStep(64) == 30, "E4 is step 30")
expect(ScoreLayout.treblePosition(64) == 0, "E4 sits on the treble bottom line")
expect(ScoreLayout.treblePosition(60) == -2, "middle C hangs a step below the treble staff")
expect(ScoreLayout.bassPosition(43) == 0, "G2 sits on the bass bottom line")
expect(ScoreLayout.isTreble(60) && !ScoreLayout.isTreble(59), "the staff split is at middle C")

do {
    let quarter = ScoreLayout.noteValue(480)
    expect(quarter.head == .filled && quarter.stem && quarter.flags == 0 && quarter.dots == 0, "a quarter is a filled stemmed head")
    let whole = ScoreLayout.noteValue(1920)
    expect(whole.head == .whole && !whole.stem, "a whole note carries no stem")
    expect(ScoreLayout.noteValue(240).flags == 1, "an eighth carries one flag")
    expect(ScoreLayout.noteValue(120).flags == 2, "a sixteenth carries two")
    expect(ScoreLayout.noteValue(720).dots == 1, "a dotted quarter carries a dot")
}

expect(ScoreLayout.keyGlyphs(1).count == 1 && ScoreLayout.keyGlyphs(1)[0].treblePosition == 8 && ScoreLayout.keyGlyphs(1)[0].accidental == .sharp, "G major shows one sharp on the treble top line")
expect(ScoreLayout.keyGlyphs(-2).count == 2 && ScoreLayout.keyGlyphs(-2).allSatisfy { $0.accidental == .flat }, "two flats for a two-flat key")
expect(ScoreLayout.keyGlyphs(0).isEmpty, "C major shows no key glyphs")
expect(ScoreLayout.accidental(for: 65, fifths: 1) == .natural, "F natural against G major needs a natural sign")
expect(ScoreLayout.accidental(for: 66, fifths: 1) == nil, "F sharp is covered by G major")
expect(ScoreLayout.accidental(for: 66, fifths: 0) == .sharp, "F sharp against C major needs a sharp")
expect(ScoreLayout.accidental(for: 65, fifths: 0) == nil, "F natural against C major needs nothing")

layoutFixture: do {
    // the same C major session as the engrave check above, plus a gap that
    // leaves one measure empty so the rest filler has to speak
    var session: [NoteEvent] = []
    for i in 0..<4 {
        let onset = Double(i) * 0.5
        for pitch in [48, 60, 64, 67] {
            session.append(NoteEvent(pitch: pitch, velocity: 100, onset: onset + Double(pitch % 4) * 0.01, duration: 0.45))
        }
    }
    session.append(NoteEvent(pitch: 72, velocity: 70, onset: 4.0, duration: 0.4))

    guard let score = Engraver.engrave(notes: session, chords: [(0.0, "C")]) else {
        expect(false, "layout fixture engraves")
        break layoutFixture
    }

    let keys = Engraver.scoreKeyCandidates(session)
    expect(keys.count == 24, "all 24 keys are ranked")
    expect(keys.first?.name == "C major", "key candidates rank C major first")

    let overridden = Engraver.engrave(
        notes: session,
        framing: ScoreFraming(
            beatsPerMinute: 90,
            timeSignature: TimeSignature(beatsPerMeasure: 3, beatUnit: 4),
            key: KeySignature(tonic: 7, isMinor: false)
        )
    )
    expect(
        overridden?.framing.beatsPerMinute == 90
            && overridden?.framing.timeSignature == TimeSignature(beatsPerMeasure: 3, beatUnit: 4)
            && overridden?.framing.key.name == "G major",
        "engrave takes the framing the choices step picked"
    )

    let result = ScoreLayout.layout(score, width: 200)
    expect(result.systems.count >= 2, "a narrow page wraps measures into systems")
    expect(result.keyGlyphs.isEmpty, "C major lays out with no key glyphs")
    let allMeasures = result.systems.flatMap(\.measures)
    let first = allMeasures[0]
    expect(first.showsFraming, "the first measure shows clef key and meter")
    expect(
        first.treble.contains { $0.pitch == 60 && $0.staffPosition == -2 && $0.ledgerPositions == [-2] },
        "middle C hangs on a ledger line below the treble staff"
    )
    expect(
        first.bass.contains { $0.pitch == 48 && $0.staffPosition == ScoreLayout.bassPosition(48) },
        "the low chord notes land on the bass staff"
    )
    let highNote = allMeasures.flatMap(\.treble).first { $0.pitch == 72 }
    expect(highNote?.stemUp == false, "a note above the middle line stems down")
    expect(first.treble.first { $0.pitch == 60 }?.stemUp == true, "a low chord stems up")
    expect(first.chord?.symbol == "C", "the chord symbol rides on the first measure")

    let empty = allMeasures.first { $0.treble.isEmpty && $0.bass.isEmpty }
    expect(empty?.trebleRest?.whole == true && empty?.bassRest?.whole == true, "an empty measure gets whole rests on both staves")

    let wide = ScoreLayout.layout(score, width: 4000)
    expect(wide.systems.count == 1, "a wide page keeps every measure on one system")
    expect(wide.systems[0].measures[1].showsFraming == false, "later measures on the same system show no framing")
}

// MARK: SheetDraft (the live-stream engraving process)

do {
    // Chordify: onsets within the 40 ms window collapse onto the chain head.
    let options = SheetDraft.Options(bpm: 120, numerator: 4, denominator: 4)
    let notes = [
        SheetDraft.RunningNote(start: 0, duration: 240, pitch: 60),
        SheetDraft.RunningNote(start: 30, duration: 240, pitch: 64),
        SheetDraft.RunningNote(start: 200, duration: 240, pitch: 67),
    ]
    let chordified = SheetDraft.chordify(notes, options: options)
    expect(chordified[0].start == chordified[1].start, "onsets within the combine interval collapse")
    expect(chordified[2].start > chordified[1].start, "an onset past the interval keeps its own time")
    expect(SheetDraft.ticks(ms: 40, options: options) == 38, "40 ms is 38 ticks at 120 bpm")
}

do {
    // Duration rounding: notes stretch to the next onset on a quarter grid.
    var notes = [
        SheetDraft.RunningNote(start: 0, duration: 120, pitch: 60),
        SheetDraft.RunningNote(start: 480, duration: 120, pitch: 62),
    ]
    notes = SheetDraft.roundDurations(notes)
    expect(notes[0].duration == 480, "a note to the next quarter fills a quarter")
    var pair = [
        SheetDraft.RunningNote(start: 0, duration: 240, pitch: 60),
        SheetDraft.RunningNote(start: 240, duration: 240, pitch: 64),
    ]
    pair = SheetDraft.roundDurations(pair)
    expect(pair[0].duration == 240, "an adjacent equal pair stays intact for beaming")
}

do {
    // Hand split: a chord spanning octaves divides top and bottom.
    let notes = [
        SheetDraft.RunningNote(start: 0, duration: 480, pitch: 48),
        SheetDraft.RunningNote(start: 0, duration: 480, pitch: 76),
        SheetDraft.RunningNote(start: 480, duration: 480, pitch: 60),
    ]
    let hands = SheetDraft.splitHands(notes, measureTicks: 1920)
    expect(hands.top.contains { $0.pitch == 76 }, "the high note goes to the top hand")
    expect(hands.bottom.contains { $0.pitch == 48 }, "the low note goes to the bottom hand")
}

do {
    // Key guessing picks the key with the fewest accidentals.
    let cMajor = [60, 62, 64, 65, 67, 69, 71, 72]
    expect(SheetDraft.guessedFifths(pitches: cMajor) == 0, "the C major scale reads as C major")
    let eMajor = [64, 66, 68, 69, 71, 73, 75, 76]
    expect(SheetDraft.guessedFifths(pitches: eMajor) == 4, "the E major scale reads as E major")
    let fMajor = [65, 67, 69, 70, 72, 74, 76]
    expect(SheetDraft.guessedFifths(pitches: fMajor) == -1, "the F major scale reads as F major")
}

do {
    // Accidentals per key signature.
    expect(SheetDraft.accidental(pitchClass: 6, fifths: 0) == .sharp, "F sharp in C major takes a sharp")
    expect(SheetDraft.accidental(pitchClass: 5, fifths: 1) == .natural, "F natural in G major takes a natural")
    expect(SheetDraft.accidental(pitchClass: 10, fifths: 0) == .flat, "A sharp spells as B flat on the sharp side")
    expect(SheetDraft.accidental(pitchClass: 6, fifths: 1) == .none, "F sharp in G major carries no accidental")
}

do {
    // The duration ladder.
    expect(SheetDraft.noteValue(1920).head == .whole, "a whole note wears a whole head")
    expect(SheetDraft.noteValue(960).head == .half && SheetDraft.noteValue(960).dots == 0, "three quarters draw as a half")
    expect(SheetDraft.noteValue(480).flags == 0, "a quarter note carries no flags")
    expect(SheetDraft.noteValue(240).flags == 1, "an eighth note carries one flag")
    expect(SheetDraft.noteValue(120).flags == 2, "a sixteenth note carries two flags")
}

do {
    // Rests fill by the classic buckets.
    let quarterGap = SheetDraft.rests(start: 0, end: 480)
    expect(quarterGap == [.rest(startTicks: 0, kind: .quarter)], "a quarter gap fills with one quarter rest")
    let dottedHalf = SheetDraft.rests(start: 0, end: 1440)
    expect(dottedHalf == [.rest(startTicks: 0, kind: .half), .rest(startTicks: 960, kind: .quarter)],
           "a dotted half splits into half plus quarter")
    expect(SheetDraft.rests(start: 0, end: 120).isEmpty, "a tiny gap draws nothing")
}

do {
    // A full draft of a two-measure run of quarter chords.
    let options = SheetDraft.Options(bpm: 120, numerator: 4, denominator: 4)
    var events: [NoteEvent] = []
    for i in 0..<8 {
        let onset = 0.25 + Double(i) * 0.5
        events.append(NoteEvent(pitch: i.isMultiple(of: 2) ? 64 : 67, velocity: 80, onset: onset, duration: 0.4))
    }
    let result = SheetDraft.draft(notes: events, options: options)
    expect(result.rows.first?.showsFraming == true, "the first row shows clef key and meter")
    expect(result.rows.first?.firstMeasure == 1, "measure numbers start at one")
    let topBars = result.topTrack.filter { if case .bar = $0 { return true }; return false }
    expect(topBars.count >= 2, "the run crosses a measure boundary")
    if case .chord(let first)? = result.topTrack.first(where: { if case .chord = $0 { return true }; return false }) {
        expect(first.notes[0].staffPosition >= 0, "the treble chord lands on the staff")
        expect(first.stems.isEmpty || first.stems[0].flags == 0, "quarter chords carry no flags")
    } else {
        expect(false, "the top track carries chords")
    }
    expect(result.rows[0].top.contains { placed in
        placed.trackIndex >= 0
    }, "placed symbols carry their track index")
}

do {
    // Eighths in the same beat beam together.
    let options = SheetDraft.Options(bpm: 120, numerator: 4, denominator: 4)
    var events: [NoteEvent] = []
    for i in 0..<4 {
        let onset = 0.25 + Double(i) * 0.25
        events.append(NoteEvent(pitch: 72, velocity: 80, onset: onset, duration: 0.15))
    }
    let result = SheetDraft.draft(notes: events, options: options)
    expect(result.beamGroups.contains { $0.chordIndices.count == 2 },
           "a beat's two eighths share a beam")
    let beamedChords = result.topTrack.filter { symbol in
        if case .chord(let c) = symbol {
            return c.stems.contains { $0.beamGroupId != nil }
        }
        return false
    }
    expect(beamedChords.count == 2, "the on-beat eighths get beamed, the trailing ones stand alone")
}

do {
    // The empty stream still produces a framed empty row.
    let result = SheetDraft.draft(notes: [], options: SheetDraft.Options())
    expect(result.rows.count == 1 && result.rows[0].showsFraming, "an empty stream draws one empty row")
    expect(result.fifths == 0, "no notes guess the key of C")
}

midiProgramChange: do {
    // A program change carries one data byte. Reading two desynchronises the
    // rest of the track, which silently corrupts every imported MIDI file.
    let midi = syntheticMidi(events: [
        (0, [0xC0, 0x05]),          // program change, one data byte
        (0, [0x90, 60, 80]),        // C4 on
        (480, [0x80, 60, 0]),       // C4 off at 0.5 s
        (0, [0xC1, 0x10]),          // a second channel's program change
        (0, [0x91, 67, 70]),        // G4 on channel 1
        (480, [0x81, 67, 0]),       // G4 off at 1.0 s
        (0, [0xFF, 0x2F, 0x00]),
    ])
    let file = try? MidiReader.read(midi)
    expect(file != nil, "program-change midi parses")
    if let file {
        expect(file.notes.count == 2, "program changes do not swallow notes")
        let pitches = file.notes.map { $0.pitch }.sorted()
        expect(pitches == [60, 67], "the notes after program changes keep their pitch")
        expect(abs((file.notes.last?.onset ?? 0) - 0.5) < 1e-9,
               "the note after a program change keeps its time")
    }
}

pedalChecks: do {
    // CC64 spans: a note released under the pedal rings to the lift, and
    // the reader keeps the pedal spans themselves for the engraver.
    let midi = syntheticMidi(events: [
        (0, [0x90, 60, 80]),        // C4 on
        (0, [0xB0, 64, 100]),       // sustain down
        (480, [0x80, 60, 0]),       // key up at 0.5 s, pedal holds it
        (0, [0x90, 64, 80]),        // E4 on, still under the pedal
        (480, [0xB0, 64, 0]),       // pedal up at 1.0 s
        (240, [0x80, 64, 0]),       // E4 off at 1.25 s, unpedalled tail
        (0, [0xFF, 0x2F, 0x00]),
    ])
    let file = try? MidiReader.read(midi)
    expect(file != nil, "pedal midi parses")
    guard let file else { break pedalChecks }
    expect(file.notes.count == 2, "two notes under one pedal span")
    if let c4 = file.notes.first(where: { $0.pitch == 60 }) {
        expect(abs(c4.duration - 1.0) < 1e-9, "the pedalled note rings to the pedal lift")
    } else {
        expect(false, "the C4 note parsed")
    }
    expect(file.sustainPedals.count == 1, "one pedal span read")
    if let span = file.sustainPedals.first {
        expect(abs(span.start) < 1e-9 && abs(span.end - 1.0) < 1e-9,
               "the pedal span runs 0 to 1 s")
    }
}

pedalSheet: do {
    // The engraved edition carries no pedal marks: a pedalled performance
    // has a span under almost every chord, and a mark in the wrong place
    // reads worse than none. What the engraver must still guarantee is that
    // the pedal never disturbs the notes it sounds under.
    let options = SheetDraft.Options(bpm: 120, numerator: 4, denominator: 4)
    let notes = [
        NoteEvent(pitch: 60, velocity: 80, onset: 0.0, duration: 1.8),
        NoteEvent(pitch: 64, velocity: 80, onset: 0.0, duration: 1.8),
        NoteEvent(pitch: 60, velocity: 80, onset: 2.0, duration: 0.9),
        NoteEvent(pitch: 43, velocity: 80, onset: 0.0, duration: 1.8),
        NoteEvent(pitch: 48, velocity: 80, onset: 2.0, duration: 0.9),
    ]
    let plain = SheetDraft.draft(notes: notes, options: options)
    let pedalled = SheetDraft.draft(notes: notes, options: options, pedals: [
        SheetDraft.PedalSpan(startTick: 950, endTick: 1500),
    ])
    let pedalMarks = pedalled.bottomTrack.filter {
        if case .pedalDown = $0 { return true }
        if case .pedalUp = $0 { return true }
        return false
    }
    expect(pedalMarks.isEmpty, "pedal spans stay out of the ink")
    expect(pedalled.topTrack == plain.topTrack, "the pedal leaves the treble untouched")
    expect(pedalled.bottomTrack == plain.bottomTrack, "the pedal leaves the bass untouched")
    expect(pedalled.rows == plain.rows, "the pedal leaves the layout untouched")
}

sheetLayout: do {
    // Four bars of waltz: a bass note on the downbeat, chords on the two
    // beats after it, a melody above. The sheet must read it as 3/4 — the
    // default 4/4 would put every barline in the wrong place — and the
    // system must close with a barline of its own.
    var notes: [NoteEvent] = []
    for bar in 0..<4 {
        let start = Double(bar) * 1.5          // 3/4 at 120 bpm
        notes.append(NoteEvent(pitch: 43, velocity: 96, onset: start, duration: 0.4))
        notes.append(NoteEvent(pitch: 55, velocity: 64, onset: start + 0.5, duration: 0.4))
        notes.append(NoteEvent(pitch: 59, velocity: 62, onset: start + 1.0, duration: 0.4))
        notes.append(NoteEvent(pitch: 79, velocity: 80, onset: start, duration: 0.45))
        notes.append(NoteEvent(pitch: 76, velocity: 74, onset: start + 0.5, duration: 0.45))
        notes.append(NoteEvent(pitch: 72, velocity: 72, onset: start + 1.0, duration: 0.45))
    }
    let guessed = SheetDraft.inferredOptions(notes: notes)
    expect(guessed.numerator == 3, "a waltz bass reads as 3/4")
    let draft = SheetDraft.draft(notes: notes, options: guessed)
    expect(draft.rows.count == 1, "four bars make one system")
    expect(draft.rows.first?.top.last.map {
        if case .finalBar = $0.symbol { return true }
        return false
    } ?? false, "the system closes with a final barline")
    expect(draft.rowsPerPage == SheetEngraver.systemsPerPage,
           "systems are grouped into pages")

    // Every column of a bar keeps its own place: two sixteenths share a bar
    // without their noteheads landing on top of each other, and nothing is
    // ever pushed past the bar's closing line.
    let sixteenths = [
        NoteEvent(pitch: 72, velocity: 80, onset: 0.00, duration: 0.2),
        NoteEvent(pitch: 74, velocity: 80, onset: 0.25, duration: 0.2),
        NoteEvent(pitch: 76, velocity: 80, onset: 0.50, duration: 0.2),
        NoteEvent(pitch: 77, velocity: 80, onset: 0.75, duration: 0.2),
        NoteEvent(pitch: 43, velocity: 80, onset: 0.0, duration: 1.4),
    ]
    let dense = SheetDraft.draft(notes: sixteenths,
                                 options: SheetDraft.Options(bpm: 120, numerator: 4, denominator: 4))
    if let row = dense.rows.first {
        let xs = row.top.compactMap { placed -> Double? in
            guard case .chord = placed.symbol else { return nil }
            return placed.x
        }.sorted()
        let gaps = zip(xs.dropFirst(), xs).map { $0 - $1 }
        expect(gaps.allSatisfy { $0 >= 1.2 }, "sixteenths get a column of their own")
        let widest = row.top.map(\.x).max() ?? 0
        expect(widest <= row.width, "no head crosses the closing barline")
    } else {
        expect(false, "a dense bar still engraves")
    }

    // A key held past the barline is written again on the next downbeat and
    // tied to what came before, never restruck and never closed by a rest.
    let heldChord = [
        NoteEvent(pitch: 72, velocity: 80, onset: 0.0, duration: 2.4),
        NoteEvent(pitch: 43, velocity: 80, onset: 0.0, duration: 0.4),
    ]
    let held = SheetDraft.draft(notes: heldChord,
                                options: SheetDraft.Options(bpm: 120, numerator: 4, denominator: 4))
    var tied = false
    var continued = false
    for row in held.rows {
        for placed in row.top {
            guard case .chord(let chord) = placed.symbol else { continue }
            if chord.notes.contains(where: { $0.pitch == 72 && $0.tieToNext }) { tied = true }
        }
    }
    for track in held.topTrack {
        guard case .chord(let chord) = track else { continue }
        if chord.startTicks == held.options.measureTicks,
           chord.notes.contains(where: { $0.pitch == 72 }) { continued = true }
    }
    expect(tied, "a note held over the barline is tied")
    expect(continued, "the tied note resumes on the next downbeat")
}

if failures == 0 {
    print("all \(checks) checks passed")
} else {
    print("\(failures) of \(checks) checks failed")
    exit(1)
}
