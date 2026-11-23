import AVFoundation
import CadenzaCore
import Combine
import CoreAudio
import CoreML
import Foundation

/// The live transcription engine: captures microphone audio, runs the CoreML
/// backbone over one 16 s window at a time (slid 8 s at a time the way
/// transkun's transcribe() does), decodes with the semi-CRF viterbi and
/// publishes merged NoteEvents plus identified chords as it goes.
@MainActor
final class TranscriptionEngine: ObservableObject {
    enum NoteEventKind { case struck, extended, released }

    @Published private(set) var isRunning = false
    @Published private(set) var level: Float = 0
    @Published private(set) var lastError: String?

    /// The merged performance history, growing as windows confirm notes.
    @Published private(set) var notes: [NoteEvent] = []
    /// Chord sheet rows over the history, recomputed as notes arrive.
    @Published private(set) var sheet: [SheetEntry] = []
    /// The most recent chord by onset, if any.
    @Published private(set) var currentChord: Chord?
    @Published private(set) var noteCount = 0

    /// Fired on the main actor for every emission from the streaming merge:
    /// fresh strikes as `.struck`, pedal-tail prolongations as `.extended`,
    /// releases as `.released` (carrying the note's sounding interval).
    var onNoteEvent: ((NoteEvent, NoteEventKind) -> Void)?

    /// Per-window trace of the pipeline. A session submits a window twice a
    /// second, so this is opt-in: CADENZA_DEBUG_ENGINE=1 turns it on.
    static let verbose = ProcessInfo.processInfo.environment["CADENZA_DEBUG_ENGINE"] != nil

    /// Windows skipped because the audio under them was silent.
    private var skippedWindows = 0
    /// Room floor for the silence skip: about -56 dBFS, under a piano's
    /// quietest note and above a quiet room's noise.
    static let silencePeak: Float = 0.0016
    /// The room floor for background listening, louder than a take's: a
    /// played piano is far above it, a fan, a fridge and a laptop's own
    /// microphone hiss are below it, and everything below it costs nothing.
    static let ambientPeak: Float = 0.008
    /// A study switch: CADENZA_NO_SILENCE_SKIP=1 decodes silence too.
    static let skipsSilence = ProcessInfo.processInfo.environment["CADENZA_NO_SILENCE_SKIP"] == nil

    private let audioEngine = AVAudioEngine()
    private var tapState = AudioTapState()
    /// two decoders run in parallel, alternating windows: a fresh window
    /// starts every `streamingStep` while the previous one still decodes,
    /// so the decode latency stops pacing the stream
    private var decoders: [InferenceContext] = []
    private var decoderBusy: [Bool] = []
    /// decoded windows awaiting in-order absorption
    private var pendingWindows: [Int: WindowResult] = [:]
    private var nextWindowToAbsorb = 0
    /// wall seconds the most recent decode took, for the log
    private var lastDecodeWall = 0.0
    /// the session's window geometry
    private var plan: WindowPlan = .standard
    private var tickTimer: Timer?
    private var levelTimer: Timer?
    /// whether capture writes a wav for a take, or only holds the minute
    private var recordsSession = true
    /// decodes performed this session, for logging only
    private var windowIndex = 0
    /// content seconds at which the next window's trailing edge sits
    private var nextEdge = WindowPlan.standard.streamingWarmup
    /// the pace the windows are cut at: the pacer measures each decode and
    /// moves the step between the plan's floor and the ceiling
    private var pacer = DecodePacer(floorStep: WindowPlan.standard.streamingStep,
                                   ceilingStep: WindowGeometry.stepCeiling)
    private var currentStep: Double { pacer.step }
    /// the edge of the last window that made it into the history: what the
    /// pacer reads the backlog against
    private var absorbedEdge = WindowPlan.standard.streamingWarmup
    /// the streaming merge state: anchors, live notes, merged history
    private var merge = StreamingMerge(symbolCount: WindowGeometry.symbols.count)
    /// when the current capture session began, for the silence watchdog
    private var captureStarted = Date()

    enum EngineError: LocalizedError {
        case microphoneUnavailable
        case tensorsNotFound
        case modelLoadFailed

        var errorDescription: String? {
            switch self {
            case .microphoneUnavailable: return "No input device is available"
            case .tensorsNotFound: return "The transcription model files are missing"
            case .modelLoadFailed: return "The transcription model failed to load"
            }
        }
    }

    /// Asks for microphone access, then begins capture and inference.
    /// A start while already running is a no-op: the transport toggles.
    ///
    /// `recordSession` is what separates listening from taking: with the
    /// rolling minute on, the app listens from launch without writing a
    /// wav, so an hour of sitting at the piano does not become an hour-long
    /// file. A session starts its wav when the player asks for one.
    func start(tensorsDir: URL, modelURL: URL, recordSession: Bool = true) {
        guard !isRunning else { return }
        recordsSession = recordSession
        // @Sendable: the answer arrives on a queue of Apple's choosing, and a
        // closure that inherited this type's main-actor isolation would trap
        // there instead of hopping back
        AVAudioApplication.requestRecordPermission { @Sendable [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                print("[engine] microphone granted: \(granted)")
                if granted {
                    self.beginCapture(tensorsDir: tensorsDir, modelURL: modelURL)
                } else {
                    self.lastError = "Microphone access was denied, allow Cadenza in System Settings under privacy, microphone"
                }
            }
        }
    }

    /// Points the input unit at the device chosen in settings; 0 keeps the
    /// system default. A stale id (a device that left) logs and falls back.
    private static func selectInputDevice(on node: AVAudioInputNode) {
        let wanted = SettingsKeys.inputDeviceID
        guard wanted != 0, let unit = node.audioUnit else { return }
        var device = AudioDeviceID(wanted)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &device, size)
        if status != noErr {
            print("[engine] input device selection failed, using default (\(status))")
        }
    }

    private func beginCapture(tensorsDir: URL, modelURL: URL) {
        print("[engine] begin capture: \(tensorsDir.path)")
        do {
            let modelURL = modelURL
            plan = .standard
            if decoders.isEmpty {
                decoders = try Self.buildDecoders(tensorsDir: tensorsDir, modelURL: modelURL)
                decoderBusy = Array(repeating: false, count: decoders.count)
            }
            let input = audioEngine.inputNode
            Self.selectInputDevice(on: input)
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw EngineError.microphoneUnavailable
            }
            print("[engine] capture: \(format.sampleRate) Hz, \(format.channelCount) channels, \(decoders.count) pipelined decoders, \(plan.segmentSeconds) s windows")
            tapState.reset(
                rate: format.sampleRate, plan: plan,
                tuningA4: SettingsKeys.tuningA4, gain: SettingsKeys.inputGain,
                retroSeconds: SettingsKeys.keepRecentMinute ? SettingsKeys.retroWindow + 2 : 0)
            if recordsSession {
                tapState.startRecording(url: Self.recordingTempURL())
            }
            windowIndex = 0
            nextEdge = plan.streamingWarmup
            pacer = DecodePacer(floorStep: plan.streamingStep, ceilingStep: WindowGeometry.stepCeiling)
            absorbedEdge = plan.streamingWarmup
            lastDecodeWall = 0
            pendingWindows = [:]
            nextWindowToAbsorb = 0
            merge = StreamingMerge(symbolCount: WindowGeometry.symbols.count, plan: plan)
            notes = []
            sheet = []
            currentChord = nil
            noteCount = 0
            input.removeTap(onBus: 0)
            // 4096 frames: the tap chunk bounds how long the ring waits for
            // its trailing edge; smaller buffers only add callback overhead
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable [tapState] buffer, _ in
                // InstallTap's block is the plain ObjC type, so without
                // @Sendable this closure literal would inherit the enclosing
                // @MainActor isolation and trap when AVFoundation calls it
                // on its realtime queue.
                guard let channel = buffer.floatChannelData?[0] else { return }
                // straight from the capture buffer: no array is built on the
                // audio thread, and nothing here touches the disk
                tapState.append(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            }
            try audioEngine.start()
            // ticks are fast and cheap: they only submit the next window when
            // its trailing edge has arrived, so decodes pipeline back to back
            // 100 ms: the tick only submits the next window when its trailing
            // edge has arrived, so tighter pacing trims the submission tail
            tickTimer = Clock.every(0.1) { [weak self] in self?.tick() }
            levelTimer = Clock.every(0.5) { [weak self] in
                guard let self else { return }
                self.level = self.tapState.currentLevel()
                // the recording is written from here, never from the tap
                self.tapState.drainRecording()
            }
            isRunning = true
            lastError = nil
            captureStarted = Date()
            print("[engine] capture started")
        } catch {
            isRunning = false
            lastError = error.localizedDescription
            print("[engine] capture failed: \(error.localizedDescription)")
        }
    }

    /// The raw last `seconds` of microphone, with the content second it
    /// starts at. What a kept minute is made of: the notes come from the
    /// engine, the audio from here, and the two are cut to each other.
    func retroAudio(seconds: Double) -> (samples: [Float], rate: Double, startSeconds: Double)? {
        tapState.retroAudio(seconds: seconds)
    }

    /// The streaming wav the session that just stopped recorded into, at
    /// device rate. The app shell moves it into the session folder or
    /// deletes it; nil captures nothing.
    private(set) var lastRecording: (url: URL, rate: Double)?

    func stop() {
        guard isRunning else { return }
        tickTimer?.invalidate()
        tickTimer = nil
        levelTimer?.invalidate()
        levelTimer = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isRunning = false
        if Self.verbose, skippedWindows > 0 {
            print("[engine] skipped \(skippedWindows) silent windows, no decode spent on them")
        }
        skippedWindows = 0
        lastRecording = takeRecording()
    }

    private func takeRecording() -> (url: URL, rate: Double)? {
        let rate = tapState.deviceRate()
        guard let url = tapState.finishRecording() else { return nil }
        return (url, rate)
    }

    /// Deletes the last session's wav without saving it anywhere.
    func discardRecording() {
        if let lastRecording {
            try? FileManager.default.removeItem(at: lastRecording.url)
        }
        lastRecording = nil
    }

    /// Where a session's mic capture streams while it runs. One scratch
    /// file per process: a new session overwrites the previous one, which
    /// by then lives in the session folder it belongs to.
    static func recordingTempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Cadenza capture.wav")
    }

    /// audio content captured so far this session, for diagnostics
    var capturedSeconds: Double {
        tapState.receivedSeconds()
    }

    /// One scheduled step: submit every window whose trailing edge has
    /// arrived while a decoder is free. With two decoders alternating, a
    /// window starts every `streamingStep` even though a decode takes about
    /// twice that; the results absorb in window order as they land.
    private func tick() {
        guard isRunning else { return }
        let received = tapState.receivedSeconds()
        // Background listening has to be cheap enough to leave running all
        // day. It reads the last two seconds rather than the whole window
        // (a take counts a note's tail as sound, the minute does not) and it
        // decodes every other step, so an idle room costs no decode and a
        // busy one costs half of what a take costs.
        if !recordsSession {
            if tapState.recentPeak(seconds: 2.0) < Self.ambientPeak {
                if received - nextEdge > 30 { nextEdge = received }
                while received >= nextEdge { nextEdge += currentStep }
                return
            }
        }
        let step = recordsSession ? currentStep : currentStep * 2
        if received < 1.0, Date().timeIntervalSince(captureStarted) > 15 {
            stop()
            lastError = "Not hearing any input, check the microphone settings"
            return
        }
        var guardCount = 0
        while received >= nextEdge, let slot = decoderBusy.firstIndex(of: false) {
            let edge = nextEdge
            // Silence costs nothing to skip: a window whose newest step is
            // below the room floor has no note in it, so the decode that
            // would prove that is pure heat. The cursor still advances, so
            // the next window is cut in the same grid and keeps its history.
            if Self.skipsSilence, edge > plan.segmentSeconds + 0.5,
               tapState.recentPeak(seconds: plan.segmentSeconds) < Self.silencePeak,
               !notes.contains(where: { $0.offset > edge - 2.0 }) {
                // Only a window whose whole 16 s is silent is skipped, and
                // only when nothing is still sounding: the merge carries note
                // state from window to window, so cutting a decode out of the
                // middle of sounding music invented thousands of repeats.
                nextEdge = edge + step
                skippedWindows += 1
                continue
            }
            if Self.verbose {
                print("[engine] window \(windowIndex) submitted on decoder \(slot), edge \(String(format: "%.2f", edge)) s, \(Int(received)) s captured so far")
            }
            decoderBusy[slot] = true
            submitWindow(index: windowIndex, edge: edge, slot: slot)
            windowIndex += 1
            nextEdge = edge + step
            guardCount += 1
            if guardCount > 64 { break }
        }
    }

    /// Builds the pipelined decoders: two independent CoreML contexts so
    /// two windows decode at once. The compiles run in parallel, each into its
    /// own slot, so the result order is the slot order and no append can race.
    private static func buildDecoders(tensorsDir: URL, modelURL: URL) throws -> [InferenceContext] {
        final class Slots: @unchecked Sendable {
            var decoders: [InferenceContext?] = [nil, nil]
            var failure: Error?
            let lock = NSLock()
        }
        let slots = Slots()
        DispatchQueue.concurrentPerform(iterations: slots.decoders.count) { index in
            let outcome = Result { try InferenceContext(tensorsDir: tensorsDir, modelURL: modelURL) }
            slots.lock.lock()
            defer { slots.lock.unlock() }
            switch outcome {
            case .success(let decoder): slots.decoders[index] = decoder
            case .failure(let error): slots.failure = error
            }
        }
        if let failure = slots.failure { throw failure }
        let built = slots.decoders.compactMap { $0 }
        guard built.count == 2 else { throw EngineError.modelLoadFailed }
        return built
    }

    private func submitWindow(index: Int, edge: Double, slot: Int) {
        guard decoders.indices.contains(slot) else { return }
        guard let deviceSamples = tapState.takeStreamWindow(edgeSeconds: edge) else {
            nextEdge = min(nextEdge, tapState.receivedSeconds())
            decoderBusy[slot] = false
            return
        }
        let forcedStart = merge.forcedStart(for: edge - plan.segmentSeconds)
        let deviceRate = tapState.deviceRate()
        let decoder = decoders[slot]
        let plan = self.plan
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let decodeStart = CACurrentMediaTime()
            let result = decoder.run(windowIndex: index, edgeSeconds: edge, samples: deviceSamples,
                                     deviceRate: deviceRate, forcedStartPos: forcedStart, plan: plan)
            let decodeWall = CACurrentMediaTime() - decodeStart
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.decoderBusy[slot] = false
                self.lastDecodeWall = decodeWall
                // the pacer reads what the pipeline is carrying, not what
                // one decode looked like on one machine
                self.pacer.record(wall: decodeWall,
                                  backlog: self.tapState.receivedSeconds() - self.absorbedEdge,
                                  decoders: self.decoderBusy.count)
                if let result {
                    self.pendingWindows[index] = result
                    self.drainPending()
                }
            }
        }
    }

    /// Absorbs decoded windows in window order: the merge's anchors and
    /// live notes assume windows arrive the way they were cut, so a window
    /// that finished early waits for its predecessors in the pending buffer.
    private func drainPending() {
        while let result = pendingWindows.removeValue(forKey: nextWindowToAbsorb) {
            absorbWindow(result)
            nextWindowToAbsorb += 1
        }
    }

    /// Applies one decoded window: the streaming merge extends the history
    /// and reports what is worth emitting live; the chord sheet recomputes
    /// over the whole history.
    private func absorbWindow(_ result: WindowResult) {
        for emission in merge.absorb(result) {
            let kind: NoteEventKind
            switch emission.kind {
            case .struck: kind = .struck
            case .extended: kind = .extended
            case .released: kind = .released
            }
            onNoteEvent?(emission.event, kind)
        }
        absorbedEdge = max(absorbedEdge, result.edgeSeconds)
        notes = merge.notes
        noteCount = merge.notes.count
        recomputeChords()
    }

    private func recomputeChords() {
        let entries = ChordSheet.entries(for: notes)
            .map { SheetEntry(onset: $0.onset, chord: $0.chord) }
        sheet = entries
        currentChord = entries.last?.chord
    }
}
