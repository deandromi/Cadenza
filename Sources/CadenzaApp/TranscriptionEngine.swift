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

    /// Real-time streaming: windows always end at the latest received audio
    /// and slide by this much per decode. Decodes pipeline back to back, so
    /// when a decode takes longer than this step the next window simply
    /// covers all the audio that arrived meanwhile. The measured cost of a
    /// 691-frame decode is about 1.1 to 1.3 s on CPU and no faster on GPU
    /// or the Neural Engine, so on this machine the effective step is the
    /// decode time and the step only bounds it from below.
    static let streamingStep = 0.45

    /// Content required before the first streaming window decodes: the
    /// decode needs a handful of frames past an attack, and the first
    /// window may not extend beyond the audio that exists yet.
    static let streamingWarmup = 0.6

    /// The ring keeps this much history: a window reaches back segmentSeconds
    /// behind its trailing edge, and the grid pipeline needs a bit less.
    static let ringHistorySeconds = 25.0

    /// How far the next window's trailing edge moves after a decode that
    /// just finished, given it took `decodeWall` seconds: at least a step,
    /// at least a decode plus a small slack so decodes pipeline back to
    /// back, and never more than one window, or consecutive windows would
    /// stop overlapping and tear holes in the coverage. The slack past the
    /// decode time lands directly in the publication delay of fresh notes,
    /// so it stays minimal.
    static func streamingAdvance(decodeWall: Double) -> Double {
        min(max(streamingStep, decodeWall + 0.10), segmentSeconds)
    }
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

        /// True unless the interval reaches the window's last frame without
        /// the offset head confirming it (the note likely continues past the
        /// trailing edge).
        var hasOffset: Bool { endFrame < WindowGeometry.lastFrameIdx || presenceOffset }
    }

    let windowIndex: Int
    /// content seconds of the window's first frame, edge - segmentSeconds
    let beginSeconds: Double
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
        // keep what a window could still reach back to; older audio can no
        // longer be needed
        let cap = Int(WindowGeometry.ringHistorySeconds * rate)
        if ring.count > cap {
            let drop = ring.count - cap
            ring.removeFirst(drop)
            ringStart += drop
        }
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

    /// Returns the streaming window ending at `edgeSeconds` content time,
    /// spanning `segmentSeconds` behind it, or nil while the edge has not
    /// arrived. Missing leading audio (the performance is younger than the
    /// window) arrives as zeros, which is what the model's leading pad
    /// semantics expect.
    func takeStreamWindow(edgeSeconds: Double) -> [Float]? {
        let startSeconds = edgeSeconds - WindowGeometry.segmentSeconds
        let startSample = Int((startSeconds * rate).rounded())
        let endSample = Int((edgeSeconds * rate).rounded())

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
        // nothing older than this window's own start can be needed again
        if startSample > ringStart {
            let drop = min(startSample - ringStart, ring.count)
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
        configuration.computeUnits = Self.computeUnits
        model = try MLModel(contentsOf: compiled, configuration: configuration)
    }

    /// The compute-unit choice for the backbone. The CPU beats the
    /// accelerators for this model's dense per-frame convolutions on this
    /// machine, but the choice stays measurable: set
    /// CADENZA_COMPUTE_UNITS to cpuOnly, cpuAndGPU, cpuAndNe or all.
    static var computeUnits: MLComputeUnits {
        switch ProcessInfo.processInfo.environment["CADENZA_COMPUTE_UNITS"] {
        case "cpuAndGPU": return .cpuAndGPU
        case "cpuAndNE": return .cpuAndNeuralEngine
        case "all": return .all
        default: return .cpuOnly
        }
    }

    /// Decodes one window ending at `edgeSeconds` content time: resamples to
    /// exactly one segment, computes mel features, runs the backbone, walks
    /// the forced-start viterbi and refines every interval with the attribute
    /// heads. Events come back sorted by (onset, offset, pitch).
    func run(windowIndex: Int, edgeSeconds: Double, samples: [Float], deviceRate: Double, forcedStartPos: [Int]) -> WindowResult? {
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
        let frames = mel.compute(Self.alignToSegment(at44100))
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
        let score = copy(scoreArray)
        let skip = copy(skipArray)
        let context = copy(contextArray)
        let crfStart = CACurrentMediaTime()
        // every symbol's suffix DP is independent: spread them over the cores
        var intervals = [[FrameInterval]](repeating: [], count: symbolCount)
        DispatchQueue.concurrentPerform(iterations: symbolCount) { symbol in
            intervals[symbol] = SemiCRFDecoder.decodeSymbol(
                score: score, skip: skip, T: t, P: symbolCount,
                p: symbol, start: forcedStartPos[symbol])
        }
        let crfWall = CACurrentMediaTime() - crfStart

        let beginTime = edgeSeconds - WindowGeometry.segmentSeconds
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

    private let audioEngine = AVAudioEngine()
    private let inferenceQueue = DispatchQueue(label: "dev.cadenza.transcription", qos: .userInitiated)
    private var tapState = AudioTapState()
    private var inference: InferenceContext?
    private var tickTimer: Timer?
    private var levelTimer: Timer?
    private var processing = false
    /// decodes performed this session, for logging only
    private var windowIndex = 0
    /// content seconds at which the next window's trailing edge sits
    private var nextEdge = WindowGeometry.streamingWarmup
    /// wall seconds the most recent decode took, pacing the stream below
    private var lastDecodeWall = 0.0
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
    func start(tensorsDir: URL, modelURL: URL) {
        guard !isRunning else { return }
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
            nextEdge = WindowGeometry.streamingWarmup
            lastDecodeWall = 0
            merge = StreamingMerge(symbolCount: WindowGeometry.symbols.count)
            notes = []
            sheet = []
            currentChord = nil
            noteCount = 0
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
            // ticks are fast and cheap: they only submit the next window when
            // its trailing edge has arrived, so decodes pipeline back to back
            tickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
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

    /// The raw mic capture of the session that just stopped, at device rate.
    /// The app shell hands it to the session store; nil when nothing was
    /// recorded.
    private(set) var lastRecording: (samples: [Float], rate: Double)?

    func stop() {
        guard isRunning else { return }
        tickTimer?.invalidate()
        tickTimer = nil
        levelTimer?.invalidate()
        levelTimer = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isRunning = false
        lastRecording = takeRecording()
        dumpSessionRecording()
    }

    /// Drains the recorded raw audio without stopping capture.
    private func takeRecording() -> (samples: [Float], rate: Double)? {
        let raw = tapState.drainRaw()
        tapState.setRecording(false)
        guard !raw.isEmpty else { return nil }
        return (raw, tapState.deviceRate())
    }

    /// Writes the session's raw mic capture (device rate) next to the other
    /// diagnostics, so a failed session can be replayed offline.
    private func dumpSessionRecording() {
        guard let (raw, rate) = lastRecording else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let url = URL(fileURLWithPath: "/tmp/cadenza_session_\(stamp.prefix(19)).f32")
        raw.withUnsafeBufferPointer { pointer in
            let data = Data(bytes: pointer.baseAddress!, count: raw.count * 4)
            try? data.write(to: url)
        }
        print("[engine] session mic capture written to \(url.path), \(raw.count) samples at \(Int(rate)) Hz")
    }

    /// audio content captured so far this session, for diagnostics
    var capturedSeconds: Double {
        tapState.receivedSeconds()
    }

    /// One scheduled step: submit the next streaming window once its trailing
    /// edge has arrived. Decodes run back to back, so the stream paces itself
    /// at the decode rate: a step never shorter than a decode, or windows
    /// would pile up behind the decoder; when the decode outruns the step,
    /// the next window simply covers all the audio that arrived meanwhile.
    private func tick() {
        guard isRunning, !processing else { return }
        let received = tapState.receivedSeconds()
        if received < 1.0, Date().timeIntervalSince(captureStarted) > 15 {
            stop()
            lastError = "Not hearing any input, check the microphone settings"
            return
        }
        guard received >= nextEdge else { return }
        let edge = nextEdge
        print("[engine] window \(windowIndex) submitted, edge \(String(format: "%.2f", edge)) s, \(Int(received)) s captured so far")
        submitWindow(index: windowIndex, edge: edge)
        windowIndex += 1
        nextEdge = edge + WindowGeometry.streamingAdvance(decodeWall: lastDecodeWall)
    }

    private func submitWindow(index: Int, edge: Double) {
        guard let inference else { return }
        guard let deviceSamples = tapState.takeStreamWindow(edgeSeconds: edge) else {
            nextEdge = min(nextEdge, tapState.receivedSeconds())
            return
        }
        processing = true
        let forcedStart = merge.forcedStart(for: edge - WindowGeometry.segmentSeconds)
        let deviceRate = tapState.deviceRate()
        inferenceQueue.async { [weak self, inference] in
            let decodeStart = CACurrentMediaTime()
            let result = inference.run(windowIndex: index, edgeSeconds: edge, samples: deviceSamples,
                                       deviceRate: deviceRate, forcedStartPos: forcedStart)
            let decodeWall = CACurrentMediaTime() - decodeStart
            Task { @MainActor [weak self] in
                self?.processing = false
                self?.lastDecodeWall = decodeWall
                if let result {
                    self?.absorbWindow(result)
                }
            }
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
        notes = merge.notes
        noteCount = merge.notes.count
        recomputeChords()
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
}
