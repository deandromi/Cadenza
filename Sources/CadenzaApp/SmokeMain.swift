import AppKit
import AVFoundation
import CadenzaCore
import UniformTypeIdentifiers
import CoreML
import Foundation

enum SmokeMain {
    /// Live capture smoke: requests mic access, captures for ~24 s, prints
    /// level and note output. Exercises the permission flow, the tap and
    /// the ring without any UI.
    @MainActor
    static func runCapture() {
        let permission = AVAudioApplication.shared.recordPermission
        let permissionName: String
        switch permission {
        case .undetermined: permissionName = "undetermined"
        case .granted: permissionName = "granted"
        case .denied: permissionName = "denied"
        @unknown default: permissionName = "unknown"
        }
        print("permission before: \(permissionName)")
        guard let assets = AppDelegate.locateAssets() else {
            print("capture smoke: model assets not found")
            exit(1)
        }
        let engine = TranscriptionEngine()
        engine.onNoteEvent = { event, kind in
            let label: String
            switch kind {
            case .struck: label = "on"
            case .extended: label = "extend"
            case .released: label = "off"
            }
            print(String(format: "note %@: %d v%d @%.2f", label, event.pitch, event.velocity, event.onset))
        }
        engine.start(tensorsDir: assets.tensors, modelURL: assets.model)
        let began = Date()
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                let wall = Date().timeIntervalSince(began)
                print(String(format: "capture: wall %.1f s, content %.1f s, level %.4f, notes %d, running %@", wall, engine.capturedSeconds, engine.level, engine.noteCount, engine.isRunning ? "yes" : "no"))
                if let error = engine.lastError { print("error: \(error)") }
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(24))
        timer.invalidate()
        engine.stop()
        print(String(format: "capture smoke done: %d notes", engine.noteCount))
    }

    /// Offline replay of a recorded session through the engine's own
    /// windowing and merge logic, so a misbehaving session can be compared
    /// note for note against the Python reference on the exact same audio.
    /// - replay <file.f32> <deviceRate>: run() on every window with the same
    //    forced-start bookkeeping and the same merge rules as absorb().
    static func replayNotes(path: String, deviceRate: Double) -> [NoteEvent] {
        guard let assets = AppDelegate.locateAssets() else {
            print("replay: model assets not found")
            exit(1)
        }
        let data = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
        let input = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard !input.isEmpty else {
            print("replay FAILED: no samples in \(path)")
            exit(1)
        }
        print("replay: \(input.count) samples at \(Int(deviceRate)) Hz")

        let context: InferenceContext
        do {
            context = try InferenceContext(tensorsDir: assets.tensors, modelURL: assets.model)
        } catch {
            print("replay FAILED: \(error)")
            exit(1)
        }

        let tapState = AudioTapState()
        tapState.reset(rate: deviceRate)

        var lastP = Array(repeating: 0, count: WindowGeometry.symbols.count)
        var history: [NoteEvent] = []
        var liveIndex: [Int: Int] = [:]
        var windowIndex = 0
        var fed = 0  // how many samples of the recording have been fed

        while true {
            let startSeconds = Double(windowIndex) * WindowGeometry.stepWallSeconds - WindowGeometry.padSeconds
            let endSeconds = startSeconds + WindowGeometry.segmentSeconds
            let endSample = Int((endSeconds * deviceRate).rounded())
            if startSeconds * deviceRate >= Double(input.count) { break }
            Self.feed(tapState, from: input, fed: &fed, upTo: endSample)
            if fed < endSample && fed >= input.count {
                // recording over: let the engine's zero pad close the window
                tapState.append([Float](repeating: 0, count: endSample - fed))
                fed = endSample
            }
            guard let samples = tapState.takeWindow(index: windowIndex) else { break }

            let forcedStart: [Int]
            if windowIndex == 0 {
                forcedStart = Array(repeating: WindowGeometry.padFrames, count: WindowGeometry.symbols.count)
            } else {
                forcedStart = lastP.map { max($0 - WindowGeometry.stepFrames, 0) }
            }
            guard let result = context.run(windowIndex: windowIndex, edgeSeconds: Double(windowIndex) * WindowGeometry.stepWallSeconds
                                              - WindowGeometry.padSeconds + WindowGeometry.segmentSeconds,
                                          samples: samples,
                                          deviceRate: deviceRate,
                                          forcedStartPos: forcedStart) else {
                print("replay FAILED: window \(windowIndex) decode error")
                exit(1)
            }
            lastP = result.lastP
            print("replay: window \(windowIndex) decoded \(result.events.count) events")

            for event in result.events {
                var note = NoteEvent(pitch: event.pitch, velocity: event.velocity,
                                     onset: max(event.onsetSeconds, 0), duration: 0)
                note.duration = max(event.offsetSeconds, note.onset + 1e-8) - note.onset
                let isStrikeCandidate = event.hasOnset && note.duration >= WindowGeometry.minimumNoteDuration
                if let index = liveIndex[event.pitch], history.indices.contains(index),
                   note.onset < history[index].offset {
                    if isStrikeCandidate {
                        history[index] = note
                    } else if !event.hasOnset {
                        let newEnd = max(history[index].offset, note.offset)
                        history[index].duration = newEnd - history[index].onset
                    }
                } else if isStrikeCandidate {
                    history.append(note)
                    liveIndex[event.pitch] = history.count - 1
                }
            }
            windowIndex += 1
        }

        history.sort { ($0.onset, $0.pitch) < ($1.onset, $1.pitch) }
        return history
    }

    /// Prints the merged notes a replay produced, the format the reference
    /// tools diff against.
    static func runReplay(path: String, deviceRate: Double) {
        let history = replayNotes(path: path, deviceRate: deviceRate)
        print("replay: \(history.count) notes")
        for note in history {
            print(String(format: "swift note: %d @%.3f-%.3f v%d", note.pitch, note.onset, note.offset, note.velocity))
        }
    }

    /// Engraves a captured session offline: the replay's merged notes go to
    /// the engraver with the same chord inference the live sheet uses, and
    /// the resulting MusicXML lands in /tmp so the sheet generator can be
    /// judged on real performances before any UI exists.
    /// - score <file.f32> <deviceRate>
    static func runScore(path: String, deviceRate: Double) {
        let notes = replayNotes(path: path, deviceRate: deviceRate)
        guard !notes.isEmpty else {
            print("score: nothing to engrave")
            exit(1)
        }
        let grouped = assignOnsetGroups(notes)
        var chords: [(seconds: Double, symbol: String)] = []
        var lastSymbol = ""
        let chordsByGroup = Dictionary(grouping: grouped, by: { $0.onsetGroup })
        for groupId in chordsByGroup.keys.sorted() {
            guard let chord = Chord.identify(in: grouped, group: groupId) else { continue }
            guard chord.symbol != lastSymbol else { continue }
            let onset = chordsByGroup[groupId]?.map(\.onset).min() ?? 0
            chords.append((onset, chord.symbol))
            lastSymbol = chord.symbol
        }
        guard let score = Engraver.engrave(notes: notes, chords: chords) else {
            print("score: engraving failed")
            exit(1)
        }
        let time = score.framing.timeSignature
        let chordList = score.chords.map(\.symbol).joined(separator: ", ")
        print("score: \(Int(score.framing.beatsPerMinute.rounded())) bpm, \(time.beatsPerMeasure)/\(time.beatUnit), \(score.framing.key.name), \(score.measures.count) measures, chords: \(chordList)")
        let xml = MusicXML.write(score)
        do {
            try xml.write(toFile: "/tmp/cadenza_score.musicxml", atomically: true, encoding: .utf8)
            print("score: musicxml written to /tmp/cadenza_score.musicxml")
        } catch {
            print("score FAILED: \(error)")
            exit(1)
        }
    }

    /// Feeds a published MIDI file to the sheet generator and compares the
    /// engraver's framing against the file's own tempo, meter and key meta
    /// events — the ground truth a published score always carries — plus
    /// the quantization deviation per note. Writes the engraved document to
    /// /tmp/cadenza_midiscore.musicxml and sketches the first measures as
    /// text for eyeballing against the reference PDF.
    /// - midiscore <file.mid>
    static func runMidiScore(path: String) {
        guard let file = try? MidiReader.read(url: URL(fileURLWithPath: path)) else {
            print("midiscore: cannot read \(path)")
            exit(1)
        }
        print("midiscore: \(file.notes.count) notes at \(file.ticksPerQuarter) ppqn")

        let metaTempo = file.initialTempo
        let metaMeter = file.timeSignatures.first?.signature
        let metaKey = file.keySignatures.first?.key
        let meterText = metaMeter.map { "\($0.beatsPerMeasure)/\($0.beatUnit)" } ?? "?"
        print("midiscore meta: \(Int(metaTempo.rounded())) bpm, \(meterText), \(metaKey?.name ?? "?")")

        let grouped = assignOnsetGroups(file.notes)
        var chords: [(seconds: Double, symbol: String)] = []
        var lastSymbol = ""
        let chordsByGroup = Dictionary(grouping: grouped, by: { $0.onsetGroup })
        for groupId in chordsByGroup.keys.sorted() {
            guard let chord = Chord.identify(in: grouped, group: groupId) else { continue }
            guard chord.symbol != lastSymbol else { continue }
            let onset = chordsByGroup[groupId]?.map(\.onset).min() ?? 0
            chords.append((onset, chord.symbol))
            lastSymbol = chord.symbol
        }

        guard let score = Engraver.engrave(notes: file.notes, chords: chords) else {
            print("midiscore: nothing to engrave")
            exit(1)
        }
        let framing = score.framing
        let engravedMeter = "\(framing.timeSignature.beatsPerMeasure)/\(framing.timeSignature.beatUnit)"
        print("midiscore engraved: \(Int(framing.beatsPerMinute.rounded())) bpm, \(engravedMeter), \(framing.key.name), \(score.measures.count) measures")
        print("midiscore framing delta: tempo \(String(format: "%.1f", framing.beatsPerMinute - metaTempo)) bpm, meter \(engravedMeter == meterText ? "match" : "MISMATCH (meta \(meterText))"), key \(framing.key.name == metaKey?.name ? "match" : "MISMATCH (meta \(metaKey?.name ?? "?"))")")
        Engraver.meterDebug = true
        for candidate in Engraver.scoreMeterCandidates(file.notes, tempo: framing.beatsPerMinute) {
            print(String(format: "midiscore meter candidate %d/%d score %.3f", candidate.signature.beatsPerMeasure, candidate.signature.beatUnit, candidate.score))
        }
        Engraver.meterDebug = false
        for bpm in Engraver.tempoCandidates(file.notes) {
            let top = Engraver.scoreMeterCandidates(file.notes, tempo: bpm).first
            print(String(format: "midiscore tempo candidate %.0f bpm -> best meter %d/%d score %.3f", bpm, top?.signature.beatsPerMeasure ?? 0, top?.signature.beatUnit ?? 0, top?.score ?? 0))
        }

        // pitch-class evidence for the key call: top classes by sounding
        // time, and the root of the final chord when one is identifiable
        var histogram = Array(repeating: 0.0, count: 12)
        for note in file.notes { histogram[note.pitchClass] += note.duration }
        let top = histogram.enumerated().sorted { $0.element > $1.element }.prefix(5)
        let letters = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
        print("midiscore pitch classes: " + top.map { "\(letters[$0.offset]):\(Int($0.element))s" }.joined(separator: " "))
        if let lastGroup = grouped.last?.onsetGroup,
           let finalChord = Chord.identify(in: grouped, group: lastGroup) {
            print("midiscore final chord root: \(finalChord.root)")
        }
        // cadence evidence: pitch classes of the first and last onset groups
        let groupIds = Array(Set(grouped.map(\.onsetGroup))).sorted()
        for gid in (groupIds.prefix(2) + groupIds.suffix(3)) {
            let members = grouped.filter { $0.onsetGroup == gid }
            let onset = members.map(\.onset).min() ?? 0
            let names = Set(members.map { letters[$0.pitchClass] }).sorted()
            print(String(format: "midiscore group @%.1fs: %@", onset, names.joined(separator: " ")))
        }

        // quantization deviation: the tick the engraver wrote versus the
        // ideal tick at the engraved tempo, both relative to the first note
        let quarterSeconds = 60.0 / framing.beatsPerMinute
        let firstOnset = file.notes.map(\.onset).min() ?? 0
        let engravedNotes = score.measures.flatMap(\.notes).sorted { ($0.onsetTick, $0.pitch) < ($1.onsetTick, $1.pitch) }
        let midiSorted = file.notes.sorted { ($0.onset, $0.pitch) < ($1.onset, $1.pitch) }
        var deviations: [Double] = []
        for (a, b) in zip(midiSorted, engravedNotes) {
            let ideal = (a.onset - firstOnset) / quarterSeconds * Double(scoreTicksPerQuarter)
            deviations.append(abs(Double(b.onsetTick) - ideal))
        }
        if let maxDev = deviations.max(), let mean = deviations.isEmpty ? nil : deviations.reduce(0, +) / Double(deviations.count) {
            let sixteenth = scoreTicksPerQuarter / 4
            let within = Double(deviations.filter { $0 <= Double(sixteenth) / 2 }.count) / Double(deviations.count)
            print(String(format: "midiscore quantization: mean %.1f ticks, max %.1f ticks, %.0f%% within a sixteenth", mean, maxDev, within * 100))
        }

        // text sketch of the first measures for eyeballing against the PDF
        for measure in score.measures.prefix(6) {
            let notes = measure.notes.map { "\(noteName($0.pitch)):\($0.durationTicks)" }.joined(separator: " ")
            let chordsHere = score.chords
                .filter { $0.onsetTick >= measure.startTick && $0.onsetTick < measure.startTick + framing.timeSignature.ticksPerMeasure }
                .map(\.symbol)
                .joined(separator: ",")
            print("measure \(measure.index + 1)\(chordsHere.isEmpty ? "" : " [\(chordsHere)]"): \(notes)")
        }

        let xml = MusicXML.write(score)
        do {
            try xml.write(toFile: "/tmp/cadenza_midiscore.musicxml", atomically: true, encoding: .utf8)
            print("midiscore: musicxml written to /tmp/cadenza_midiscore.musicxml")
        } catch {
            print("midiscore FAILED: \(error)")
            exit(1)
        }
    }

    /// Offline streaming simulation: slides the 16 s window over the
    /// recording exactly the way the live engine does — warmup edge first,
    /// then edges pacing themselves at the decode rate, anchors chained per
    /// symbol — and prints the emission stream ("stream struck/released"
    /// lines carrying the emission edge) plus the final merged notes in the
    /// same "swift note" format as runReplay, so the two outputs can be
    /// diffed to measure flicker, duplicates and timing drift offline.
    static func runReplayStream(path: String, deviceRate: Double) {
        guard let assets = AppDelegate.locateAssets() else {
            print("replay-stream: model assets not found")
            exit(1)
        }
        let data = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
        let input = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard !input.isEmpty else {
            print("replay-stream FAILED: no samples in \(path)")
            exit(1)
        }
        print("replay-stream: \(input.count) samples at \(Int(deviceRate)) Hz")

        let context: InferenceContext
        do {
            context = try InferenceContext(tensorsDir: assets.tensors, modelURL: assets.model)
        } catch {
            print("replay-stream FAILED: \(error)")
            exit(1)
        }

        let tapState = AudioTapState()
        tapState.reset(rate: deviceRate)
        var merge = StreamingMerge(symbolCount: WindowGeometry.symbols.count)
        var fed = 0

        var edge = WindowGeometry.streamingWarmup
        var index = 0
            var emissionCount = 0
            var struckLatencies: [Double] = []
            while edge * deviceRate <= Double(input.count) {
                Self.feed(tapState, from: input, fed: &fed, upTo: Int((edge * deviceRate).rounded()))
                guard let window = tapState.takeStreamWindow(edgeSeconds: edge) else { break }
                let forcedStart = merge.forcedStart(for: edge - WindowGeometry.segmentSeconds)
                let decodeStart = CACurrentMediaTime()
                guard let result = context.run(windowIndex: index, edgeSeconds: edge, samples: window,
                                               deviceRate: deviceRate, forcedStartPos: forcedStart) else {
                    print("replay-stream FAILED: window \(index) decode error")
                    exit(1)
                }
                let decodeWall = CACurrentMediaTime() - decodeStart

                for emission in merge.absorb(result) {
                    emissionCount += 1
                    let kind: String
                    switch emission.kind {
                    case .struck: kind = "struck"
                    case .extended: kind = "extended"
                    case .released: kind = "released"
                    }
                    let note = emission.event
                    if emission.kind == .struck {
                        // in live playback the note becomes public about when
                        // this decode finishes, so far behind the onset as
                        // this: the number the pipeline is chasing
                        struckLatencies.append(edge + decodeWall - note.onset)
                    }
                    print(String(format: "stream %@: %d @%.3f-%.3f v%d at edge %.2f", kind, note.pitch, note.onset, note.offset, note.velocity, edge))
                }
                index += 1
                edge += WindowGeometry.streamingAdvance(decodeWall: decodeWall)
            }

            if !struckLatencies.isEmpty {
                let sorted = struckLatencies.sorted()
                let median = sorted[sorted.count / 2]
                let p90 = sorted[Int(Double(sorted.count - 1) * 0.9)]
                print(String(format: "replay-stream latency: mean %.2f s, median %.2f s, p90 %.2f s, max %.2f s over %d strikes",
                             struckLatencies.reduce(0, +) / Double(struckLatencies.count), median, p90,
                             sorted.last!, struckLatencies.count))
            }

        for emission in merge.releaseAll() {
            let note = emission.event
            print(String(format: "stream released: %d @%.3f-%.3f v%d at end", note.pitch, note.onset, note.offset, note.velocity))
        }

        let sortedNotes = merge.notes.sorted { ($0.onset, $0.pitch) < ($1.onset, $1.pitch) }
        print("replay-stream: \(merge.notes.count) notes, \(emissionCount) emissions")
        for note in sortedNotes {
            print(String(format: "swift note: %d @%.3f-%.3f v%d", note.pitch, note.onset, note.offset, note.velocity))
        }
    }

    /// MIDI file writer check: three notes in, structurally parsed back out.
    static func runMidiProbe() {
        var notes: [NoteEvent] = [
            NoteEvent(pitch: 60, velocity: 39, onset: 0.0, duration: 2.0),
            NoteEvent(pitch: 64, velocity: 48, onset: 0.5, duration: 1.0),
            NoteEvent(pitch: 67, velocity: 46, onset: 0.0, duration: 2.5),
        ]
        notes.sort { $0.onset < $1.onset }
        let url = URL(fileURLWithPath: "/tmp/cadenza_smoke.mid")
        do {
            try MidiFileWriter.write(notes, to: url)
            let data = try Data(contentsOf: url)
            let bytes = [UInt8](data)

            func be16(_ i: Int) -> UInt16 { UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]) }
            func be32(_ i: Int) -> UInt32 { UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3]) }

            guard bytes.count > 14,
                  String(decoding: bytes[0..<4], as: UTF8.self) == "MThd",
                  be32(4) == 6,
                  be16(8) == 0, be16(10) == 1, be16(12) == 480,
                  String(decoding: bytes[14..<18], as: UTF8.self) == "MTrk",
                  Int(be32(18)) == bytes.count - 22 else {
                print("midi probe FAILED: structure invalid")
                exit(1)
            }
            // the track payload must carry the three note-ons and their
            // note-offs exactly once each
            let payload = Array(bytes[22...])
            var on60 = 0, on64 = 0, on67 = 0
            var off60 = 0
            for i in 0..<(payload.count - 2) {
                if payload[i] == 0x90 {
                    if payload[i + 1] == 60 { on60 += 1 }
                    if payload[i + 1] == 64 { on64 += 1 }
                    if payload[i + 1] == 67 { on67 += 1 }
                } else if payload[i] == 0x80 {
                    if payload[i + 1] == 60 { off60 += 1 }
                }
            }
            guard on60 == 1, on64 == 1, on67 == 1, off60 == 1 else {
                print("midi probe FAILED: on/off counts wrong (\(on60), \(on64), \(on67), off60 \(off60))")
                exit(1)
            }
            print("midi probe PASSED: \(bytes.count) bytes, 3 note-ons, 1 note-off found")
        } catch {
            print("midi probe FAILED: \(error)")
            exit(1)
        }
    }

    /// Converter matrix probe: which buffer sizes, directions and layouts
    /// the AVAudioConverter accepts on this machine.
    static func runConverterProbe() {
        let cases: [(String, AVAudioFormat, AVAudioFormat)] = [
            ("deinterleaved", Self.fmt(44100, false), Self.fmt(48000, false)),
            ("interleaved", Self.fmt(44100, true), Self.fmt(48000, true)),
            ("standard", AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!,
                               AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!),
        ]
        for (name, src, dst) in cases {
            guard let conv = AVAudioConverter(from: src, to: dst) else {
                print("probe: \(name) converter nil")
                continue
            }
            for n in [1000, 352800] {
                guard let ib = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(n)) else { continue }
                ib.frameLength = AVAudioFrameCount(n)
                // capacity must cover both the converted length and, for the
                // convenience API, the input length itself
                let cap = AVAudioFrameCount(max(Double(n) * dst.sampleRate / src.sampleRate, Double(n))) + 4096
                guard let ob = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: cap) else { continue }
                do {
                    try conv.convert(to: ob, from: ib)
                    print("probe: \(name) n=\(n) ok out=\(ob.frameLength)")
                } catch {
                    print("probe: \(name) n=\(n) FAIL \(error.localizedDescription)")
                }
            }
        }
        // callback flavor, deinterleaved, the way v1 used it
        let src = Self.fmt(44100, false), dst = Self.fmt(48000, false)
        if let conv = AVAudioConverter(from: src, to: dst) {
            conv.sampleRateConverterAlgorithm = "cplx"
            for n in [1000, 352800] {
                guard let ib = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(n)) else { continue }
                ib.frameLength = AVAudioFrameCount(n)
                let cap = AVAudioFrameCount(Double(n) * 48000 / 44100) + 8192
                guard let ob = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: cap) else { continue }
                do {
                    try conv.convert(to: ob, from: ib)
                    print("probe: sinc algorithm n=\(n) ok out=\(ob.frameLength)")
                } catch {
                    print("probe: sinc algorithm n=\(n) FAIL \(error.localizedDescription)")
                }
            }
        }
    }

    private static func fmt(_ rate: Double, _ interleaved: Bool) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: interleaved)!
    }

    /// Offline full-pipeline simulation: feeds the fixture through the tap
    /// ring as if a 48 kHz device had captured it, takes window 0 the way
    /// the engine's tick would, and decodes it. Expected: the three golden
    /// notes.
    static func runSimulate() {
        guard let assets = AppDelegate.locateAssets() else {
            print("simulate: model assets not found")
            exit(1)
        }
        let audioURL = URL(fileURLWithPath: rootPath("Fixtures/golden/audio_window.f32"))
        guard let fixture = try? Data(contentsOf: audioURL) else {
            print("simulate: fixture missing")
            exit(1)
        }
        let fixture44 = fixture.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        print("simulate: \(fixture44.count) fixture samples at 44100")

        let context: InferenceContext
        do {
            context = try InferenceContext(tensorsDir: assets.tensors, modelURL: assets.model)
        } catch {
            print("simulate FAILED: \(error)")
            exit(1)
        }

        // The fixture is window 0's padded view: 8 s of silence + 8 s of
        // music. As live audio, only the performance part (the last 8 s)
        // arrives through the tap; the engine adds the leading pad itself.
        let performance44 = Array(fixture44[(8 * 44100)...])
        guard let performance48 = InferenceContext.resample(performance44, from: 44100, to: 48000) else {
            print("simulate FAILED: upsample to 48 kHz failed")
            exit(1)
        }
        print("simulate: \(performance48.count) device samples at 48000")

        let tapState = AudioTapState()
        tapState.reset(rate: 48000)
        // feed in tap-sized chunks, like the realtime tap does
        var index = 0
        while index < performance48.count {
            let end = min(index + 8192, performance48.count)
            tapState.append(Array(performance48[index..<end]))
            index = end
        }

        guard let window = tapState.takeWindow(index: 0) else {
            print("simulate FAILED: window 0 not available")
            exit(1)
        }
        print("simulate: window 0 is \(window.count) device samples")

        guard let result = context.run(windowIndex: 0, edgeSeconds: WindowGeometry.segmentSeconds - WindowGeometry.padSeconds,
                                       samples: window, deviceRate: 48000,
                                       forcedStartPos: Array(repeating: WindowGeometry.padFrames, count: WindowGeometry.symbols.count)) else {
            print("simulate FAILED: no decode result")
            exit(1)
        }
        for event in result.events {
            let duration = event.offsetSeconds - event.onsetSeconds
            print(String(format: "simulate note: %d@%.3f-%.3f v%d", event.pitch, event.onsetSeconds, event.onsetSeconds + duration, event.velocity))
        }
        let pitches = Set(result.events.map({ $0.pitch }))
        if pitches == [60, 64, 67] {
            print("simulate PASSED")
        } else {
            print("simulate FAILED: expected pitches 60, 64, 67, got \(pitches.sorted())")
            exit(1)
        }
    }

    private static func rootPath(_ relative: String) -> String {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Models/tensors").path) {
                return dir.appendingPathComponent(relative).path
            }
            dir = dir.deletingLastPathComponent()
        }
        return relative
    }

    /// Feeds the tap ring from a recording in tap-sized chunks, the way the
    /// realtime tap delivers. `fed` tracks how many samples have entered.
    private static func feed(_ tapState: AudioTapState, from input: [Float], fed: inout Int, upTo sampleIndex: Int) {
        let target = min(sampleIndex, input.count)
        while fed < target {
            let end = min(fed + 8192, target)
            tapState.append(Array(input[fed..<end]))
            fed = end
        }
    }

    /// Headless check of the app's own inference path: feeds the golden
    /// fixture window through InferenceContext.run exactly as captured
    /// audio would arrive, then prints the notes it produces.
    ///
    /// Expected result for the fixture (verified against the Python
    /// transcribe() reference): 60@0.000-3.986 v39, 64@0.000-3.985 v48,
    /// 67@0.000-4.003 v46.
    static func run(audioPath: String?) {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var dir = CommandLine.arguments.count > 2
            ? URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            : root
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Models/tensors").path) { break }
            dir = dir.deletingLastPathComponent()
        }
        let tensors = dir.appendingPathComponent("Models/tensors", isDirectory: true)
        let model = dir.appendingPathComponent("Models/TranskunBackbone.mlpackage", isDirectory: true)
        let audioURL = URL(fileURLWithPath: audioPath ?? "Fixtures/golden/audio_window.f32")
        print("smoke: tensors \(tensors.path)")
        print("smoke: model \(model.path)")

        do {
            let context = try InferenceContext(tensorsDir: tensors, modelURL: model)
            let audio = readF32(audioURL)
            print("smoke: \(audio.count) samples from \(audioURL.path)")

            let result = context.run(windowIndex: 0, edgeSeconds: WindowGeometry.segmentSeconds - WindowGeometry.padSeconds,
                                     samples: audio,
                                     deviceRate: 44100,
                                     forcedStartPos: Array(repeating: WindowGeometry.padFrames, count: WindowGeometry.symbols.count))
            guard let result else {
                print("smoke FAILED: no result")
                exit(1)
            }
            for event in result.events {
                let duration = event.offsetSeconds - event.onsetSeconds
                print(String(format: "smoke note: %d@%.3f-%.3f v%d", event.pitch, event.onsetSeconds, event.onsetSeconds + duration, event.velocity))
            }
            let pitches = Set(result.events.map(\.pitch))
            guard pitches == [60, 64, 67] else {
                print("smoke FAILED: expected pitches 60, 64, 67, got \(pitches.sorted())")
                exit(1)
            }
            print("smoke PASSED")
        } catch {
            print("smoke FAILED: \(error)")
            exit(1)
        }
    }

    /// Renders an engraved MIDI file's sheet to a PNG, offscreen, so the
    /// notation can be inspected without opening a window: --sheet <mid>
    static func runSheet(path: String) {
        MainActor.assumeIsolated {
            // the app renders its paper world in light mode; the offscreen
            // render must resolve the same dynamic colors
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
            MusicFont.register()
            guard let file = try? MidiReader.read(url: URL(fileURLWithPath: path)) else {
                print("sheet: cannot read \(path)")
                exit(1)
            }
            // the sheet honours the file's own meter and tempo when it declares
            // them, the way a DAW-exported MIDI carries its notation intent
            let metaMeter = file.timeSignatures.first?.signature
            let metaBpm = file.initialTempo
            let options = SheetDraft.Options(
                bpm: metaBpm > 0 ? metaBpm : 120,
                numerator: metaMeter?.beatsPerMeasure ?? 4,
                denominator: metaMeter?.beatUnit ?? 4)
            let result = SheetDraft.draft(notes: file.notes, options: options, pageWidth: 86)
            print("sheet draft: \(result.rows.count) rows, fifths \(result.fifths), "
                + "\(result.beamGroups.count) beams, options \(result.options.numerator)/\(result.options.denominator)")
            let view = ScoreView(result: result)
            let size = ScoreView.pointSize(of: result)
            view.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
            let scale: CGFloat = 1.6
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * scale),
                pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )!
            // paper behind the ink
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            if let ctx = NSGraphicsContext.current {
                PaperTheme.paper.setFill()
                NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh).fill()
                ctx.cgContext.translateBy(x: 0, y: CGFloat(rep.pixelsHigh))
                ctx.cgContext.scaleBy(x: scale, y: -scale)
                view.draw(NSRect(x: 0, y: 0, width: size.width, height: size.height))
            }
            NSGraphicsContext.restoreGraphicsState()
            guard let cg = rep.cgImage,
                  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "/tmp/cadenza_sheet.png") as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                print("sheet: could not write png")
                exit(1)
            }
            CGImageDestinationAddImage(dest, cg, nil)
            CGImageDestinationFinalize(dest)
            print("sheet: wrote /tmp/cadenza_sheet.png")
        }
    }

    /// Renders the endless measure with a spread of synthetic notes,
    /// offscreen: --strip-shot. The strip is otherwise driven by live
    /// engine events, so this is how its engraving gets inspected.
    static func runStripShot() {
        MainActor.assumeIsolated {
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
            MusicFont.register()
            let strip = EndlessStaffView()
            let size = NSSize(width: 900, height: 240)
            strip.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
            // a chord, a melody, an accidental and a ledger test, oldest first
            for (pitch, age) in [(48, 8.6), (55, 8.5), (72, 6.4), (76, 6.3),
                                 (61, 4.4), (66, 4.3), (70, 2.2), (84, 0.9),
                                 (93, 0.9), (30, 0.4)] {
                strip.noteStruck(pitch: pitch, age: age)
            }
            // flush the timer: draw one frame now
            let scale: CGFloat = 2
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            if let ctx = NSGraphicsContext.current {
                PaperTheme.paper.setFill()
                NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh).fill()
                ctx.cgContext.translateBy(x: 0, y: CGFloat(rep.pixelsHigh))
                ctx.cgContext.scaleBy(x: scale, y: -scale)
                strip.draw(NSRect(x: 0, y: 0, width: size.width, height: size.height))
            }
            NSGraphicsContext.restoreGraphicsState()
            if let cg = rep.cgImage,
               let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "/tmp/cadenza_strip.png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, cg, nil)
                CGImageDestinationFinalize(dest)
                print("strip-shot: wrote /tmp/cadenza_strip.png")
            }
        }
    }

    private static func readF32(_ url: URL) -> [Float] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }
    }
}
