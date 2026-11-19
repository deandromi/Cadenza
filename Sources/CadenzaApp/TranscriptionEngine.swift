import AVFoundation
import CadenzaCore
import Combine
import CoreAudio
import CoreML
import Foundation

/// Window constants shared by every tier, mirroring transkun's transcribe()
/// and readable from any isolation domain (the tap, the inference queue, main).
enum WindowGeometry {
    static let sampleRate: Double = 44100.0
    static let hopSize = 1024
    static let symbols: [Int] = [-64, -67] + Array(21...108)

    /// Notes shorter than this are dropped at merge time: on room-tone
    /// recordings the reference model fires phantoms of 47 to 52 ms in the
    /// low register, and they poison chords and MIDI output. Real staccato
    /// notes ring longer.
    static let minimumNoteDuration = 0.055
}

/// The window geometry of one transcription tier. The CoreML backbone is
/// exported per tier at a fixed input length (the position embeddings are
/// baked into the graph), so each tier carries its own geometry:
///
/// - standard: the reference 16 s window, half-stepped, highest context.
/// - fast: a 4 s window on the short-exported backbone; a decode costs
///   about a quarter of the standard one (measured 0.15 s versus 0.63 s
///   for the model call), which is what buys sub-second latency.
struct WindowPlan: Sendable, Equatable {
    let segmentSeconds: Double
    let padSeconds: Double
    let streamingStep: Double
    let streamingWarmup: Double
    let ringHistorySeconds: Double

    /// samples in one full segment at the model's 44100 Hz
    var segmentSamples: Int { Int((segmentSeconds * WindowGeometry.sampleRate).rounded()) }
    /// one grid step covers half a segment (transkun's stride)
    var stepSamples: Int { segmentSamples / 2 }
    var stepFrames: Int { stepSamples / WindowGeometry.hopSize }
    /// leading pad frames for the grid pipeline
    var padFrames: Int { Int((padSeconds * WindowGeometry.sampleRate) / Double(WindowGeometry.hopSize)) }
    /// mel frames one window decodes to: ceil(N / hop) + 1
    var frames: Int { (segmentSamples + WindowGeometry.hopSize - 1) / WindowGeometry.hopSize + 1 }
    /// a decoded interval reaching this frame is cut off by the window edge
    var lastFrameIdx: Int { frames - 2 }
    var frameDuration: Double { Double(WindowGeometry.hopSize) / WindowGeometry.sampleRate }
    var stepWallSeconds: Double { Double(stepSamples) / WindowGeometry.sampleRate }

    func streamingAdvance(decodeWall: Double) -> Double {
        min(max(streamingStep, decodeWall + 0.10), segmentSeconds)
    }

    /// The reference tier: matches the published transcribe() numbers.
    static let standard = WindowPlan(
        segmentSeconds: 16.0,
        padSeconds: 8.0,
        streamingStep: 0.45,
        streamingWarmup: 0.6,
        ringHistorySeconds: 25.0
    )

}

/// The session's tier: the standard 16 s backbone. A short-window tier
/// was prototyped and measured (174/260/346-frame exports all suppress
/// onsets — the backbone is trained on 16 s crops and shows it), so the
/// shipped tier stays on the full window; the latency lever that DOES
/// work is pipelining two decoders, which the engine does. WindowPlan
/// stays parameterized for the day a short-context fine-tune lands.
enum WindowTier {
    static let standard = WindowPlan.standard
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
        /// True unless the interval merely continues from the window start
        /// (a note sounding before this window began, no onset observed).
        let hasOnset: Bool
        /// True unless the interval reaches the window's last frame without
        /// the offset head confirming it (the note likely continues past the
        /// trailing edge).
        let hasOffset: Bool
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
    /// the tier's geometry: window spans and the ring's history budget
    private var plan: WindowPlan = .standard
    /// rms of the most recent tap buffer, read by the level timer on main
    private var latestLevel: Float = 0
    /// full-session mirror of the tap, for offline diagnostics; untouched
    /// by gain and tuning so the .wav is the microphone as it heard it
    private var rawAll: [Float] = []
    private var recordingRaw = false
    /// stretch applied at append: a4/440, slowing content so a piano tuned
    /// sharp of A=440 still lands on a 440-referenced model
    private var pitchRatio: Double = 1.0
    /// the user's input gain, folded into the model path at append
    private var gainValue: Float = 1.0
    /// fractional raw-sample read head for the streaming pitch correction
    private var readPos: Double = 0
    /// the raw sample just before the current chunk, for interpolation
    private var carry: Float = 0
    /// total raw samples the correction has seen, so the read head can
    /// address the global raw stream rather than one chunk
    private var rawConsumed = 0

    func reset(rate: Double, plan: WindowPlan = .standard, tuningA4: Double = 440, gain: Float = 1.0) {
        lock.lock()
        defer { lock.unlock() }
        ring = []
        ringStart = 0
        // correcting a4 to 440 stretches the stream; content therefore
        // ticks at deviceRate / stretch
        pitchRatio = tuningA4 > 0 ? tuningA4 / 440.0 : 1.0
        gainValue = gain
        self.rate = rate / pitchRatio
        self.plan = plan
        rawAll = []
        readPos = 0
        carry = 0
        rawConsumed = 0
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
        // model path: the user's gain, and the tuning stretch that walks a
        // stream tuned to a4 back onto 440; raw stays untouched for the wav
        var modelPath = samples
        if pitchRatio != 1.0 || gainValue != 1.0 {
            let chunkStart = rawConsumed
            let count = samples.count
            let outCount = Int((Double(count) * pitchRatio).rounded(.down))
            var out = [Float]()
            out.reserveCapacity(outCount + 1)
            for n in 0..<max(outCount, 1) {
                // out[n] reads raw global position readPos + n / ratio,
                // which inside this chunk is readPos - chunkStart ahead
                let g = readPos + Double(n) / pitchRatio
                let i = Int(g.rounded(.down))
                let frac = g - Double(i)
                let a = read(chunk: samples, chunkStart: chunkStart, index: i)
                let b = read(chunk: samples, chunkStart: chunkStart, index: i + 1)
                out.append((a + (b - a) * Float(frac)) * gainValue)
            }
            readPos += Double(max(outCount, 1)) / pitchRatio
            carry = samples.last ?? 0
            modelPath = out
        }
        rawConsumed += samples.count
        ring.append(contentsOf: modelPath)
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
        let cap = Int(plan.ringHistorySeconds * rate)
        if ring.count > cap {
            let drop = ring.count - cap
            ring.removeFirst(drop)
            ringStart += drop
        }
    }

    /// Raw sample at global stream index `index` when the current chunk
    /// starts at `chunkStart`: before the chunk the carry speaks, inside it
    /// the buffer (clamped at its end).
    private func read(chunk: [Float], chunkStart: Int, index: Int) -> Float {
        let local = index - chunkStart
        if local < 0 { return carry }
        return chunk[min(local, chunk.count - 1)]
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
        lock.lock()
        let plan = self.plan
        let rate = self.rate
        lock.unlock()
        let stepSeconds = plan.stepWallSeconds
        let startSeconds = Double(index) * stepSeconds - plan.padSeconds
        let endSeconds = startSeconds + plan.segmentSeconds
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
        let nextStartSample = Int(((Double(index + 1) * stepSeconds - plan.padSeconds) * rate).rounded())
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
        lock.lock()
        let plan = self.plan
        lock.unlock()
        let startSeconds = edgeSeconds - plan.segmentSeconds
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
    /// decodes performed this session, for logging only
    private var windowIndex = 0
    /// content seconds at which the next window's trailing edge sits
    private var nextEdge = WindowPlan.standard.streamingWarmup
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
                tuningA4: SettingsKeys.tuningA4, gain: SettingsKeys.inputGain)
            windowIndex = 0
            nextEdge = plan.streamingWarmup
            lastDecodeWall = 0
            pendingWindows = [:]
            nextWindowToAbsorb = 0
            merge = StreamingMerge(symbolCount: WindowGeometry.symbols.count, plan: plan)
            notes = []
            sheet = []
            currentChord = nil
            noteCount = 0
            tapState.setRecording(true)
            input.removeTap(onBus: 0)
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

    /// One scheduled step: submit every window whose trailing edge has
    /// arrived while a decoder is free. With two decoders alternating, a
    /// window starts every `streamingStep` even though a decode takes about
    /// twice that; the results absorb in window order as they land.
    private func tick() {
        guard isRunning else { return }
        let received = tapState.receivedSeconds()
        if received < 1.0, Date().timeIntervalSince(captureStarted) > 15 {
            stop()
            lastError = "Not hearing any input, check the microphone settings"
            return
        }
        var guardCount = 0
        while received >= nextEdge, let slot = decoderBusy.firstIndex(of: false) {
            let edge = nextEdge
            print("[engine] window \(windowIndex) submitted on decoder \(slot), edge \(String(format: "%.2f", edge)) s, \(Int(received)) s captured so far")
            decoderBusy[slot] = true
            submitWindow(index: windowIndex, edge: edge, slot: slot)
            windowIndex += 1
            nextEdge = edge + plan.streamingStep
            guardCount += 1
            if guardCount > 64 { break }
        }
    }

    /// Builds the pipelined decoders: two independent CoreML contexts so
    /// two windows decode at once. The compiles run in parallel.
    private static func buildDecoders(tensorsDir: URL, modelURL: URL) throws -> [InferenceContext] {
        var slots: [Result<InferenceContext, Error>?] = [nil, nil]
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            slots[index] = Result { try InferenceContext(tensorsDir: tensorsDir, modelURL: modelURL) }
        }
        let built = slots.compactMap { try? $0?.get() }
        guard built.count == 2 else {
            throw EngineError.modelLoadFailed
        }
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
