import AVFoundation
import CadenzaCore
import Combine
import CoreML
import Foundation

/// Window geometry constants, mirroring transkun's transcribe() exactly and
/// readable from any isolation domain (the tap, the inference queue, main).
enum WindowGeometry {
    static let sampleRate: Double = 44100.0
    static let hopSize = 1024
    static let segmentSeconds = 16.0
    static let padSeconds = 8.0
    static let segmentSamples = 705600          // 16 s at 44100, 691 frames
    static let stepSamples = 353280             // one step: 345 hops
    static let stepFrames = stepSamples / hopSize   // 345 hops per step
    static let padFrames: Int = Int((8.0 * sampleRate) / Double(hopSize)) // 344
    /// a decoded interval reaching this frame is cut off by the window edge
    static let lastFrameIdx = 689
    static let frameDuration = Double(hopSize) / sampleRate
    static let stepWallSeconds = Double(stepSamples) / sampleRate
    static let symbols: [Int] = [-64, -67] + Array(21...108)
    /// Notes shorter than this are dropped at merge time: on room-tone
    /// recordings the reference model fires phantoms of 47 to 52 ms in the
    /// low register, and they poison chords and MIDI output. Real staccato
    /// notes ring longer.
    static let minimumNoteDuration = 0.055
}

/// One chord sheet row: an onset group with its identified chord.
struct SheetEntry: Sendable {
    let onset: Double
    let chord: Chord
}

/// A decoded window: refined events in performance seconds plus the
/// per-symbol bookkeeping the next window continues from.
struct WindowResult: Sendable {
    struct Event: Sendable {
        let pitch: Int
        let velocity: Int
        let startFrame: Int
        let endFrame: Int
        let onsetSeconds: Double
        let offsetSeconds: Double
        let presenceOnset: Bool
        let presenceOffset: Bool

        /// True unless the interval merely continues from the window start
        /// (a note sounding before this window began, no onset observed).
        var hasOnset: Bool { startFrame > 0 || presenceOnset }
    }

    let windowIndex: Int
    let events: [Event]
    /// per symbol: end frame of the last interval whose offset was observed
    /// in this window, 0 when the symbol never ended here
    let lastP: [Int]
}

/// Thread-safe sample ring for the audio tap. Holds recent performance
/// samples at the device rate; hands out one window per transcription step
/// and trims what the next window can no longer need.
final class AudioTapState: @unchecked Sendable {
    private let lock = NSLock()
    private var ring: [Float] = []
    /// absolute sample index (since stream start) of ring[0]
    private var ringStart = 0
    /// CACurrentMediaTime of the first sample ever appended, the wall clock
    /// of performance second zero
    private var firstAppendWall: Double?
    private var rate: Double = 44100
    /// rms of the most recent tap buffer, read by the level timer on main
    private var latestLevel: Float = 0
    /// full-session mirror of the tap, for offline diagnostics
    private var rawAll: [Float] = []
    private var recordingRaw = false

    func reset(rate: Double) {
        lock.lock()
        defer { lock.unlock() }
        ring = []
        ringStart = 0
        firstAppendWall = nil
        self.rate = rate
        rawAll = []
    }

    func setRecording(_ on: Bool) {
        lock.lock()
        defer { lock.unlock() }
        recordingRaw = on
    }

    func drainRaw() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let copy = rawAll
        rawAll = []
        return copy
    }

    func append(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        if firstAppendWall == nil { firstAppendWall = CACurrentMediaTime() }
        ring.append(contentsOf: samples)
        if recordingRaw {
            rawAll.append(contentsOf: samples)
            let cap = Int(300 * rate)
            if rawAll.count > cap {
                rawAll.removeFirst(rawAll.count - cap)
            }
        }
        var sum = 0.0
        for sample in samples { sum += Double(sample) * Double(sample) }
        latestLevel = Float(sqrt(sum / Double(max(samples.count, 1))))
        // keep at most a minute; older audio can no longer be needed
        let cap = Int(120 * rate)
        if ring.count > cap {
            let drop = ring.count - cap
            ring.removeFirst(drop)
            ringStart += drop
        }
    }

    /// CACurrentMediaTime of the first appended sample, or nil while nothing
    /// has arrived yet.
    func contentOrigin() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return firstAppendWall
    }

    func currentLevel() -> Float {
        lock.lock()
        defer { lock.unlock() }
        return latestLevel
    }

    func receivedSeconds() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(ringStart + ring.count) / rate
    }

    func deviceRate() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return rate
    }

    /// Returns the window `index`'s full content, or nil while not enough of
    /// it has arrived. Window `index` covers performance seconds
    /// `index * stepSeconds - padSeconds` through `+ segmentSeconds`.
    func takeWindow(index: Int) -> [Float]? {
        let stepSeconds = WindowGeometry.stepWallSeconds
        let startSeconds = Double(index) * stepSeconds - WindowGeometry.padSeconds
        let endSeconds = startSeconds + WindowGeometry.segmentSeconds
        let startSample = Int((startSeconds * rate).rounded())
        let endSample = Int((endSeconds * rate).rounded())

        lock.lock()
        defer { lock.unlock() }
        guard ringStart + ring.count >= endSample else { return nil }
        var out = [Float](repeating: 0, count: max(endSample - startSample, 0))
        let from = max(startSample, ringStart)
        let to = min(endSample, ringStart + ring.count)
        if to > from {
            out.replaceSubrange((from - startSample)..<(to - startSample),
                                with: ring[(from - ringStart)..<(to - ringStart)])
        }
        // the next window starts one step later; everything before is spent
        let nextStartSample = Int(((Double(index + 1) * stepSeconds - WindowGeometry.padSeconds) * rate).rounded())
        if nextStartSample > ringStart {
            let drop = min(nextStartSample - ringStart, ring.count)
            ring.removeFirst(drop)
            ringStart += drop
        }
        return out
    }
}

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
        configuration.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: compiled, configuration: configuration)
    }

    /// Decodes one window: aligns the samples to exactly one segment,
    /// computes mel features, runs the backbone, walks the forced-start
    /// viterbi and refines every interval with the attribute heads. Events
    /// come back sorted by (onset, offset, pitch).
    func run(windowIndex: Int, samples: [Float], deviceRate: Double, forcedStartPos: [Int]) -> WindowResult? {
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
        let frames = mel.compute(Self.alignToSegment(at44100))
        let t = frames.count / (MelFrontEnd.nMels * MelFrontEnd.nChannels)
        guard t > 1 else { return nil }
        print("[inference] window \(windowIndex): \(at44100.count) samples at 44100, \(t) frames")

        guard let features = try? MLMultiArray(
            shape: [1, t, MelFrontEnd.nMels, MelFrontEnd.nChannels] as [NSNumber],
            dataType: .float32) else { return nil }
        let destination = features.dataPointer.assumingMemoryBound(to: Float.self)
        frames.withUnsafeBufferPointer { pointer in
            destination.update(from: pointer.baseAddress!, count: frames.count)
        }
        guard let prediction = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["mel": features])),
              let scoreArray = prediction.featureValue(for: "S")?.multiArrayValue,
              let skipArray = prediction.featureValue(for: "S_skip")?.multiArrayValue,
              let contextArray = prediction.featureValue(for: "ctx")?.multiArrayValue else { return nil }

        let symbolCount = WindowGeometry.symbols.count
        let score = copy(scoreArray)
        let skip = copy(skipArray)
        let context = copy(contextArray)
        let intervals = SemiCRFDecoder.decode(score: score, skip: skip, frameCount: t,
                                              symbolCount: symbolCount, forcedStartPos: forcedStartPos)

        let beginTime = Double(windowIndex) * WindowGeometry.stepWallSeconds - WindowGeometry.padSeconds
        var events: [WindowResult.Event] = []
        var lastP = Array(repeating: 0, count: symbolCount)
        for symbol in 0..<symbolCount {
            let pitch = WindowGeometry.symbols[symbol]
            guard (21...108).contains(pitch) else { continue }
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
                let onsetShift = Self.offsetValue(refined[0]) * WindowGeometry.frameDuration
                let offsetShift = Self.offsetValue(refined[1]) * WindowGeometry.frameDuration
                let presenceOnset = refined[2] > 0
                let presenceOffset = refined[3] > 0

                var onset = beginTime + Double(interval.start) * WindowGeometry.frameDuration + onsetShift
                var offset = beginTime + Double(interval.end) * WindowGeometry.frameDuration + offsetShift
                onset = max(onset, lastEnd)
                offset = max(offset, onset + 1e-8)
                lastEnd = offset

                events.append(WindowResult.Event(
                    pitch: pitch, velocity: velocity,
                    startFrame: interval.start, endFrame: interval.end,
                    onsetSeconds: onset, offsetSeconds: offset,
                    presenceOnset: presenceOnset, presenceOffset: presenceOffset))
                if interval.end < WindowGeometry.lastFrameIdx || presenceOffset {
                    lastP[symbol] = interval.end
                }
            }
        }
        events.sort { a, b in
            if a.onsetSeconds != b.onsetSeconds { return a.onsetSeconds < b.onsetSeconds }
            if a.offsetSeconds != b.offsetSeconds { return a.offsetSeconds < b.offsetSeconds }
            return a.pitch < b.pitch
        }
        print("[inference] window \(windowIndex): \(events.count) events decoded in \(String(format: "%.2f", CACurrentMediaTime() - decodeStart)) s")
        return WindowResult(windowIndex: windowIndex, events: events, lastP: lastP)
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

    private static func alignToSegment(_ input: [Float]) -> [Float] {
        var out = input
        if out.count > WindowGeometry.segmentSamples {
            out.removeLast(out.count - WindowGeometry.segmentSamples)
        } else if out.count < WindowGeometry.segmentSamples {
            out.append(contentsOf: [Float](repeating: 0, count: WindowGeometry.segmentSamples - out.count))
        }
        return out
    }

    static func resample(_ input: [Float], from: Double, to: Double) -> [Float]? {
        Resampler.convert(input, from: from, to: to)
    }
}

/// The live transcription engine: captures microphone audio, runs the CoreML
/// backbone over one 16 s window at a time (slid 8 s at a time the way
/// transkun's transcribe() does), decodes with the semi-CRF viterbi and
/// publishes merged NoteEvents plus identified chords as it goes.
@MainActor
final class TranscriptionEngine: ObservableObject {
    enum NoteEventKind { case struck, extended }

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

    /// Fired on the main actor for every confirmed event: fresh strikes and
    /// re-onsets as `.struck`, pedal-tail prolongations as `.extended`.
    var onNoteEvent: ((NoteEvent, NoteEventKind) -> Void)?

    /// Fired on the main actor when performance time zero is established:
    /// the first audio the tap sees, carrying the wall clock
    /// (CACurrentMediaTime) of that moment.
    var onPerformanceStarted: ((Double) -> Void)?

    /// Fired on the main actor after each window's events are merged,
    /// carrying how many performance seconds of audio the latest decode
    /// covered: `windowIndex * step - pad + segment`.
    var onWindowCovered: ((Double) -> Void)?

    private let audioEngine = AVAudioEngine()
    private let inferenceQueue = DispatchQueue(label: "dev.cadenza.transcription", qos: .userInitiated)
    private var tapState = AudioTapState()
    private var inference: InferenceContext?
    private var tickTimer: Timer?
    private var levelTimer: Timer?
    private var processing = false
    private var windowIndex = 0
    private var skippedTicks = 0
    /// merged note history, append-ordered by confirmation
    private var history: [NoteEvent] = []
    /// pitch → index into history of that pitch's current sounding event
    private var liveIndex: [Int: Int] = [:]
    /// when the current capture session began, for the silence watchdog
    private var captureStarted = Date()
    /// per symbol: end frame of the last interval whose offset was observed
    private var lastP: [Int] = []
    /// whether the wall clock of performance second zero has been reported
    private var originDelivered = false
    /// CACurrentMediaTime at performance second zero, set once the first
    /// audio arrives
    private var performanceOrigin: Double = 0

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
    func start(tensorsDir: URL, modelURL: URL) {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                if granted {
                    self.beginCapture(tensorsDir: tensorsDir, modelURL: modelURL)
                } else {
                    self.lastError = "Microphone access was denied, allow Cadenza in System Settings under privacy, microphone"
                }
            }
        }
    }

    private func beginCapture(tensorsDir: URL, modelURL: URL) {
        do {
            if inference == nil {
                inference = try InferenceContext(tensorsDir: tensorsDir, modelURL: modelURL)
            }
            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw EngineError.microphoneUnavailable
            }
            print("[engine] capture: \(format.sampleRate) Hz, \(format.channelCount) channels")
            tapState.reset(rate: format.sampleRate)
            windowIndex = 0
            skippedTicks = 0
            lastP = Array(repeating: 0, count: WindowGeometry.symbols.count)
            liveIndex = [:]
            history = []
            notes = []
            sheet = []
            currentChord = nil
            noteCount = 0
            originDelivered = false
            tapState.setRecording(true)
            input.installTap(onBus: 0, bufferSize: 8192, format: format) { @Sendable [tapState] buffer, _ in
                // InstallTap's block is the plain ObjC type, so without
                // @Sendable this closure literal would inherit the enclosing
                // @MainActor isolation and trap when AVFoundation calls it
                // on its realtime queue.
                guard let channel = buffer.floatChannelData?[0] else { return }
                let frames = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
                tapState.append(Array(frames))
            }
            try audioEngine.start()
            // ticks are one second apart so a window is taken as soon as its
            // full content has arrived; a full step of tick quantization would
            // otherwise sit on top of the 16 s window as extra latency
            tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            levelTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.level = self.tapState.currentLevel()
                }
            }
            isRunning = true
            lastError = nil
            captureStarted = Date()
            print("[engine] capture started")
        } catch {
            isRunning = false
            lastError = error.localizedDescription
        }
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        levelTimer?.invalidate()
        levelTimer = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isRunning = false
        dumpSessionRecording()
    }

    /// Writes the session's raw mic capture (device rate) next to the other
    /// diagnostics, so a failed session can be replayed offline.
    private func dumpSessionRecording() {
        let raw = tapState.drainRaw()
        tapState.setRecording(false)
        guard !raw.isEmpty else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let url = URL(fileURLWithPath: "/tmp/cadenza_session_\(stamp.prefix(19)).f32")
        raw.withUnsafeBufferPointer { pointer in
            let data = Data(bytes: pointer.baseAddress!, count: raw.count * 4)
            try? data.write(to: url)
        }
        print("[engine] session mic capture written to \(url.path), \(raw.count) samples at \(Int(tapState.deviceRate())) Hz")
    }

    /// audio content captured so far this session, for diagnostics
    var capturedSeconds: Double {
        tapState.receivedSeconds()
    }

    /// One scheduled step: decode the next window when its full content has
    /// arrived.
    private func tick() {
        guard isRunning, !processing else { return }
        if !originDelivered, let origin = tapState.contentOrigin() {
            performanceOrigin = origin
            originDelivered = true
            onPerformanceStarted?(origin)
        }
        let received = tapState.receivedSeconds()
        if received < 1.0, Date().timeIntervalSince(captureStarted) > 15 {
            stop()
            lastError = "Not hearing any input, check the microphone settings"
            return
        }
        if let samples = tapState.takeWindow(index: windowIndex) {
            print("[engine] window \(self.windowIndex) submitted, \(Int(received)) s captured so far")
            submitWindow(index: windowIndex, deviceSamples: samples, deviceRate: tapState.deviceRate())
            windowIndex += 1
            skippedTicks = 0
        } else {
            skippedTicks += 1
        }
    }

    private func submitWindow(index: Int, deviceSamples: [Float], deviceRate: Double) {
        guard let inference else { return }
        processing = true
        let forcedStart: [Int]
        if index == 0 {
            forcedStart = Array(repeating: WindowGeometry.padFrames, count: WindowGeometry.symbols.count)
        } else {
            forcedStart = lastP.map { max($0 - WindowGeometry.stepFrames, 0) }
        }
        inferenceQueue.async { [weak self, inference] in
            let result = inference.run(windowIndex: index, samples: deviceSamples,
                                       deviceRate: deviceRate, forcedStartPos: forcedStart)
            Task { @MainActor [weak self] in
                self?.processing = false
                if let result {
                    self?.absorb(result)
                }
            }
        }
    }

    /// Applies one decoded window: merges each decoded interval with the
    /// last live note of its pitch (re-onset replaces, continuation
    /// extends), then reports what is new and recomputes the chord sheet.
    private func absorb(_ result: WindowResult) {
        var newCount = 0
        for event in result.events {
            var note = NoteEvent(pitch: event.pitch, velocity: event.velocity,
                                 onset: max(event.onsetSeconds, 0), duration: 0)
            note.duration = max(event.offsetSeconds, note.onset + 1e-8) - note.onset

            // noise-floor phantoms never become events: the reference
            // model fires sub-55 ms notes on quiet room tone, real staccato
            // does not get that short at the piano
            let isStrikeCandidate = event.hasOnset && note.duration >= WindowGeometry.minimumNoteDuration

            if let index = liveIndex[event.pitch], history.indices.contains(index),
               note.onset < history[index].offset {
                if isStrikeCandidate {
                    // re-onset while still sounding replaces the event
                    history[index] = note
                    newCount += 1
                    onNoteEvent?(note, .struck)
                } else if !event.hasOnset {
                    // continuation: the sounding note simply lasts longer
                    let newEnd = max(history[index].offset, note.offset)
                    history[index].duration = newEnd - history[index].onset
                    onNoteEvent?(history[index], .extended)
                }
            } else if isStrikeCandidate {
                history.append(note)
                liveIndex[event.pitch] = history.count - 1
                newCount += 1
                onNoteEvent?(note, .struck)
            }
        }
        noteCount += newCount

        notes = history
        recomputeChords()

        let covered = Double(result.windowIndex) * WindowGeometry.stepWallSeconds
            - WindowGeometry.padSeconds + WindowGeometry.segmentSeconds
        onWindowCovered?(covered)
    }

    private func recomputeChords() {
        let grouped = assignOnsetGroups(notes)
        var entries: [SheetEntry] = []
        var seen = Set<Int>()
        for note in grouped where !seen.contains(note.onsetGroup) {
            seen.insert(note.onsetGroup)
            if let chord = Chord.identify(in: grouped, group: note.onsetGroup) {
                entries.append(SheetEntry(onset: note.onset, chord: chord))
            }
        }
        sheet = entries
        currentChord = entries.last?.chord
    }

    /// seconds since performance second zero, on the wall clock
    private var performanceAge: Double {
        CACurrentMediaTime() - performanceOrigin
    }
}
