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
        let timer = Clock.every(2.0) {
            let wall = Date().timeIntervalSince(began)
            print(String(format: "capture: wall %.1f s, content %.1f s, level %.4f, notes %d, running %@", wall, engine.capturedSeconds, engine.level, engine.noteCount, engine.isRunning ? "yes" : "no"))
            if let error = engine.lastError { print("error: \(error)") }
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
    static func replayNotes(path: String, deviceRate: Double, plan: WindowPlan = .standard) -> [NoteEvent] {
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
        tapState.reset(rate: deviceRate, plan: plan)

        var lastP = Array(repeating: 0, count: WindowGeometry.symbols.count)
        var history: [NoteEvent] = []
        var liveIndex: [Int: Int] = [:]
        var windowIndex = 0
        var fed = 0  // how many samples of the recording have been fed

        while true {
            let startSeconds = Double(windowIndex) * plan.stepWallSeconds - plan.padSeconds
            let endSeconds = startSeconds + plan.segmentSeconds
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
                forcedStart = Array(repeating: plan.padFrames, count: WindowGeometry.symbols.count)
            } else {
                forcedStart = lastP.map { max($0 - plan.stepFrames, 0) }
            }
            // a CLI main() never returns to the run loop, so drain the
            // autorelease pool around each decode: CoreML temporaries would
            // otherwise pile up over a long recording until the process eats
            // gigabytes
            autoreleasepool {
            guard let result = context.run(windowIndex: windowIndex, edgeSeconds: Double(windowIndex) * plan.stepWallSeconds
                                              - plan.padSeconds + plan.segmentSeconds,
                                          samples: samples,
                                          deviceRate: deviceRate,
                                          forcedStartPos: forcedStart, plan: plan) else {
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

    /// The streaming pipeline over a recording, exactly the way the live
    /// engine runs it — warmup edge first, then edges pacing themselves at
    /// the decode rate, anchors chained per symbol — returning the merged
    /// notes and the strike latencies (edge + decode wall - onset) without
    /// printing anything.
    static func streamRun(path: String, deviceRate: Double, plan: WindowPlan, modelURL: URL?, printEvents: Bool) -> (notes: [NoteEvent], latencies: [Double], emissions: Int) {
        guard let assets = AppDelegate.locateAssets() else {
            print("stream run: model assets not found")
            exit(1)
        }
        let data = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
        let input = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard !input.isEmpty else {
            print("stream run FAILED: no samples in \(path)")
            exit(1)
        }
        print("stream run: \(input.count) samples at \(Int(deviceRate)) Hz, \(plan.segmentSeconds) s windows")

        let context: InferenceContext
        do {
            context = try InferenceContext(tensorsDir: assets.tensors, modelURL: modelURL ?? assets.model)
        } catch {
            print("stream run FAILED: \(error)")
            exit(1)
        }

        let tapState = AudioTapState()
        tapState.reset(rate: deviceRate, plan: plan)
        var merge = StreamingMerge(symbolCount: WindowGeometry.symbols.count, plan: plan)
        var fed = 0

        // Submission follows the live pipelined engine: edges step at the
        // streaming step (two decoders keep that pace), decodes run then
        // absorb in window order. Latency models the two-decoder queue:
        // a window's decode starts when its edge arrived AND a decoder is
        // free, and its strikes publish when that decode finishes.
        var edge = plan.streamingWarmup
        // accuracy runs pin the step so two builds are compared on the same
        // windows instead of on whatever the machine's load happened to allow
        let fixedStep = ProcessInfo.processInfo.environment["CDZ_FIXED_STEP"].flatMap(Double.init)
        var step = fixedStep ?? plan.streamingStep
        var index = 0
        var emissionCount = 0
        // per window: its edge, its (later filled) decode wall, and the
        // onsets it struck
        var schedule: [(edge: Double, decodeWall: Double, onsets: [Double])] = []
        var done = false
        while !done && edge * deviceRate <= Double(input.count) {
          // a CLI main() never returns to the run loop, so the autorelease
          // pool would never drain and every window's CoreML temporaries
          // would pile up until the process eats gigabytes; drain per window
          autoreleasepool {
            Self.feed(tapState, from: input, fed: &fed, upTo: Int((edge * deviceRate).rounded()))
            guard let window = tapState.takeStreamWindow(edgeSeconds: edge) else { done = true; return }
            let forcedStart = merge.forcedStart(for: edge - plan.segmentSeconds)
            let decodeStart = CACurrentMediaTime()
            guard let result = context.run(windowIndex: index, edgeSeconds: edge, samples: window,
                                           deviceRate: deviceRate, forcedStartPos: forcedStart, plan: plan) else {
                print("stream run FAILED: window \(index) decode error")
                exit(1)
            }
            let decodeWall = CACurrentMediaTime() - decodeStart
            var onsets: [Double] = []
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
                    onsets.append(note.onset)
                }
                if printEvents {
                    print(String(format: "stream %@: %d @%.3f-%.3f v%d at edge %.2f", kind, note.pitch, note.onset, note.offset, note.velocity, edge))
                }
            }
            schedule.append((edge: edge, decodeWall: decodeWall, onsets: onsets))
            index += 1
            // the live engine stretches its step until two decoders keep up
            if fixedStep == nil {
                step = min(WindowGeometry.stepCeiling, max(plan.streamingStep, decodeWall * 0.6))
            }
            edge += step
          }
        }

        // the two-decoder queue: each window takes the earlier-free decoder
        var slotFree = [0.0, 0.0]
        var struckLatencies: [Double] = []
        if plan == WindowPlan.standard {
            for entry in schedule {
                let slot = slotFree[0] <= slotFree[1] ? 0 : 1
                let start = max(entry.edge, slotFree[slot])
                let finish = start + entry.decodeWall
                slotFree[slot] = finish
                struckLatencies.append(contentsOf: entry.onsets.map { finish - $0 })
            }
        } else {
            // a single decoder (any other plan): the window publishes when
            // its own decode finishes
            for entry in schedule {
                struckLatencies.append(contentsOf: entry.onsets.map { entry.edge + entry.decodeWall - $0 })
            }
        }

        for emission in merge.releaseAll() {
            if printEvents {
                let note = emission.event
                print(String(format: "stream released: %d @%.3f-%.3f v%d at end", note.pitch, note.onset, note.offset, note.velocity))
            }
        }
        return (merge.notes, struckLatencies, emissionCount)
    }

    /// Offline streaming simulation: slides the window over the recording
    /// exactly the way the live engine does and prints the emission stream
    /// ("stream struck/released" lines carrying the emission edge) plus the
    /// final merged notes in the same "swift note" format as runReplay, so
    /// the two outputs can be diffed to measure flicker, duplicates and
    /// timing drift offline.
    static func runReplayStream(path: String, deviceRate: Double) {
        let (notes, latencies, emissions) = streamRun(path: path, deviceRate: deviceRate,
                                                      plan: WindowPlan.standard, modelURL: nil, printEvents: true)
        if !latencies.isEmpty {
            let sorted = latencies.sorted()
            let median = sorted[sorted.count / 2]
            let p90 = sorted[Int(Double(sorted.count - 1) * 0.9)]
            print(String(format: "replay-stream latency: mean %.2f s, median %.2f s, p90 %.2f s, max %.2f s over %d strikes",
                         latencies.reduce(0, +) / Double(latencies.count), median, p90,
                         sorted.last!, latencies.count))
        }
        let sortedNotes = notes.sorted { ($0.onset, $0.pitch) < ($1.onset, $1.pitch) }
        print("replay-stream: \(notes.count) notes, \(emissions) emissions")
        for note in sortedNotes {
            print(String(format: "swift note: %d @%.3f-%.3f v%d", note.pitch, note.onset, note.offset, note.velocity))
        }
    }

    /// Diagnostic: decodes back-to-back non-overlapping short crops with
    /// the FAST model and prints how many events each crop sees, so a low
    /// fast-tier recall can be split into "the crop itself decodes badly"
    /// versus "the streaming interplay loses notes". Prints per-crop event
    /// counts and the total for the first `crops` tiles.
    /// Usage: --probe-short <audio.f32> [rate] [crops]
    static func runProbeShort(audioPath: String, deviceRate: Double, crops: Int, plan: WindowPlan, modelURL: URL) {
        let context: InferenceContext
        do {
            context = try InferenceContext(tensorsDir: AppDelegate.locateAssets()!.tensors, modelURL: modelURL)
        } catch {
            print("probe-short FAILED: \(error)")
            exit(1)
        }
        let data = (try? Data(contentsOf: URL(fileURLWithPath: audioPath))) ?? Data()
        let input = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let tapState = AudioTapState()
        tapState.reset(rate: deviceRate, plan: plan)
        var fed = 0
        var total = 0
        var edge = plan.segmentSeconds  // tile the whole recording from the start
        var index = 0
        while index < crops {
            Self.feed(tapState, from: input, fed: &fed, upTo: Int((edge * deviceRate).rounded()))
            guard fed >= Int((edge * deviceRate).rounded()) || fed >= input.count else { break }
            guard let window = tapState.takeStreamWindow(edgeSeconds: edge) else { break }
            let forced = Array(repeating: 0, count: WindowGeometry.symbols.count)
            guard let result = context.run(windowIndex: index, edgeSeconds: edge, samples: window,
                                           deviceRate: deviceRate, forcedStartPos: forced, plan: plan) else {
                print("probe-short: crop \(index) decode error")
                break
            }
            let strikes = result.events.filter { $0.hasOnset && ($0.offsetSeconds - $0.onsetSeconds) >= WindowGeometry.minimumNoteDuration }
            total += strikes.count
            let onsets = strikes.map { $0.onsetSeconds - (edge - plan.segmentSeconds) }.filter { $0 >= 0 }
            print(String(format: "probe-short crop %d (content %.1f-%.1f s): %d raw events, %d strikes, onset span %.2f-%.2f",
                         index, edge - plan.segmentSeconds, edge, result.events.count, strikes.count,
                         onsets.min() ?? -1, onsets.max() ?? -1))
            index += 1
            edge += plan.segmentSeconds
        }
        print("probe-short total strikes over \(index) crops: \(total)")
    }

    /// Dumps the raw decode of one window, unfiltered: every symbol interval
    /// the semi-CRF chose, with the onset/offset and presence flags the
    /// merge would see. The diagnostic for "is a note decoded at all".
    /// Usage: --decode-dump <audio.f32> <rate> <edgeSeconds>
    static func runDecodeDump(audioPath: String, deviceRate: Double, edge: Double) {
        let context: InferenceContext
        do {
            context = try InferenceContext(tensorsDir: AppDelegate.locateAssets()!.tensors,
                                           modelURL: AppDelegate.locateAssets()!.model)
        } catch {
            print("decode-dump FAILED: \(error)")
            exit(1)
        }
        let data = (try? Data(contentsOf: URL(fileURLWithPath: audioPath))) ?? Data()
        let input = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let plan = WindowPlan.standard
        let tapState = AudioTapState()
        tapState.reset(rate: deviceRate, plan: plan)
        var fed = 0
        Self.feed(tapState, from: input, fed: &fed, upTo: Int((edge * deviceRate).rounded()))
        guard let window = tapState.takeStreamWindow(edgeSeconds: edge) else {
            print("decode-dump: no window")
            exit(1)
        }
        let forced = Array(repeating: 0, count: WindowGeometry.symbols.count)
        guard let result = context.run(windowIndex: 0, edgeSeconds: edge, samples: window,
                                       deviceRate: deviceRate, forcedStartPos: forced, plan: plan) else {
            print("decode-dump: decode error")
            exit(1)
        }
        print(String(format: "decode-dump window %.1f-%.1f s: %d events", edge - plan.segmentSeconds, edge, result.events.count))
        for event in result.events {
            print(String(format: "raw %d @%.3f-%.3f v%d on%d off%d", event.pitch,
                         event.onsetSeconds - (edge - plan.segmentSeconds),
                         event.offsetSeconds - (edge - plan.segmentSeconds),
                         event.velocity, event.hasOnset ? 1 : 0, event.hasOffset ? 1 : 0))
        }
    }

    /// Prints the mel front end's view of one instant: the strongest bands
    /// and their values, so "no energy up there" can be separated from "the
    /// model ignores it". Usage: --mel-probe <audio.f32> <rate> <seconds>
    static func runMelProbe(audioPath: String, deviceRate: Double, at seconds: Double) {
        guard let tensors = AppDelegate.locateAssets()?.tensors,
              let mel = try? MelFrontEnd(tensorsDir: tensors) else {
            print("mel-probe FAILED: no tensors")
            exit(1)
        }
        let data = (try? Data(contentsOf: URL(fileURLWithPath: audioPath))) ?? Data()
        let all = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let count = min(all.count, Int(16 * deviceRate))
        let window = Array(all.suffix(count))
        let flat = mel.compute(window)
        let bands = MelFrontEnd.nMels
        let channels = MelFrontEnd.nChannels
        let frames = flat.count / (bands * channels)
        let covered = Double(count) / deviceRate
        let offset = seconds - (16.0 - covered)
        let frameIndex = offset * WindowGeometry.sampleRate / Double(MelFrontEnd.hopSize)
        let wanted = min(frames - 1, max(0, Int(frameIndex)))
        var row: [(Int, Float)] = []
        for b in 0..<bands {
            row.append((b, flat[(wanted * bands + b) * channels]))
        }
        let top = row.sorted { $0.1 > $1.1 }.prefix(8)
        print(String(format: "mel-probe frame %d of %d (t %.2f s)", wanted, frames, Double(count) / deviceRate - 16 + seconds))
        for (b, v) in top {
            print(String(format: "band %d value %.4f", b, v))
        }
        for b in stride(from: 40, through: 120, by: 10) {
            print(String(format: "band %d value %.4f", b, flat[(wanted * bands + b) * channels]))
        }
    }

    /// A sibling mlpackage by file name, for the probe diagnostics.
    static func modelByName(_ name: String) -> URL? {
        guard let assets = AppDelegate.locateAssets() else { return nil }
        let url = assets.model.deletingLastPathComponent().appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The standing eval: runs the streaming pipeline over a recorded f32
    /// capture and scores it against the ground-truth MIDI the audio was
    /// synthesized from. Greedy per-pitch matching with a 75 ms onset
    /// window. Prints precision/recall/F1 and the strike latency
    /// percentiles in one line — the number every model change is judged by.
    /// Usage: --eval <audio.f32> <groundtruth.mid> [rate]
    static func runEval(audioPath: String, midiPath: String, deviceRate: Double) {
        guard let file = try? MidiReader.read(url: URL(fileURLWithPath: midiPath)) else {
            print("eval FAILED: cannot read \(midiPath)")
            exit(1)
        }
        let data = (try? Data(contentsOf: URL(fileURLWithPath: audioPath))) ?? Data()
        let audioSeconds = Double(data.count / 4) / deviceRate
        // the synth rendered only the first audioSeconds: the truth beyond
        // the recording's end can never match and would sink the recall
        let truth = file.notes.filter { $0.onset < audioSeconds - 0.05 }
        let (notes, latencies, _) = streamRun(path: audioPath, deviceRate: deviceRate,
                                              plan: WindowPlan.standard, modelURL: nil, printEvents: false)
        if ProcessInfo.processInfo.environment["CDZ_COMPLETE_DUMP"] == "1" {
            for note in notes {
                print(String(format: "det %.3f %d", note.onset, note.pitch))
            }
            for note in truth {
                print(String(format: "truth %.3f %d", note.onset, note.pitch))
            }
        }
        let score = Self.scoreNotes(detected: notes, truth: truth)
        var line = String(format: "precision %.3f, recall %.3f, F1 %.3f (match %d, detected %d, truth %d)",
                          score.precision, score.recall, score.f1, score.matches, notes.count, truth.count)
        // note lengths: the second half of a transcription, scored only over
        // matched pairs, and relative to how long the note actually was
        if !score.offsetErrors.isEmpty {
            let magnitudes = score.offsetErrors.map { abs($0) }.sorted()
            let signed = score.offsetErrors.sorted()
            let median = magnitudes[magnitudes.count / 2]
            let bias = signed[signed.count / 2]
            let p90 = magnitudes[Int(Double(magnitudes.count - 1) * 0.9)]
            let accurate = zip(score.offsetErrors, score.offsetTolerances)
                .filter { abs($0.0) <= $0.1 }.count
            line += String(format: ", offset bias %+.2f s, |err| median %.2f s, p90 %.2f s, within 10%% %d/%d",
                           bias, median, p90, accurate, score.offsetErrors.count)
        }
        if !latencies.isEmpty {
            let sorted = latencies.sorted()
            let median = sorted[sorted.count / 2]
            let p90 = sorted[Int(Double(sorted.count - 1) * 0.9)]
            line += String(format: ", latency median %.2f s, p90 %.2f s", median, p90)
        }
        print("== eval " + (midiPath as NSString).lastPathComponent)
        print(line)
    }

    /// Greedy per-pitch onset matching of detected notes against ground
    /// truth: a detection matches the nearest unmatched truth note of the
    /// same pitch within the onset window.
    static func scoreNotes(detected: [NoteEvent], truth: [NoteEvent], onsetWindow: Double = 0.075) -> (precision: Double, recall: Double, f1: Double, matches: Int, offsetErrors: [Double], offsetTolerances: [Double]) {
        var matched = 0
        var usedTruth = Set<Int>()
        var usedDetected = Set<Int>()
        var offsetErrors: [Double] = []
        var offsetTolerances: [Double] = []
        let byPitch = Dictionary(grouping: truth.enumerated().map { ($0.offset, $0.element) }, by: { $0.1.pitch })
        for note in detected.sorted(by: { $0.onset < $1.onset }) {
            let candidates = byPitch[note.pitch] ?? []
            var bestIndex: Int?
            var bestDistance = onsetWindow
            for (index, pair) in candidates.enumerated() where !usedTruth.contains(pair.0) {
                let distance = abs(pair.1.onset - note.onset)
                if distance <= bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }
            if let index = bestIndex {
                usedTruth.insert(candidates[index].0)
                usedDetected.insert(detected.firstIndex(of: note)!)
                matched += 1
                let truthNote = candidates[index].1
                offsetErrors.append(note.offset - truthNote.offset)
                offsetTolerances.append(max(0.05, min(0.2, truthNote.duration * 0.1)))
            }
        }
        if ProcessInfo.processInfo.environment["CDZ_DUMP_MISMATCH"] == "1" {
            for (i, note) in detected.enumerated() where !usedDetected.contains(i) {
                print(String(format: "FP pitch %d @%.3f-%.3f v%d", note.pitch, note.onset, note.offset, note.velocity))
            }
            let sortedTruth = truth.enumerated().sorted { $0.element.onset < $1.element.onset }
            for (i, note) in sortedTruth where !usedTruth.contains(i) {
                print(String(format: "FN pitch %d @%.3f-%.3f v%d", note.pitch, note.onset, note.offset, note.velocity))
            }
        }
        let precision = detected.isEmpty ? 0 : Double(matched) / Double(detected.count)
        let recall = truth.isEmpty ? 0 : Double(matched) / Double(truth.count)
        let f1 = precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0
        return (precision, recall, f1, matched, offsetErrors, offsetTolerances)
    }

    /// Synthesizes a MIDI file into a raw f32 mono capture at the given rate:
    /// each note becomes a piano-ish tone (six decaying harmonics), which is
    /// the cleanest audio the engine can ever see — the "at its best" case.
    /// Prints every ground-truth note as "gt note:" lines for offline
    /// precision/recall matching against --replay-stream output.
    /// Usage: --synth-midi <file.mid> <out.f32> [rate] [maxSeconds]
    static func runSynthMidi(path: String, out: String, rate: Double, maxSeconds: Double?) {
        guard let file = try? MidiReader.read(url: URL(fileURLWithPath: path)) else {
            print("synth-midi FAILED: cannot read \(path)")
            exit(1)
        }
        let limit = maxSeconds ?? .infinity
        let notes = file.notes.filter { $0.onset < limit }
        let tail = 2.0
        let total = min(notes.map { $0.onset + $0.duration }.max() ?? 0, limit) + tail
        let count = Int(total * rate)
        var buffer = [Float](repeating: 0, count: count)
        for note in notes {
            let freq = 440.0 * pow(2.0, (Double(note.pitch) - 69.0) / 12.0)
            let amp = Double(note.velocity) / 127.0 * 0.4
            let start = Int(note.onset * rate)
            let end = min(count, Int((note.onset + note.duration) * rate))
            let dur = max(0.05, note.duration)
            let tau = min(1.8, max(0.25, dur * 0.6))
            var phase = 0.0
            let step = 2.0 * Double.pi * freq / rate
            for i in start..<end {
                let t = Double(i - start) / rate
                var s = 0.0
                for k in 1...6 {
                    s += sin(Double(k) * phase) / Double(k)
                }
                let env = exp(-t / tau) * min(1.0, t / 0.005 + 0.05)
                buffer[i] += Float(amp * env * s * 0.22)
                phase += step
            }
            print(String(format: "gt note: %d @%.3f-%.3f v%d", note.pitch, note.onset, note.onset + note.duration, note.velocity))
        }
        let data = Data(bytes: buffer, count: buffer.count * MemoryLayout<Float>.size)
        do {
            try data.write(to: URL(fileURLWithPath: out))
            print("synth-midi: \(notes.count) notes -> \(out) (\(count) samples at \(Int(rate)) Hz)")
        } catch {
            print("synth-midi FAILED: \(error)")
            exit(1)
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

        guard let result = context.run(windowIndex: 0, edgeSeconds: WindowPlan.standard.segmentSeconds - WindowPlan.standard.padSeconds,
                                       samples: window, deviceRate: 48000,
                                       forcedStartPos: Array(repeating: WindowPlan.standard.padFrames, count: WindowGeometry.symbols.count),
                                       plan: .standard) else {
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

            let result = context.run(windowIndex: 0, edgeSeconds: WindowPlan.standard.segmentSeconds - WindowPlan.standard.padSeconds,
                                     samples: audio,
                                     deviceRate: 44100,
                                     forcedStartPos: Array(repeating: WindowPlan.standard.padFrames, count: WindowGeometry.symbols.count),
                                     plan: .standard)
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
            let pedalSpans = ProcessInfo.processInfo.environment["CDZ_NO_PEDALS"] == nil
                ? file.sustainPedals.map { span in
                    SheetDraft.PedalSpan(
                        startTick: SheetDraft.ticks(seconds: span.start, options: options),
                        endTick: SheetDraft.ticks(seconds: span.end, options: options))
                }
                : []
            let result = SheetDraft.draft(notes: file.notes, options: options, pageWidth: 86,
                                          pedals: pedalSpans)
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

    /// Engraves a MIDI file's session PDF the way a session end writes it,
    /// so the automatic export is verifiable offline: --pdf <mid> <out.pdf>
    static func runPDF(path: String, out: String) {
        MainActor.assumeIsolated {
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
            MusicFont.register()
            guard let file = try? MidiReader.read(url: URL(fileURLWithPath: path)) else {
                print("pdf: cannot read \(path)")
                exit(1)
            }
            do {
                try SheetPDF.write(notes: file.notes, to: URL(fileURLWithPath: out))
                print("pdf: wrote \(out)")
            } catch {
                print("pdf: \(error.localizedDescription)")
                exit(1)
            }
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

    /// Renders the whole practice screen offscreen - paper, panel, keybed
    /// and the endless measure - exactly as the app composes it, seeded with
    /// synthetic notes: --screen-shot. The live screen can only be judged
    /// in the running app, so this is how its composition is inspected.
    /// Captures frames during the panel's unfold morph, to inspect the
    /// animation geometry offscreen: --morph-shot
    static func runMorphShot() {
        MainActor.assumeIsolated {
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
            MusicFont.register()
            let size = NSSize(width: 1080, height: 660)
            let screen = PracticeScreenView(
                transport: PanelTransport(
                    isListening: { true },
                    toggleListening: {},
                    exportEnabled: { true },
                    export: {}
                ),
                onSheetMusic: {}
            )
            screen.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
            screen.setSessions([
                SessionRecord(id: UUID(), name: nil, folderName: "Session 1", startedAt: Date().addingTimeInterval(-3600), durationSeconds: 96, noteCount: 214, hasAudio: true),
                SessionRecord(id: UUID(), name: nil, folderName: "Session 2", startedAt: Date().addingTimeInterval(-7200), durationSeconds: 41, noteCount: 88, hasAudio: false),
            ], playing: nil)
            screen.setNoteCount(12)
            screen.sessionStarted()
            screen.syncTransport()
            screen.layoutSubtreeIfNeeded()
            let scale: CGFloat = 1
            func snap(_ name: String) {
                MainActor.assumeIsolated {
                    screen.layoutSubtreeIfNeeded()
                    let rep = NSBitmapImageRep(
                        bitmapDataPlanes: nil,
                        pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    rep.size = size
                    screen.cacheDisplay(in: screen.bounds, to: rep)
                    if let cg = rep.cgImage,
                       let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "/tmp/morph_\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
                        CGImageDestinationAddImage(dest, cg, nil)
                        CGImageDestinationFinalize(dest)
                    }
                    print("morph-shot: \(name)")
                }
            }
            snap("0_start")
            screen.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.12))
            snap("1_mid")
            RunLoop.main.run(until: Date().addingTimeInterval(0.12))
            snap("2_mid2")
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            snap("3_end")
        }
    }

    static func runScreenShot() {
        MainActor.assumeIsolated {
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
            MusicFont.register()
            let size = NSSize(width: 1080, height: 660)
            let screen = PracticeScreenView(
                transport: PanelTransport(
                    isListening: { true },
                    toggleListening: {},
                    exportEnabled: { true },
                    export: {}
                ),
                onSheetMusic: {}
            )
            screen.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
            screen.setSessions([
                SessionRecord(id: UUID(), name: nil, folderName: "Session 1", startedAt: Date().addingTimeInterval(-3600), durationSeconds: 96, noteCount: 214, hasAudio: true),
                SessionRecord(id: UUID(), name: nil, folderName: "Session 2", startedAt: Date().addingTimeInterval(-7200), durationSeconds: 41, noteCount: 88, hasAudio: false),
                SessionRecord(id: UUID(), name: nil, folderName: "Session 3", startedAt: Date().addingTimeInterval(-90000), durationSeconds: 154, noteCount: 531, hasAudio: true),
            ], playing: nil)
            screen.layoutSubtreeIfNeeded()
            screen.setNoteCount(12)
            screen.sessionStarted()
            for (pitch, age) in [(48, 8.6), (55, 8.5), (72, 6.4), (76, 6.3),
                                 (61, 4.4), (66, 4.3), (70, 2.2), (84, 0.9),
                                 (93, 0.9), (30, 0.4)] {
                screen.noteStruck(NoteEvent(pitch: pitch, velocity: 80, onset: 0, duration: 0.5))
            }
            screen.noteReleased(NoteEvent(pitch: 66, velocity: 80, onset: 0, duration: 0.5))
            screen.syncTransport()

            let scale: CGFloat = 2
            screen.layoutSubtreeIfNeeded()
            // the view tree renders through cacheDisplay: the official
            // window-less render of a view and its subviews
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = size
            screen.cacheDisplay(in: NSRect(x: 0, y: 0, width: size.width, height: size.height), to: rep)
            if let cg = rep.cgImage,
               let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "/tmp/cadenza_screen.png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, cg, nil)
                CGImageDestinationFinalize(dest)
                print("screen-shot: wrote /tmp/cadenza_screen.png")
            }
        }
    }

    /// Renders the in-window sections — the archive and the settings card —
    /// into PNGs through the real overlay host, so layout and the frozen
    /// glass can be inspected without a screen recording of the live app.
    static func runOverlayShot() {
        MainActor.assumeIsolated {
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
            MusicFont.register()
            let size = NSSize(width: 1080, height: 660)
            let transport = PanelTransport(
                isListening: { true },
                toggleListening: {},
                exportEnabled: { true },
                export: {}
            )
            let screen = PracticeScreenView(transport: transport, onSheetMusic: {})
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = screen
            screen.frame = NSRect(origin: .zero, size: size)
            let sessions = [
                SessionRecord(id: UUID(), name: "Chopin, wrong notes", folderName: "Session 1", startedAt: Date().addingTimeInterval(-3600), durationSeconds: 96, noteCount: 214, hasAudio: true),
                SessionRecord(id: UUID(), name: nil, folderName: "Session 2", startedAt: Date().addingTimeInterval(-7200), durationSeconds: 41, noteCount: 88, hasAudio: false),
                SessionRecord(id: UUID(), name: nil, folderName: "Session 3", startedAt: Date().addingTimeInterval(-90000), durationSeconds: 154, noteCount: 531, hasAudio: true),
                SessionRecord(id: UUID(), name: "Late night take", folderName: "Session 4", startedAt: Date().addingTimeInterval(-180000), durationSeconds: 302, noteCount: 811, hasAudio: true),
                SessionRecord(id: UUID(), name: nil, folderName: "Session 5", startedAt: Date().addingTimeInterval(-260000), durationSeconds: 74, noteCount: 190, hasAudio: false),
                SessionRecord(id: UUID(), name: nil, folderName: "Session 6", startedAt: Date().addingTimeInterval(-300000), durationSeconds: 55, noteCount: 120, hasAudio: true),
            ]
            screen.setSessions(sessions, playing: sessions[1])
            screen.layoutSubtreeIfNeeded()

            writeShot(of: screen, size: size, name: "home")
            let archive = SessionsOverlayView(transport: transport,
                                              sessions: sessions,
                                              playing: sessions[1])
            screen.presentOverlay(archive, size: NSSize(width: 620, height: 130 + CGFloat(sessions.count) * 47 + 20))
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            writeShot(of: screen, size: size, name: "sessions")
            screen.dismissOverlay(animated: false)

            let settings = SettingsController().overlayContent()
            screen.presentOverlay(settings, size: NSSize(width: 460, height: 430))
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            writeShot(of: screen, size: size, name: "settings")
            screen.dismissOverlay(animated: false)

            let stats = StatsController().overlayContent(sessions: sessions)
            screen.presentOverlay(stats, size: NSSize(width: 440, height: 300))
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            writeShot(of: screen, size: size, name: "stats")
            screen.dismissOverlay(animated: false)
        }
    }

    /// One offscreen render of a view tree to /tmp, at 2×.
    @MainActor
    private static func writeShot(of view: NSView, size: NSSize, name: String) {
        view.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        view.cacheDisplay(in: NSRect(origin: .zero, size: size), to: rep)
        guard let cg = rep.cgImage,
              let dest = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: "/tmp/cadenza_\(name).png") as CFURL,
                UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
        print("overlay-shot: wrote /tmp/cadenza_\(name).png")
    }

    private static func readF32(_ url: URL) -> [Float] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }
    }
}
