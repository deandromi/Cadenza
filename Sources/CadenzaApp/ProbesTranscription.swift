import AppKit
import AVFoundation
import CadenzaCore
import UniformTypeIdentifiers
import CoreML
import Foundation
import CoreText

extension SmokeMain {
/// Offline transcription diagnostics: capture, replay, streaming latency,
/// the eval harness and its scoring.
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
        // offline there is no live edge to fall behind: the replay cuts at the
        // plan's step, and CDZ_FIXED_STEP poses a different one on purpose
        var step = fixedStep ?? plan.streamingStep
        let pacerOn = ProcessInfo.processInfo.environment["CDZ_PACE"] != nil
        var pacer = DecodePacer(floorStep: plan.streamingStep, ceilingStep: WindowGeometry.stepCeiling)
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
            // the live engine's pacer, fed the same measurements it reads
            if fixedStep == nil, pacerOn {
                // offline there is no live edge; the backlog a decode creates
                // is how much longer it took than the audio it advanced
                step = pacer.record(wall: decodeWall, backlog: max(0, decodeWall - step), decoders: 2)
            }
            edge += step
          }
        }

        // what one window costs on this machine, for the latency budget: a
        // note waits for the step that carries it plus its window's decode
        let walls = schedule.map(\.decodeWall).sorted()
        if !walls.isEmpty {
            let median = walls[walls.count / 2]
            let p90 = walls[Int(Double(walls.count - 1) * 0.9)]
            print(String(format: "decode wall: median %.2f s, p90 %.2f s over %d windows (step floor %.2f s)",
                         median, p90, walls.count, plan.streamingStep))
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

    /// The whole chain, as the app actually runs it: --instant-live-latency
    /// <file.mid> [rate] [tapBuffer] [seconds]. The audio is synthesized from
    /// the MIDI, then delivered into the real AudioTapState in the chunk size
    /// installTap asks for, on a clock that moves at the speed of sound, while
    /// the real InstantStrikeReader polls it every ten milliseconds. What is
    /// measured is wall time from the moment a sample was captured to the
    /// moment the strike left the reader: buffering, the poll, the analysis
    /// window and the confirmation all included, which is the delay a player
    /// feels between the key and the note leaving the app.
    static func runInstantLiveLatency(midiPath: String, rate: Double, tapBuffer: Int, seconds: Double) {
        guard let file = try? MidiReader.read(url: URL(fileURLWithPath: midiPath)) else {
            print("instant-live: cannot read \(midiPath)")
            exit(1)
        }
        let notes = file.notes.filter { $0.onset < seconds }
        guard !notes.isEmpty else {
            print("instant-live: no notes")
            exit(1)
        }
        let samples = synthTones(notes, rate: rate, limit: seconds)
        var attackTable: [Int: [Double]] = [:]
        for note in notes { attackTable[note.pitch, default: []].append(note.onset) }

        final class Collected: @unchecked Sendable {
            var hits: [(pitch: Int, latency: Double, onset: Double)] = []
            var stray = 0
            var started = CACurrentMediaTime()
            let lock = NSLock()
        }
        let collected = Collected()
        let tapState = AudioTapState()
        tapState.reset(rate: rate)
        let attacks = attackTable
        let reader = InstantStrikeReader(tapState: tapState, rate: rate) { strikes in
            let now = CACurrentMediaTime()
            collected.lock.lock()
            defer { collected.lock.unlock() }
            for strike in strikes {
                if let nearest = attacks[strike.pitch]?.min(by: {
                    abs($0 - strike.atSeconds) < abs($1 - strike.atSeconds)
                }), abs(nearest - strike.atSeconds) < 0.20 {
                    // the sample was captured at `nearest`; the reader is
                    // hearing it now
                    let sinceCapture = now - collected.started - nearest
                    collected.hits.append((strike.pitch, sinceCapture, nearest))
                } else {
                    collected.stray += 1
                }
            }
        }
        collected.lock.lock()
        collected.started = CACurrentMediaTime()
        collected.lock.unlock()
        reader.start()
        let started = CACurrentMediaTime()
        // the tap's own rhythm: a buffer of `tapBuffer` frames every
        // tapBuffer / rate seconds, filled from the synthesized audio
        var fed = 0
        let slice = Int(0.010 * rate)
        while fed < samples.count {
            // what the microphone would have captured by now
            let elapsed = CACurrentMediaTime() - started
            let captured = min(samples.count, Int(elapsed * rate))
            // deliver it the way the tap does: whole buffers only
            while captured - fed >= tapBuffer || (captured >= samples.count && fed < samples.count) {
                let end = min(samples.count, fed + tapBuffer)
                tapState.append(Array(samples[fed..<end]))
                fed = end
                if captured - fed < tapBuffer { break }
            }
            _ = slice
            RunLoop.current.run(until: Date().addingTimeInterval(0.002))
        }
        // let the last window and its confirmation land
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        reader.stop()
        collected.lock.lock()
        let hits = collected.hits
        let stray = collected.stray
        collected.lock.unlock()
        let latencies = hits.map(\.latency).sorted()
        guard !latencies.isEmpty else {
            print("instant-live: no strike matched a true attack (\(stray) stray)")
            exit(1)
        }
        let median = latencies[latencies.count / 2]
        let p90 = latencies[Int(Double(latencies.count - 1) * 0.9)]
        print(String(format: "instant-live: tap %d frames (%.0f ms), %d attacks found, %d stray",
                     tapBuffer, Double(tapBuffer) / rate * 1000, latencies.count, stray))
        print(String(format: "instant-live: median %.0f ms, p90 %.0f ms, best %.0f ms, worst %.0f ms",
                     median * 1000, p90 * 1000, latencies.first! * 1000, latencies.last! * 1000))
    }

    /// The instantaneous path's own number: --instant-latency <file.mid>    /// The instantaneous path's own number: --instant-latency <file.mid>
    /// [rate] [maxSeconds]. The MIDI is ground truth, its tone is synthesized
    /// the way --synth-midi does it, and the detector reads it in ten
    /// millisecond chunks exactly as the live reader polls the ring. For every
    /// true attack it prints how long after the attack the strike was
    /// announced, which is the delay a player would feel between the key and
    /// the note leaving the app.
    static func runInstantLatency(midiPath: String, rate: Double, maxSeconds: Double?) {
        guard let file = try? MidiReader.read(url: URL(fileURLWithPath: midiPath)) else {
            print("instant-latency: cannot read \(midiPath)")
            exit(1)
        }
        let limit = maxSeconds ?? .infinity
        let notes = file.notes.filter { $0.onset < limit }
        guard !notes.isEmpty else {
            print("instant-latency: no notes")
            exit(1)
        }
        let samples = synthTones(notes, rate: rate, limit: limit)
        let detector = InstantOnsetDetector(rate: rate)
        let chunk = Int(0.010 * rate)
        // every true attack, by key: a strike is read against the nearest one
        var attacks: [Int: [Double]] = [:]
        for note in notes { attacks[note.pitch, default: []].append(note.onset) }
        for pitch in attacks.keys { attacks[pitch]?.sort() }
        var covered = Set<String>()
        var fed = 0
        var latencies: [Double] = []
        var stray = 0
        var repeats = 0
        while fed < samples.count {
            let end = min(fed + chunk, samples.count)
            for strike in detector.push(Array(samples[fed..<end])) {
                let announced = Double(end) / rate
                guard let nearest = attacks[strike.pitch]?.min(by: {
                    abs($0 - strike.atSeconds) < abs($1 - strike.atSeconds)
                }), abs(nearest - strike.atSeconds) < 0.20 else {
                    stray += 1
                    continue
                }
                let key = "\(strike.pitch)@\(Int(nearest * 1000))"
                if covered.contains(key) {
                    repeats += 1
                } else {
                    covered.insert(key)
                    latencies.append(announced - nearest)
                }
            }
            fed = end
        }
        let missed = notes.count - covered.count
        guard !latencies.isEmpty else {
            print("instant-latency: no strike matched a true attack (\(stray) stray)")
            exit(1)
        }
        let sorted = latencies.sorted()
        let median = sorted[sorted.count / 2]
        let p90 = sorted[Int(Double(sorted.count - 1) * 0.9)]
        print(String(format: "instant-latency: %d attacks of %d found, %d missed, %d stray, %d repeated",
                     covered.count, notes.count, missed, stray, repeats))
        print(String(format: "instant-latency: median %.0f ms, p90 %.0f ms, best %.0f ms, worst %.0f ms",
                     median * 1000, p90 * 1000, sorted.first! * 1000, sorted.last! * 1000))
        let raw = zip(sorted, 0...).map { value, index in
            String(format: "%d:%.0f", index, value * 1000)
        }
        print("instant-latency ms: \(raw.prefix(24).joined(separator: " "))")
    }

    /// Times a handful of window decodes and reports what the notebook sees:    /// Times a handful of window decodes and reports what the notebook sees:
    /// --decode-bench <audio.f32> <rate> <windows>. The decode is the part of
    /// the latency the pipeline cannot hide behind a step, so this is the
    /// number that decides whether sub-second note delivery is possible at
    /// all, and the number an A/B on compute units is read against.
    static func runDecodeBench(audioPath: String, deviceRate: Double, windows: Int) {
        guard let assets = AppDelegate.locateAssets() else {
            print("decode-bench: model assets not found")
            exit(1)
        }
        let context: InferenceContext
        do {
            context = try InferenceContext(tensorsDir: assets.tensors, modelURL: assets.model)
        } catch {
            print("decode-bench FAILED: \(error)")
            exit(1)
        }
        let data = (try? Data(contentsOf: URL(fileURLWithPath: audioPath))) ?? Data()
        let input = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard !input.isEmpty else {
            print("decode-bench: no audio at \(audioPath)")
            exit(1)
        }
        let plan = WindowPlan.standard
        let tapState = AudioTapState()
        tapState.reset(rate: deviceRate, plan: plan)
        var fed = 0
        var walls: [Double] = []
        var notes = 0
        let step = plan.stepWallSeconds
        for index in 0..<windows {
            let edge = plan.segmentSeconds + Double(index) * step
            Self.feed(tapState, from: input, fed: &fed, upTo: Int((edge * deviceRate).rounded()))
            guard let window = tapState.takeStreamWindow(edgeSeconds: edge) else { break }
            let forced = Array(repeating: 0, count: WindowGeometry.symbols.count)
            let start = CACurrentMediaTime()
            guard let result = context.run(windowIndex: index, edgeSeconds: edge, samples: window,
                                           deviceRate: deviceRate, forcedStartPos: forced, plan: plan) else {
                print("decode-bench: decode \(index) failed")
                break
            }
            let wall = CACurrentMediaTime() - start
            walls.append(wall)
            notes += result.events.filter { $0.hasOnset }.count
            print(String(format: "decode-bench: window %d wall %.2f s, %d events", index, wall, result.events.count))
        }
        guard !walls.isEmpty else { exit(1) }
        let sorted = walls.sorted()
        let median = sorted[sorted.count / 2]
        print(String(format: "decode-bench: %d windows, median %.2f s, min %.2f s, max %.2f s, %d strikes",
                     walls.count, median, sorted.first!, sorted.last!, notes))
    }

    /// Prints the mel front end's view of one instant: the strongest bands    /// Prints the mel front end's view of one instant: the strongest bands
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
        if ProcessInfo.processInfo.environment["CDZ_DUMP_OFFSETS"] == "1" {
            // the pairs, worst first: what the length error actually is,
            // not just how big it is on average
            var pairs: [(error: Double, detected: NoteEvent, truth: NoteEvent)] = []
            var usedTruth = Set<Int>()
            for note in notes.sorted(by: { $0.onset < $1.onset }) {
                var best: (index: Int, distance: Double)?
                for (index, candidate) in truth.enumerated() where !usedTruth.contains(index) {
                    guard candidate.pitch == note.pitch else { continue }
                    let distance = abs(candidate.onset - note.onset)
                    if distance <= 0.075, distance < (best?.distance ?? .infinity) {
                        best = (index, distance)
                    }
                }
                if let best {
                    usedTruth.insert(best.index)
                    pairs.append((note.offset - truth[best.index].offset, note, truth[best.index]))
                }
            }
            for pair in pairs.sorted(by: { abs($0.error) > abs($1.error) }).prefix(12) {
                print(String(format: "len %+.2f s · pitch %d · detected %.2f-%.2f (%.2f) · truth %.2f-%.2f (%.2f)",
                             pair.error, pair.detected.pitch,
                             pair.detected.onset, pair.detected.offset, pair.detected.duration,
                             pair.truth.onset, pair.truth.offset, pair.truth.duration))
            }
        }
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
}
