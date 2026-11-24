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
    // CoreML writes a fresh TranskunBackbone_<uuid>.mlmodelc into the system
    // temp folder and nothing removes it; a checks run is not an exception, and
    // a few hundred runs filled the disk once already.
    let compiled = try! MLModel.compileModel(at: mlpackage)
    defer { try? FileManager.default.removeItem(at: compiled) }
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

// MARK: RestruckKeys

restruckKeys: do {
    // A pedal-held note outliving its own re-strike ends where the key is
    // struck again: the second attack is proof the first key came up.
    let outlives = [
        NoteEvent(pitch: 60, velocity: 70, onset: 0.0, duration: 5.0),
        NoteEvent(pitch: 60, velocity: 80, onset: 1.0, duration: 0.5)
    ]
    let clipped = RestruckKeys.clip(outlives)
    expect(abs(clipped[0].duration - 1.0) < 0.001,
           "a note ends where its own key is struck again, got \(clipped[0].duration)")
    expect(clipped[1].duration == 0.5, "the re-strike keeps its own length")
    expect(clipped.count == 2, "clipping never drops a strike")

    // A note that ends before the next strike is left exactly as it was.
    let clean = [
        NoteEvent(pitch: 60, velocity: 70, onset: 0.0, duration: 0.4),
        NoteEvent(pitch: 60, velocity: 70, onset: 1.0, duration: 0.4)
    ]
    expect(RestruckKeys.clip(clean) == clean, "a note released before its next strike is untouched")

    // Another pitch sounding through is not a re-strike.
    let otherPitch = [
        NoteEvent(pitch: 60, velocity: 70, onset: 0.0, duration: 2.0),
        NoteEvent(pitch: 64, velocity: 70, onset: 0.5, duration: 0.5)
    ]
    expect(RestruckKeys.clip(otherPitch) == otherPitch,
           "a different pitch struck underneath does not end a held note")

    // Two strikes a few milliseconds apart leave a stub, not a zero-length note.
    let instant = [
        NoteEvent(pitch: 60, velocity: 70, onset: 0.0, duration: 1.0),
        NoteEvent(pitch: 60, velocity: 70, onset: 0.004, duration: 0.5)
    ]
    expect(RestruckKeys.clip(instant)[0].duration >= RestruckKeys.floor,
           "a strike superseded at once keeps the minimum length")
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
    // The combine window itself: a rolled chord is one chord, and the window
    // the engraver folds rolls with is the option's own milliseconds.
    let options = SheetDraft.Options(bpm: 120, numerator: 4, denominator: 4)
    expect(SheetDraft.ticks(ms: 40, options: options) == 38, "40 ms is 38 ticks at 120 bpm")
}

do {
    // What the rhythm stage promises, on a performance of 3/4 waltzes: a bass
    // note on every downbeat, chords on the weak beats, and a melody held over
    // the moving inner part. Every voice must tile every measure exactly —
    // that is the invariant the whole engraver leans on — and what is drawn
    // must be the value the engraver decided.
    let options = SheetDraft.Options(bpm: 120, numerator: 3, denominator: 4)
    var notes: [NoteEvent] = []
    for bar in 0..<4 {
        let start = Double(bar) * 1.5          // 3/4 at 120 bpm
        notes.append(NoteEvent(pitch: 43, velocity: 90, onset: start, duration: 0.4))
        notes.append(NoteEvent(pitch: 55, velocity: 70, onset: start + 0.5, duration: 0.4))
        notes.append(NoteEvent(pitch: 59, velocity: 70, onset: start + 1.0, duration: 0.4))
        notes.append(NoteEvent(pitch: 79, velocity: 90, onset: start, duration: 1.4))
        notes.append(NoteEvent(pitch: 76, velocity: 70, onset: start + 1.0, duration: 0.4))
    }
    let waltz = SheetDraft.draft(notes: notes, options: options)
    let issues = SheetDraft.rhythmAudit(waltz)
    expect(issues.isEmpty, "every voice tiles its measure exactly: \(issues.prefix(3))")
}

do {
    // A value that would hide a beat is written as tied pieces: a note from
    // the first beat of 3/4 to the middle of the third is a half tied to an
    // eighth, never a dotted half that swallows the beat in between.
    let options = SheetDraft.Options(bpm: 120, numerator: 3, denominator: 4)
    let notes = [
        NoteEvent(pitch: 72, velocity: 80, onset: 0.0, duration: 1.25),
        NoteEvent(pitch: 74, velocity: 80, onset: 1.25, duration: 0.25),
    ]
    let split = SheetDraft.draft(notes: notes, options: options)
    let rooms = split.topTrack.compactMap { symbol -> (Int, Int)? in
        guard case .chord(let chord) = symbol, chord.notes.contains(where: { $0.pitch == 72 }) else { return nil }
        return (chord.startTicks, chord.endTicks - chord.startTicks)
    }
    expect(rooms.count == 2 && rooms[0] == (0, 960) && rooms[1] == (960, 240)
           && split.ties.count == 1,
           "a held value is split where it would hide a beat, and tied: \(rooms)")
}

do {
    // A note's value is the room it owns in its own voice, not the length the
    // player happened to hold. A key released a hair early still fills its
    // quarter; a key let go halfway through prints short and rests close the
    // bar behind it.
    let options = SheetDraft.Options(bpm: 120, numerator: 3, denominator: 4)
    let held = [
        NoteEvent(pitch: 72, velocity: 80, onset: 0.0, duration: 0.47),
        NoteEvent(pitch: 74, velocity: 80, onset: 0.5, duration: 0.47),
        NoteEvent(pitch: 76, velocity: 80, onset: 1.0, duration: 0.47),
    ]
    let full = SheetDraft.draft(notes: held, options: options)
    let quarters = full.topTrack.filter { symbol in
        if case .chord(let chord) = symbol { return chord.endTicks - chord.startTicks == 480 }
        return false
    }
    let detached = [
        NoteEvent(pitch: 72, velocity: 80, onset: 0.0, duration: 0.15),
        NoteEvent(pitch: 74, velocity: 80, onset: 0.5, duration: 0.5),
    ]
    let short = SheetDraft.draft(notes: detached, options: options)
    let shortValues = short.topTrack.compactMap { symbol -> Int? in
        guard case .chord(let chord) = symbol else { return nil }
        return chord.endTicks - chord.startTicks
    }
    let restsAfter = short.topTrack.filter { symbol in
        if case .rest(_, let kind) = symbol { return kind == .eighth }
        return false
    }
    expect(quarters.count == 3 && shortValues.first == 120 && !restsAfter.isEmpty,
           "a value is the room a note owns: a hair-early lift fills its quarter, "
           + "a note let go early prints short with a rest closing the room (\(shortValues))")
}

do {
    // A file's tempo map, not its nominal tempo, is the notation clock: two
    // octaves of tempo apart, the same two attacks are a quarter apart in the
    // file's ticks and an eighth apart once the seconds are read at a single
    // tempo. The sheet must engrave the file's own reading.
    let map = SheetDraft.TimeMap(ticksPerQuarter: 480,
                                 tempoChanges: [(tick: 0, bpm: 120), (tick: 1920, bpm: 60)])
    let first = map.seconds(at: 1920)
    let second = map.seconds(at: 2400)
    let options = SheetDraft.Options(bpm: 120, numerator: 4, denominator: 4)
    let notes = [
        NoteEvent(pitch: 72, velocity: 80, onset: first, duration: second - first),
        NoteEvent(pitch: 74, velocity: 80, onset: second, duration: 0.4),
    ]
    let filed = SheetDraft.draft(notes: notes, options: options, originTicks: 0, timeMap: map)
    let plain = SheetDraft.draft(notes: notes, options: options)
    func room(_ result: SheetDraft.Result) -> Int? {
        result.topTrack.compactMap { symbol -> Int? in
            guard case .chord(let chord) = symbol, chord.notes.contains(where: { $0.pitch == 72 }) else { return nil }
            return chord.endTicks - chord.startTicks
        }.first
    }
    expect(room(filed) == 480 && room(plain) == 960,
           "the file's own tempo map sets the room between attacks (\(room(filed) ?? -1) vs \(room(plain) ?? -1))")
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
    // Hands: a chord is one grip, so it prints on one staff.
    let triad = SheetDraft.divideGrip([60, 64, 67])
    expect(triad.top.count == 3 && triad.bottom.isEmpty,
           "a C major triad around middle C is one grip on the upper staff")
    let lowTriad = SheetDraft.divideGrip([48, 52, 55])
    expect(lowTriad.bottom.count == 3 && lowTriad.top.isEmpty,
           "a low triad stays whole on the lower staff")
    // A bass note under a melody note is two hands, and divides at the gap.
    let spread = SheetDraft.divideGrip([40, 76])
    expect(spread.bottom == [0] && spread.top == [1],
           "a bass note under a melody note divides between the hands")
    // A close chord is never torn: four notes within an octave stay together.
    let close = SheetDraft.divideGrip([59, 62, 65, 67])
    expect(close.top.count == 4 || close.bottom.count == 4,
           "a close four-note grip prints on one staff")
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
    // A MIDI file's own measure grid is the notation: an upbeat prints as the
    // rest in front of it instead of pulling the first barline onto the first
    // attack. Two quarter notes on beats two and three, in 3/4, from tick 0.
    do {
        let options = SheetDraft.Options(bpm: 120, numerator: 3, denominator: 4)
        let upbeat = [
            NoteEvent(pitch: 64, velocity: 80, onset: 0.5, duration: 0.5),
            NoteEvent(pitch: 67, velocity: 80, onset: 1.0, duration: 0.5),
        ]
        let filed = SheetDraft.draft(notes: upbeat, options: options, originTicks: 0)
        let firstRow = filed.rows[0]
        var sawPickupRest = false
        var firstChordTick: Int?
        for placed in firstRow.top {
            if case .rest(let tick, let kind) = placed.symbol, tick == 0, kind == .quarter {
                sawPickupRest = true
            }
            if case .chord(let chord) = placed.symbol, firstChordTick == nil {
                firstChordTick = chord.startTicks
            }
        }
        expect(sawPickupRest, "a file grid puts the upbeat behind a quarter rest")
        expect(firstChordTick == 480, "the file grid keeps the first chord on beat two")
        let loose = SheetDraft.draft(notes: upbeat, options: options)
        var looseChordTick: Int?
        for placed in loose.rows[0].top {
            if case .chord(let chord) = placed.symbol, looseChordTick == nil {
                looseChordTick = chord.startTicks
            }
        }
        expect(looseChordTick == 0, "a performance starts its bar on the first attack instead")
    }

    let sixteenthGap = SheetDraft.rests(start: 0, end: 120)
    expect(sixteenthGap == [.rest(startTicks: 0, kind: .sixteenth)],
           "a sixteenth gap draws a sixteenth rest, so the bar still adds up")
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
        // held for its eighth: the value now comes from the room a note owns,
        // so a clipped attack would honestly print as a sixteenth
        events.append(NoteEvent(pitch: 72, velocity: 80, onset: onset, duration: 0.25))
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
    // Four eighths on beats one and two: two beams, one per beat, and no
    // eighth left carrying a lone flag that nobody can read.
    expect(result.beamGroups.map(\.chordIndices.count) == [2, 2],
           "four eighths beam as two beats of pairs")
    expect(beamedChords.count == 4, "every eighth of a beat is beamed")
}

do {
    // The empty stream still produces a framed empty row.
    let result = SheetDraft.draft(notes: [], options: SheetDraft.Options())
    expect(result.rows.count == 1 && result.rows[0].showsFraming, "an empty stream draws one empty row")
    expect(result.fifths == 0, "no notes guess the key of C")
}

declaredKey: do {
    // A published MIDI states its key; guessing over it prints D flat major as
    // a page of sharps and naturals. The declared signature wins.
    var events: [NoteEvent] = []
    for i in 0..<8 {
        events.append(NoteEvent(pitch: [70, 72, 74, 75, 77, 70, 72, 74][i],
                                velocity: 80,
                                onset: Double(i) * 0.5,
                                duration: 0.45))
    }
    let options = SheetDraft.Options(bpm: 120, numerator: 4, denominator: 4)
    let guessed = SheetDraft.draft(notes: events, options: options)
    let declared = SheetDraft.draft(notes: events, options: options, declaredFifths: -5)
    expect(guessed.fifths != -5, "the notes alone do not spell D flat major")
    expect(declared.fifths == -5, "a declared key signature is honoured")
    expect(SheetLayoutFiveFlats(declared), "the key signature draws five flats")
}

do {
    // The staves divide at middle C, the way an edition divides them. A wide
    // grip is both hands: everything below middle C is the lower staff's, the
    // rest is the upper staff's. Nothing below middle C may be printed under
    // the treble staff — that is the ink that put a bass note six ledger lines
    // below the staff it was hung from.
    let options = SheetDraft.Options(bpm: 120, numerator: 4, denominator: 4)
    let grip = [43, 53, 57, 62].map { pitch in
        NoteEvent(pitch: pitch, velocity: 80, onset: 0, duration: 2.0)
    }
    let result = SheetDraft.draft(notes: grip, options: options)
    func pitches(_ placed: [SheetDraft.Placed]) -> [Int] {
        placed.compactMap { item in
            if case .chord(let chord) = item.symbol { return chord.notes.map(\.pitch) }
            return nil
        }.flatMap { $0 }
    }
    let bass = pitches(result.rows[0].bottom)
    let treble = pitches(result.rows[0].top)
    expect(bass.sorted() == [43, 53, 57], "the left hand's notes stay on the bass staff: \(bass.sorted())")
    expect(treble.sorted() == [62], "the note at middle C is the right hand's: \(treble.sorted())")
    expect(!treble.contains { $0 < SheetDraft.middleC },
           "no note below middle C is printed on the treble staff")
}

do {
    // Two hands hit one instant: a bass note under a chord reaching past two
    // octaves is not one chord. One rule decides the staff — the grip goes
    // whole to the staff it reads on, and only a grip that reads on neither is
    // divided, at a gap both halves read across.
    func sides(_ pitches: [Int]) -> ([Int], [Int]) {
        let grip = SheetDraft.divideGrip(pitches)
        return (grip.top.map { pitches[$0] }, grip.bottom.map { pitches[$0] })
    }
    let split = sides([40, 60, 64, 67])
    expect(split.0.sorted() == [60, 64, 67] && split.1 == [40],
           "a bass note under a chord is read as two hands: \(split)")
    let triad = sides([60, 64, 67])
    expect(triad.0.sorted() == [60, 64, 67] && triad.1.isEmpty,
           "a triad reads whole on one staff and is never torn")
    let wide = sides([43, 67, 71, 74])
    expect(wide.1 == [43] && wide.0.sorted() == [67, 71, 74],
           "a grip that hangs off the bass staff is divided where it reads: \(wide)")
    let reading = sides([57, 60, 64, 67])
    expect(reading.0.sorted() == [57, 60, 64, 67] && reading.1.isEmpty,
           "a chord that reads whole on the treble staff is never split")
    let hanging = sides([55, 59, 62, 65])
    expect(hanging.1.isEmpty && hanging.0.sorted() == [55, 59, 62, 65],
           "a grip inside an octave is one hand's shape and prints whole: \(hanging)")
    let lowBroken = sides([31, 43])
    expect(lowBroken.0.isEmpty && lowBroken.1.sorted() == [31, 43],
           "two low notes both belong to the lower staff: \(lowBroken)")
    let options = SheetDraft.Options(bpm: 120, numerator: 4, denominator: 4)
    let grip = [40, 60, 64, 67].map { pitch in
        NoteEvent(pitch: pitch, velocity: 80, onset: 0, duration: 2.0)
    }
    let result = SheetDraft.draft(notes: grip, options: options)
    func printed(_ placed: [SheetDraft.Placed]) -> [Int] {
        placed.compactMap { item in
            if case .chord(let chord) = item.symbol { return chord.notes.map(\.pitch) }
            return nil
        }.flatMap { $0 }
    }
    expect(printed(result.rows[0].bottom) == [40],
           "the bass note of a split instant stays on the bass staff")
    expect(printed(result.rows[0].top).sorted() == [60, 64, 67],
           "the chord of a split instant stays on the treble staff")
}

/// The drawn key signature, read off the row the way a player reads it.
private func SheetLayoutFiveFlats(_ result: SheetDraft.Result) -> Bool {
    ScoreLayout.keyGlyphs(result.fifths).filter { $0.accidental == .flat }.count == 5
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
    // A pedal span is drawn as the pedal: "Ped." where it goes down, the
    // release star where it lifts, a line between. What it may never do is
    // move a note, change a value or alter a bar, so the notes stay exactly
    // what they were without it.
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
    // A release and a press a few milliseconds apart are one held pedal: the
    // score prints one "Ped.", not two.
    let stuttered = PedalSpans.merged([(start: 1.0, end: 2.0), (start: 2.02, end: 3.0),
                                       (start: 6.0, end: 7.0)])
    expect(stuttered.count == 2, "a stuttered pedal reads as one pedal")
    expect(stuttered.first.map { abs($0.end - 3.0) < 1e-9 } == true,
           "the merged pedal lasts until the player really lifted")
    expect(stuttered.last.map { abs($0.start - 6.0) < 1e-9 } == true,
           "a pedal pressed later stays its own pedal")

    // The marks live in the layout, because that is where their x is decided:
    // a pedal sits between two columns, not on one.
    var downs = 0
    var ups = 0
    for placed in pedalled.rows.flatMap(\.bottom) {
        if case .pedalDown = placed.symbol { downs += 1 }
        if case .pedalUp = placed.symbol { ups += 1 }
    }
    expect(downs == 1 && ups == 1, "one span prints one pedal mark and one release, got \(downs)/\(ups)")
    expect(pedalled.topTrack == plain.topTrack, "the pedal leaves the treble untouched")
    let bassNotes = { (result: SheetDraft.Result) in
        result.bottomTrack.filter { if case .chord = $0 { return true } else { return false } }
    }
    expect(bassNotes(pedalled) == bassNotes(plain), "the pedal leaves the bass notes untouched")
    expect(pedalled.ties == plain.ties, "the pedal neither adds nor removes a tie")
    expect(pedalled.beamGroups == plain.beamGroups, "the pedal leaves the beaming alone")}

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
        NoteEvent(pitch: 72, velocity: 80, onset: 0.0, duration: 3.6),
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

// MARK: take description

do {
    // a I-V-vi-IV take in C major, one chord a bar at 100 bpm
    var progression: [NoteEvent] = []
    let chords = [[60, 64, 67], [55, 59, 62], [57, 60, 64], [53, 57, 60]]
    let bar = 2.4
    for (index, chord) in chords.enumerated() {
        for pitch in chord {
            progression.append(NoteEvent(pitch: pitch, velocity: 80,
                                         onset: Double(index) * bar, duration: bar * 0.9))
        }
    }
    if let described = TakeAnalysis.describe(notes: progression) {
        expect(described.keyName == "C major", "a I-V-vi-IV take reads as C major, got \(described.keyName)")
        expect(abs(described.tempoBPM - 100) < 6, "the pulse reads near 100 bpm, got \(described.tempoBPM)")
        expect(described.lines.contains { $0.caption == "Harmony" }, "the description names its harmonic rhythm")
        expect(described.summary.contains("C major"), "the one-line summary carries the key")
    } else {
        expect(false, "a four-chord take produces a description")
    }

    // silence splits phrases, and the closing chord decides the cadence
    var phrased: [NoteEvent] = []
    for (index, pitch) in [72, 71, 69, 67].enumerated() {
        phrased.append(NoteEvent(pitch: pitch, velocity: 70, onset: Double(index) * 0.5, duration: 0.4))
    }
    phrased.append(NoteEvent(pitch: 60, velocity: 70, onset: 6.0, duration: 1.6))
    phrased.append(NoteEvent(pitch: 64, velocity: 70, onset: 6.0, duration: 1.6))
    phrased.append(NoteEvent(pitch: 67, velocity: 70, onset: 6.0, duration: 1.6))
    if let described = TakeAnalysis.describe(notes: phrased) {
        let phraseLine = described.lines.first { $0.caption == "Phrases" }?.value ?? ""
        expect(phraseLine.contains("2 phrases"), "a long silence splits the take into two phrases, got \(phraseLine)")
        let cadenceLine = described.lines.first { $0.caption == "Cadences" }?.value ?? ""
        expect(cadenceLine.contains("1 on the tonic"), "a closing C major chord reads as a tonic cadence, got \(cadenceLine)")
    } else {
        expect(false, "a phrased take produces a description")
    }

    // a minor take stays minor
    if let described = TakeAnalysis.describe(notes: [
        NoteEvent(pitch: 57, velocity: 80, onset: 0, duration: 1),
        NoteEvent(pitch: 60, velocity: 80, onset: 0, duration: 1),
        NoteEvent(pitch: 64, velocity: 80, onset: 0, duration: 1),
        NoteEvent(pitch: 55, velocity: 80, onset: 1, duration: 1),
        NoteEvent(pitch: 59, velocity: 80, onset: 1, duration: 1),
        NoteEvent(pitch: 62, velocity: 80, onset: 1, duration: 1),
        NoteEvent(pitch: 57, velocity: 80, onset: 2, duration: 1),
    ]) {
        expect(described.isMinor, "an A minor cadence reads as minor, got \(described.keyName)")
    }

    expect(TakeAnalysis.describe(notes: []) == nil, "an empty take has no description")
}

// MARK: the chord sheet

do {
    // a C major triad, then a G7 sharing one strike, then a bare two-note
    // interval that spells nothing
    let take = [
        NoteEvent(pitch: 60, velocity: 80, onset: 0.00, duration: 1),
        NoteEvent(pitch: 64, velocity: 80, onset: 0.02, duration: 1),
        NoteEvent(pitch: 67, velocity: 80, onset: 0.03, duration: 1),
        NoteEvent(pitch: 55, velocity: 80, onset: 1.00, duration: 1),
        NoteEvent(pitch: 59, velocity: 80, onset: 1.01, duration: 1),
        NoteEvent(pitch: 62, velocity: 80, onset: 1.02, duration: 1),
        NoteEvent(pitch: 65, velocity: 80, onset: 1.03, duration: 1),
        NoteEvent(pitch: 72, velocity: 80, onset: 2.00, duration: 1),
        NoteEvent(pitch: 76, velocity: 80, onset: 2.01, duration: 1),
    ]
    let sheet = ChordSheet.entries(for: take)
    expect(sheet.count == 2, "two of the three strikes spell a chord, got \(sheet.count)")
    expect(sheet.first?.chord.root == "C", "the sheet opens on C, got \(sheet.first?.chord.root ?? "-")")
    expect(sheet.last?.chord.root == "G", "the dominant reads as G, got \(sheet.last?.chord.root ?? "-")")
    expect(sheet.last?.chord.quality.name == "7", "the dominant keeps its seventh")
    expect(sheet.first?.onset == 0.0, "an entry sits on its group's first onset")
    expect(ChordSheet.entries(for: []).isEmpty, "an empty take has an empty sheet")

    // the sheet agrees with the per-group read it replaces
    let grouped = take.assignOnsetGroups()
    let groups = Set(grouped.map(\.onsetGroup)).sorted()
    let legacy = groups.compactMap { Chord.identify(in: grouped, group: $0) }
    expect(legacy.map(\.root) == sheet.map(\.chord.root), "the one-pass sheet matches the filtered read")
}

// MARK: the streaming pace

do {
    let cheap = { () -> DecodePacer in
        DecodePacer(floorStep: 0.5, ceilingStep: 4.0)
    }
    var fast = cheap()
    var step = fast.record(wall: 0.20, backlog: 0.1, decoders: 2)
    expect(abs(step - 0.5) < 1e-9, "a fast machine stays at the plan's floor, got \(step)")

    // one slow machine: the floor moves up to what it can sustain
    var slow = cheap()
    step = slow.record(wall: 3.0, backlog: 3.0, decoders: 2)
    expect(step >= 3.0 / 2 * 1.15 - 1e-9, "a 3 s decode across two decoders lifts the pace, got \(step)")
    expect(step <= 4.0, "the pace never passes the ceiling, got \(step)")
    for _ in 0..<40 { _ = slow.record(wall: 3.0, backlog: 3.0, decoders: 2) }
    expect(abs(slow.step - 4.0) < 1e-9, "a pile-up pushes the pace to the ceiling, got \(slow.step)")

    // the same decode on one decoder: no pretending two run at once
    var single = cheap()
     _ = single.record(wall: 3.0, backlog: 2.0, decoders: 1)
    expect(single.step >= 3.0 * 1.15 - 1e-9, "one decoder lifts the pace further, got \(single.step)")

    // an idle pipeline buys resolution back, but never past its floor
    var idle = DecodePacer(floorStep: 0.5, ceilingStep: 4.0)
    for _ in 0..<80 { _ = idle.record(wall: 0.2, backlog: 0.05, decoders: 2) }
    expect(abs(idle.step - 0.5) < 1e-9, "an idle pipeline returns to the floor, got \(idle.step)")
}

// MARK: note lengths from the audio

do {
    // a lone C4 held two seconds, left to die into the room: the model calls
    // this a 50 ms blip (measured on the sample renderer), the audio says the
    // note is still sounding at 2 s
    let rate = 44100.0
    let seconds = 4.0
    let count = Int(rate * seconds)
    var signal = [Float](repeating: 0, count: count)
    let f0 = 261.63
    for index in 0..<count {
        let t = Double(index) / rate
        guard t >= 0.5, t < 2.5 else { continue }
        // six harmonics, decaying the way a struck string does
        let age = t - 0.5
        let envelope = Float(exp(-age * 1.1)) * 0.28
        var sample: Float = 0
        for harmonic in 1...6 {
            sample += Float(sin(2 * Double.pi * f0 * Double(harmonic) * t)) * envelope / Float(harmonic)
        }
        signal[index] = sample
    }
    // the room is never digital silence
    var seed: UInt64 = 12345
    for index in 0..<count {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let noise = Float(Int64(bitPattern: seed >> 33) % 1000) / 1_000_000
        signal[index] += noise
    }

    let refiner = NoteLengthRefiner(rate: rate)
    let blip = NoteLengthRefiner.Span(pitch: 60, onset: 0.5, offset: 0.547, hasOffset: true)
    let refined = refiner.refine([blip], samples: signal, windowBegin: 0)
    expect(refined.count == 1, "one span in, one span out")
    expect(refined[0].offset > 2.0, "a held note that dies away is followed to 2 s, got \(refined[0].offset)")
    expect(refined[0].offset < 2.75, "and not a frame past where the sound stopped, got \(refined[0].offset)")

    // the negative: the same band never stops sounding, so nothing is proven
    // and the model's end stands
    var held = signal
    for index in 0..<count {
        let t = Double(index) / rate
        guard t >= 0.5 else { continue }
        held[index] += Float(sin(2 * Double.pi * f0 * t)) * 0.2
    }
    let steady = refiner.refine([blip], samples: held, windowBegin: 0)
    expect(abs(steady[0].offset - blip.offset) < 1e-9,
           "a note that never stops sounding keeps the model's end, got \(steady[0].offset)")

    // a span the model already gave a length is untouched by the default pass
    let plausible = NoteLengthRefiner.Span(pitch: 60, onset: 0.5, offset: 2.4, hasOffset: true)
    let kept = refiner.refine([plausible], samples: signal, windowBegin: 0)
    expect(abs(kept[0].offset - 2.4) < 1e-9, "a plausible length is left alone")
}

// MARK: a bar holds what its meter holds

do {
    // The meter's capacity: one column for every grid step the bar has room
    // for. A 4/4 bar holds sixteen sixteenths, a 3/4 bar twelve, a 2/4 bar
    // eight — and a 3/4 bar at an eighth grid holds six.
    let four = SheetDraft.Meter(numerator: 4, denominator: 4)
    let three = SheetDraft.Meter(numerator: 3, denominator: 4)
    let two = SheetDraft.Meter(numerator: 2, denominator: 4)
    expect(four.capacity(grid: 120) == 16, "4/4 holds sixteen sixteenths")
    expect(three.capacity(grid: 120) == 12, "3/4 holds twelve sixteenths")
    expect(three.capacity(grid: 240) == 6, "3/4 holds six eighths")
    expect(two.capacity(grid: 120) == 8, "2/4 holds eight sixteenths")
    expect(two.capacity(grid: 120) == two.capacity(grid: 120),
           "capacity is the meter's own number, not a running guess")
}

do {
    // A bar can be handed more attacks than its meter can print — a roll, a
    // fast run read at a fine grid, two hands landing in one slot. What comes
    // out is still a bar: never more columns than the meter has room for, and
    // every column a column the bar can write.
    let options = SheetDraft.Options(bpm: 120, numerator: 2, denominator: 4)
    let capacity = SheetDraft.Meter(options).capacity(grid: 120)
    var events: [NoteEvent] = []
    // twenty attacks inside one 2/4 bar: more than its eight slots
    for index in 0..<20 {
        events.append(NoteEvent(pitch: 60 + index % 5, velocity: 80,
                                onset: Double(index) * 0.012, duration: 0.1))
    }
    let crowded = SheetDraft.draft(notes: events, options: options)
    var columnsInFirstBar = 0
    for placed in crowded.rows[0].top {
        guard case .chord(let chord) = placed.symbol else { continue }
        if chord.startTicks < options.measureTicks { columnsInFirstBar += 1 }
    }
    for placed in crowded.rows[0].bottom {
        guard case .chord(let chord) = placed.symbol else { continue }
        if chord.startTicks < options.measureTicks { columnsInFirstBar += 1 }
    }
    expect(columnsInFirstBar <= 2 * capacity,
           "a bar prints no more columns than its meter holds: \(columnsInFirstBar)")
}

do {
    // The room an accidental takes is the stack's own width, so a chord that
    // needs two sharps is priced wider than the same chord in a key that
    // already carries them. The proof the reader sees: fewer bars fit on the
    // first line when every chord has to spell its accidentals.
    let inKey = SheetDraft.Options(bpm: 120, numerator: 4, denominator: 4)
    var events: [NoteEvent] = []
    for bar in 0..<12 {
        let start = Double(bar) * 2.0
        for beat in 0..<4 {
            let onset = start + Double(beat) * 0.5
            events.append(NoteEvent(pitch: 61, velocity: 80, onset: onset, duration: 0.4))
            events.append(NoteEvent(pitch: 66, velocity: 80, onset: onset, duration: 0.4))
        }
    }
    let spelled = SheetDraft.draft(notes: events, options: inKey, declaredFifths: 0)
    let carried = SheetDraft.draft(notes: events, options: inKey, declaredFifths: 3)
    func bars(_ result: SheetDraft.Result) -> Int {
        result.rows[0].top.filter { if case .bar = $0.symbol { return true }; return false }.count
    }
    expect(bars(spelled) < bars(carried),
           "sharps that the key does not carry cost their own room: \(bars(spelled)) vs \(bars(carried))")
    let stack = AccidentalInk.width([(0, .sharp), (2, .sharp)])
    let single = AccidentalInk.width([(0, .sharp)])
    expect(stack > single, "two sharps stand in two columns and take more room than one")
    expect(AccidentalInk.columns([(0, .sharp), (2, .sharp), (9, .sharp)]) == [0, 1, 0],
           "sharps a second apart take different columns, far ones share")
}

// MARK: a system stands clear of the one above it

do {
    // The pitch between two systems is measured from the ink, not assumed: a
    // draft that climbs six ledger lines over the treble needs more room than
    // one that stays on the staff, or its ledger lines print in the bass staff
    // of the system above.
    let options = SheetDraft.Options(bpm: 120, numerator: 4, denominator: 4)
    func draft(_ pitches: [Int]) -> SheetDraft.Result {
        var events: [NoteEvent] = []
        for bar in 0..<3 {
            for pitch in pitches {
                events.append(NoteEvent(pitch: pitch, velocity: 80,
                                        onset: Double(bar) * 2.0, duration: 1.5))
            }
        }
        return SheetDraft.draft(notes: events, options: options)
    }
    // a chord around the middle of the staff, then the same piece played with
    // a left hand on the bottom of the keyboard and a right hand at the top
    let plain = draft([60, 64, 67])
    let wide = draft([26, 60, 64, 67, 100])
    // Two staves and the air an edition keeps between systems: the five
    // spaces of the grand staff's own gap, eight lines of staff, and eight
    // spaces of air. Fifteen spaces of air printed a page of lines floating
    // in blank paper; the reference editions keep about eight.
    expect(plain.rowHeight >= 21,
           "a system keeps the air of an engraved page: \(plain.rowHeight)")
    expect(wide.rowHeight > plain.rowHeight,
           "a system whose hands reach both ends of the keyboard stands wider: \(wide.rowHeight) vs \(plain.rowHeight)")
    expect(wide.totalHeight > plain.totalHeight,
           "and the page grows with it")
}

// MARK: the MIDI reader's refusals

do {
    // format 2 is a set of independent songs, not one timeline
    var data = Data("MThd".utf8)
    data.append(contentsOf: [0, 0, 0, 6])
    data.append(contentsOf: [0, 2])       // format 2
    data.append(contentsOf: [0, 1])       // one track
    data.append(contentsOf: [1, 0xE0])    // 480 ticks per quarter
    var refused = false
    do { _ = try MidiReader.read(data) } catch { refused = true }
    expect(refused, "a format 2 file is refused instead of flattened")

    // and a good header still reads
    var good = Data("MThd".utf8)
    good.append(contentsOf: [0, 0, 0, 6])
    good.append(contentsOf: [0, 0])       // format 0
    good.append(contentsOf: [0, 0])       // no tracks
    good.append(contentsOf: [1, 0xE0])
    let empty = try? MidiReader.read(good)
    expect(empty != nil, "a well formed header still reads")
}

// MARK: the LilyPond page

lilyPondPage: do {
    func score(_ measures: [[ScoreNote]], bpm: Double = 96,
               beats: Int = 4, unit: Int = 4,
               tonic: Int = 0, minor: Bool = false) -> Score {
        let framing = ScoreFraming(beatsPerMinute: bpm,
                                   timeSignature: TimeSignature(beatsPerMeasure: beats, beatUnit: unit),
                                   key: KeySignature(tonic: tonic, isMinor: minor))
        let ticks = framing.timeSignature.ticksPerMeasure
        let built = measures.enumerated().map { index, notes in
            ScoreMeasure(index: index, startTick: index * ticks, notes: notes)
        }
        return Score(framing: framing, measures: built, chords: [])
    }

    func note(_ pitch: Int, _ onset: Int, _ duration: Int) -> ScoreNote {
        ScoreNote(pitch: pitch, onsetTick: onset, durationTicks: duration, velocity: 80)
    }

    /// One staff's lines out of the file, without the framing commands.
    func staff(_ source: String, clef: String) -> [String] {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains("\\clef \(clef)") }) else { return [] }
        var body: [String] = []
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "}" { break }
            if trimmed.isEmpty { continue }
            // a bar can open with a dynamic, which says how loud the bar is
            // rather than what is in it; the note content is what these
            // checks are about
            var parts = trimmed.components(separatedBy: " ")
            if let first = parts.first, ["\\pp", "\\p", "\\mp", "\\mf", "\\f", "\\ff"].contains(first) {
                parts.removeFirst()
            }
            body.append(parts.joined(separator: " "))
        }
        return body
    }

    func bars(_ source: String, clef: String) -> [String] {
        staff(source, clef: clef).filter { $0.contains("|") }
    }

    let lengths: [(suffix: String, ticks: Int)] = [
        ("\\breve.", 5760), ("\\breve", 3840),
        ("64", 30), ("32.", 90), ("32", 60), ("16.", 180), ("16", 120),
        ("8.", 360), ("8", 240), ("4.", 720), ("4", 480),
        ("2.", 1440), ("2", 960), ("1.", 2880), ("1", 1920),
    ]

    /// A token's length: a note carries it as a suffix, a rest behind its r,
    /// and a tie hangs a tilde on the end.
    func ticks(_ token: String) -> Int? {
        var body = token
        if body.hasSuffix("~") { body.removeLast() }
        if body.hasPrefix("r") { body.removeFirst() }
        for length in lengths where body.hasSuffix(length.suffix) {
            return length.ticks
        }
        return nil
    }

    /// The tokens of one bar, keeping a chord in angle brackets together.
    func tokens(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var depth = 0
        for character in line {
            if character == "<" { depth += 1 }
            if character == ">" { depth -= 1 }
            if character == " ", depth == 0 {
                if !current.isEmpty { result.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// What one bar of the file actually adds up to.
    func barTicks(_ line: String) -> Int {
        var total = 0
        for token in tokens(line) {
            if token.hasPrefix("\\") || token.hasPrefix("\"") || token.hasPrefix("|") { continue }
            total += ticks(token) ?? -100_000
        }
        return total
    }

    // A four bar line, one note to the beat: the page has to name the version,
    // the key, the meter and the tempo before the first bar, and the right
    // hand has to read as the notes that were played.
    let line = score([[note(60, 0, 480), note(62, 480, 480), note(64, 960, 480), note(65, 1440, 480)]])
    let text = LilyPondScore.text(line, metadata: LilyPondScore.Metadata(title: "Je te veux", composer: "Satie"))
    expect(text.contains("\\version \"2.26.0\""), "the page names the engraver's version")
    expect(text.contains("\\header {"), "the page carries a heading")
    expect(text.contains("title = \"Je te veux\""), "the title travels into the heading")
    expect(text.contains("\\key c \\major"), "C major is written as LilyPond writes it")
    expect(text.contains("\\time 4/4 \\tempo 4 = 96"), "the meter and tempo stand on one line")
    expect(!text.contains("\\new PianoStaff <<"),
           "a take that only used the right hand prints one staff, not a pair")
    expect(staff(text, clef: "treble") == ["\\key c \\major", "\\time 4/4 \\tempo 4 = 96",
                                           "\\set Timing.beamExceptions = #'()",
                                           "\\set Timing.baseMoment = #(ly:make-moment 1/4)",
                                           "\\set Timing.beatStructure = 1,1,1,1",
                                           "c'4 d'4 e'4 f'4 | \\bar \"|.\""],
           "the right hand reads as its notes: \(staff(text, clef: "treble"))")
    expect(bars(text, clef: "bass").isEmpty,
           "the hand that played nothing has no bars to print: \(bars(text, clef: "bass"))")
    let bothHands = LilyPondScore.text(score([[note(60, 0, 480), note(48, 0, 960)]]))
    expect(bothHands.contains("\\new PianoStaff <<"),
           "a take with both hands is a staff pair")
    expect(bars(bothHands, clef: "bass").first?.hasPrefix("c2") == true,
           "and the left hand prints under it: \(bars(bothHands, clef: "bass"))")

    // Middle C is the divide: a line played either side of it belongs to two
    // staves, and the octave marks count away from it.
    let split = LilyPondScore.text(score([[note(60, 0, 960), note(59, 0, 960)]]))
    expect(staff(split, clef: "treble").last?.hasPrefix("c'2") == true,
           "middle C is the right hand's")
    expect(staff(split, clef: "bass").last?.hasPrefix("b2") == true,
           "the note below it is the left hand's")

    // Pitches struck at one instant are one chord. A note that lands on the
    // next sixteenth is its own attack, not a member of that chord: folding a
    // grid cell turned every run into a cluster nobody played.
    let chord = LilyPondScore.text(score([[note(60, 0, 480), note(64, 0, 480),
                                           note(67, 0, 480), note(71, 0, 480)]]))
    expect(staff(chord, clef: "treble").last?.hasPrefix("<c' e' g' b'>4") == true,
           "a chord prints as one chord: \(staff(chord, clef: "treble"))")
    expect(barTicks(bars(chord, clef: "treble")[0]) == 1920,
           "and the bar it sits in still counts four beats")
    let run = LilyPondScore.text(score([[note(72, 0, 120), note(74, 120, 120),
                                          note(76, 240, 120)]]))
    expect(staff(run, clef: "treble").last?.hasPrefix("c''16 d''16 e''16") == true,
           "a run stays a run: \(staff(run, clef: "treble"))")

    // Every bar of the page has to count its meter, whatever was played: the
    // gaps become rests, a note that runs into the barline is cut there, and a
    // note a hair before the barline still belongs to the bar it was played in.
    let messy = score([
        [note(67, 0, 240), note(69, 120, 120), note(72, 720, 480), note(74, 1680, 120)],
        [note(60, 1920, 240), note(62, 2160, 240), note(65, 2520, 960)],
        [note(67, 3960, 120)],
    ])
    let messyText = LilyPondScore.text(messy)
    for clef in ["treble", "bass"] {
        for (index, bar) in bars(messyText, clef: clef).enumerated() {
            expect(barTicks(bar) == 1920,
                   "bar \(index + 1) of the \(clef) counts its meter: \(barTicks(bar)) — \(bar)")
        }
    }
    expect(bars(messyText, clef: "treble")[0].hasSuffix("~ | \\bar \"|.\"") == false,
           "no tie leaves the last bar")
    let held = LilyPondScore.text(score([[note(62, 480, 240), note(60, 1440, 960)],
                                         [note(64, 2400, 480)]]))
    expect(bars(held, clef: "treble")[0].contains("c'4~"),
           "a note held over the barline is tied: \(bars(held, clef: "treble"))")
    expect(bars(held, clef: "treble")[1].hasPrefix("c'4"),
           "and the tie lands on the same pitch in the next bar")

    // A meter that is not 4/4 counts its own way, and the page still totals it.
    var metered = true
    for (beats, unit) in [(3, 4), (6, 8), (2, 2), (5, 4)] {
        let page = LilyPondScore.text(score([[note(60, 0, 240), note(64, 240, 480)],
                                             [note(67, 960, 480)]],
                                            beats: beats, unit: unit))
        let rule = TimeSignature(beatsPerMeasure: beats, beatUnit: unit).ticksPerMeasure
        for bar in bars(page, clef: "treble") {
            if barTicks(bar) != rule { metered = false }
        }
    }
    expect(metered, "a page in any meter fills every bar exactly")

    // The key signature decides the spelling: the black key above C is a C
    // sharp in a sharp key and a D flat in a flat key.
    func spelling(_ pitch: Int, tonic: Int, minor: Bool = false) -> String {
        let page = LilyPondScore.text(score([[note(pitch, 0, 480)]], tonic: tonic, minor: minor))
        let line = staff(page, clef: "treble").last ?? ""
        // the bar starts with whatever the page commands it to, a dynamic
        // among them; the spelling is the first token that sounds
        return tokens(line).filter { !$0.hasPrefix("\\") }.first ?? ""
    }
    expect(spelling(61, tonic: 2).hasPrefix("cis'4"), "a sharp key spells 61 as C sharp")
    expect(spelling(61, tonic: 5).hasPrefix("des'4"), "a flat key spells the same key as D flat")
    expect(spelling(66, tonic: 10).hasPrefix("fis'4") || spelling(66, tonic: 10).hasPrefix("ges'4"),
           "a raised fourth is spelled, not dropped: \(spelling(66, tonic: 10))")

    // Dynamics come from the touch: a bar played loud says so, and the page
    // does not restate a level it is already holding.
    func dynamics(_ text: String) -> [String] {
        var found: [(offset: Int, mark: String)] = []
        for mark in ["\\pp", "\\p", "\\mp", "\\mf", "\\f", "\\ff"] {
            var cursor = text.startIndex
            while let range = text.range(of: " " + mark + " ", range: cursor..<text.endIndex) {
                found.append((text.distance(from: text.startIndex, to: range.lowerBound), mark))
                cursor = range.upperBound
            }
        }
        return found.sorted { $0.offset < $1.offset }.map(\.mark)
    }
    let steady = LilyPondScore.text(score([[note(60, 0, 480), note(62, 480, 480)]],
                                          beats: 4, unit: 4))
    expect(dynamics(steady) == ["\\mf"], "a steady touch prints one dynamic: \(dynamics(steady))")
    func touched(_ velocity: Int, _ index: Int) -> ScoreNote {
        ScoreNote(pitch: 60, onsetTick: index * 1920, durationTicks: 480, velocity: velocity)
    }
    let moved = LilyPondScore.text(score([[touched(40, 0)], [], [], [touched(100, 3)], [],
                                          [], [], [touched(40, 7)]]))
    let marks = dynamics(moved)
    expect(marks == ["\\pp", "\\f", "\\pp"],
           "quiet, loud and the return are each marked once: \(marks)")

    // The key names the circle of fifths knows, and a minor key is its own.
    func keyLine(_ tonic: Int, minor: Bool) -> String {
        LilyPondScore.text(score([], tonic: tonic, minor: minor))
            .components(separatedBy: "\n")
            .first { $0.contains("\\key ") }?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }
    expect(keyLine(0, minor: false) == "\\key c \\major", "C major is c major")
    expect(keyLine(5, minor: false) == "\\key f \\major", "F major is f major")
    expect(keyLine(10, minor: false) == "\\key bes \\major", "B flat major is bes major")
    expect(keyLine(6, minor: false) == "\\key fis \\major", "F sharp major is fis major")
    expect(keyLine(9, minor: true) == "\\key a \\minor", "A minor is a minor")
    expect(keyLine(1, minor: true) == "\\key cis \\minor", "D flat minor is cis minor, its enharmonic name")

    // The page ends with a full barline and only the last one.
    let three = LilyPondScore.text(score([[note(60, 0, 480)], [note(62, 0, 480)], [note(64, 0, 480)]]))
    let threeBars = bars(three, clef: "treble")
    expect(threeBars.count == 3, "three measures print three bars: \(threeBars.count)")
    expect(!threeBars[0].contains("\\bar") && threeBars[2].contains("\\bar \"|.\""),
           "only the last bar closes the page")

    // A title with a quote or a backslash must not break the file LilyPond has
    // to parse: they are Scheme strings.
    let tricky = LilyPondScore.text(line, metadata: LilyPondScore.Metadata(title: "L'après \"midi\"", composer: "C:\\temp"))
    expect(tricky.contains("title = \"L'après \\\"midi\\\"\""), "a quote in the title is escaped")
    expect(tricky.contains("composer = \"C:\\\\temp\""), "a backslash in the heading is escaped")
    expect(tricky.contains("\n}\n"), "the heading closes whatever it holds")
}

// MARK: the LilyPond page, the rules it is written by

lilyPondRules: do {
    func score(_ measures: [[ScoreNote]], bpm: Double = 96,
               beats: Int = 4, unit: Int = 4,
               tonic: Int = 0, minor: Bool = false) -> Score {
        let framing = ScoreFraming(beatsPerMinute: bpm,
                                   timeSignature: TimeSignature(beatsPerMeasure: beats, beatUnit: unit),
                                   key: KeySignature(tonic: tonic, isMinor: minor))
        let ticks = framing.timeSignature.ticksPerMeasure
        return Score(framing: framing,
                     measures: measures.enumerated().map { index, notes in
                         ScoreMeasure(index: index, startTick: index * ticks, notes: notes)
                     },
                     chords: [])
    }
    func note(_ pitch: Int, _ onset: Int, _ duration: Int) -> ScoreNote {
        ScoreNote(pitch: pitch, onsetTick: onset, durationTicks: duration, velocity: 80)
    }

    // A left-hand-only take is one bass staff: the old page gave every take a
    // grand staff and left the unused one full of whole rests.
    let bass = LilyPondScore.text(score([[note(48, 0, 480), note(50, 480, 480)]]))
    expect(bass.contains("\\clef bass"), "a left-hand take prints a bass staff")
    expect(!bass.contains("\\clef treble"), "and no treble staff it never played")
    expect(bass.contains("\\time 4/4 \\tempo 4 = 96"),
           "the meter and tempo stand on the staff that exists")

    // A pickup is its own short bar, declared as a partial. The notes before
    // the first downbeat used to be dropped by a truncating division.
    let pickup = Score(
        framing: ScoreFraming(beatsPerMinute: 120,
                              timeSignature: TimeSignature(beatsPerMeasure: 3, beatUnit: 4),
                              key: KeySignature(tonic: 0, isMinor: false)),
        measures: [
            ScoreMeasure(index: -1, startTick: -720, notes: [note(72, 0, 240), note(74, 240, 480)]),
            ScoreMeasure(index: 0, startTick: 720, notes: [note(76, 720, 480)]),
        ],
        chords: [])
    let pickupText = LilyPondScore.text(pickup)
    expect(pickupText.contains("\\partial 4."),
           "a pickup declares its own short bar")
    expect(pickupText.contains("c''8 d''4 |"),
           "and the notes before the downbeat are still on the page: \(pickupText.components(separatedBy: "\n").filter { $0.contains("|") })")
    expect(LilyPondScore.audit(pickup).isEmpty,
           "the pickup bar counts its own length: \(LilyPondScore.audit(pickup))")

    // A note held over several bars is written as a chain of ties, each piece
    // landing on the same pitch, never shortened.
    let long = LilyPondScore.text(score([[note(60, 0, 2400)]]))
    expect(long.contains("c'1~"),
           "a note longer than its bar is tied onward: \(long.components(separatedBy: "\n").filter { $0.contains("|") })")
    expect(LilyPondScore.audit(score([[note(60, 0, 2400)]]), text: long).isEmpty,
           "and every bar it crosses still counts four beats")

    // A value too long for one symbol splits into tied symbols inside the bar.
    let fiveFour = LilyPondScore.text(score([[note(60, 0, 2400)]], beats: 5, unit: 4))
    expect(fiveFour.contains("c'1~ c'4"),
           "a whole 5/4 bar of one note is a tied pair: \(fiveFour.components(separatedBy: "\n").filter { $0.contains("|") })")

    // The audit is the gate: it passes a legal page and refuses a broken one.
    let page = score([[note(60, 0, 480), note(64, 480, 480), note(67, 960, 480), note(72, 1440, 480)]])
    let pageText = LilyPondScore.text(page)
    expect(LilyPondScore.audit(page, text: pageText).isEmpty,
           "a legal page passes its own audit: \(LilyPondScore.audit(page, text: pageText))")
    let broken = pageText.replacingOccurrences(of: "c'4 e'4", with: "c'4 e'8")
    expect(!LilyPondScore.audit(page, text: broken).isEmpty,
           "a bar that lost a value is caught by the audit")

    // What the page promises as counts, for the eval and for the app.
    let chordScore = score([[note(60, 0, 480), note(64, 0, 480), note(67, 0, 480),
                             note(72, 0, 480), note(76, 960, 480)]])
    expect(LilyPondScore.headCount(chordScore) == 5, "five heads printed for five played notes")
    expect(LilyPondScore.summary(of: chordScore).widestChord == 4,
           "the widest chord is the four-note grip")
    expect(LilyPondScore.summary(of: chordScore).staves == 1,
           "and the page is one staff")
}

if failures == 0 {
    print("all \(checks) checks passed")
} else {
    print("\(failures) of \(checks) checks failed")
    exit(1)
}
