import AVFoundation
import CadenzaCore
import Foundation

/// The mixer behind the session piano: the recorded notes, the voices
/// playing them, and the command queue that connects the main actor to the
/// audio thread.
///
/// It owns its storage in raw memory so the render block can reach it
/// without touching the Swift type system's allocation rules, and everything
/// mutable sits behind one unfair lock that the audio thread only ever tries
/// to take: a buffer that misses the lock plays its commands on the next
/// pass, at most 11 ms later, instead of ever blocking.
///
/// No allocation and no waiting happens on the audio thread: the pending
/// command list is handed over wholesale each pass, and the sample arrays
/// are only ever replaced from the main actor while the engine is parked.
final class PianoMixer: @unchecked Sendable {
    /// One recorded note: where it sits on the keyboard and its samples.
    struct Sample {
        let pitch: Int
        let frames: [Float]
    }

    /// What the main actor tells the audio thread.
    struct Event {
        enum Kind { case on, off, silence }
        var kind: Kind
        var pitch: Int
        var velocity: Int
    }

    private struct Voice {
        var active = false
        var sampleIndex = 0
        var position: Double = 0
        var rate: Double = 1
        var gain: Float = 0
        var pan: Float = 0
        var release: Float = 1
        var releasing = false
    }

    private struct Mix {
        var voices = Array(repeating: Voice(), count: 48)
        var pending: [Event] = []
        var samples: [Sample] = []
        var master: Float = 0.5
    }

    /// Sample rate the instrument renders at: the samples are 44.1 kHz, and
    /// the engine converts once to whatever the output device wants.
    static let renderRate = 44_100.0
    /// How long a key takes to fade after the note ends.
    private static let releaseSeconds = 0.14

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let mix: UnsafeMutablePointer<Mix>

    init() {
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        mix = UnsafeMutablePointer<Mix>.allocate(capacity: 1)
        mix.initialize(to: Mix())
    }

    deinit {
        mix.deinitialize(count: 1)
        mix.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    // MARK: main-actor side

    var hasSamples: Bool {
        withLock { !$0.samples.isEmpty }
    }

    /// Replaces the instrument's recorded notes. Called while nothing plays.
    func install(_ samples: [Sample]) {
        withLock { $0.samples = samples }
    }

    func enqueue(_ event: Event) {
        withLock { $0.pending.append(event) }
    }

    func silenceVoices() {
        withLock { mix in
            for index in mix.voices.indices {
                mix.voices[index].active = false
            }
        }
    }

    private func withLock<T>(_ body: (inout Mix) -> T) -> T {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return body(&mix.pointee)
    }

    /// Reads the bundled manifest and its wavs. Shared by the app and the
    /// offline probe, so both hear exactly the same instrument.
    static func loadSamples(from directory: URL) -> [Sample] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return [] }
        var loaded: [Sample] = []
        for entry in manifest.samples {
            guard let frames = readMono(directory.appendingPathComponent(entry.file)) else { continue }
            loaded.append(Sample(pitch: entry.pitch, frames: frames))
        }
        return loaded.sorted { $0.pitch < $1.pitch }
    }

    private struct Manifest: Decodable {
        struct Entry: Decodable {
            let pitch: Int
            let file: String
        }
        let samples: [Entry]
    }

    /// A 16-bit mono wav as float samples, ready for the mixer to index.
    private static func readMono(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: file.processingFormat.sampleRate,
            channels: 1,
            interleaved: false
        )
        guard let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channel = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    // MARK: the audio thread

    /// Mixes one buffer of the engine's float stereo output.
    func render(frames: Int, into list: UnsafeMutableAudioBufferListPointer) {
        guard os_unfair_lock_trylock(lock) else { return }
        defer { os_unfair_lock_unlock(lock) }

        // commands first: a note-on is heard in the buffer it arrives in
        let events = mix.pointee.pending
        mix.pointee.pending = []
        for event in events {
            switch event.kind {
            case .on: start(event.pitch, velocity: event.velocity)
            case .off: release(event.pitch)
            case .silence:
                for index in mix.pointee.voices.indices {
                    mix.pointee.voices[index].active = false
                }
            }
        }

        for buffer in list {
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
        }
        let left = list.count > 0 ? list[0].mData?.assumingMemoryBound(to: Float.self) : nil
        let right = list.count > 1 ? list[1].mData?.assumingMemoryBound(to: Float.self) : left

        var index = 0
        while index < mix.pointee.voices.count {
            if mix.pointee.voices[index].active {
                renderVoice(index, frames: frames, left: left, right: right)
            }
            index += 1
        }
        // a full chord of stretched samples can overshoot the rails: soft-limit
        // once, here, rather than in every voice
        Self.limit(left, frames: frames)
        if let right, right != left { Self.limit(right, frames: frames) }
    }

    private static func limit(_ channel: UnsafeMutablePointer<Float>?, frames: Int) {
        guard let channel else { return }
        for frame in 0..<frames {
            let value = channel[frame]
            if value > 0.97 { channel[frame] = 0.97 }
            else if value < -0.97 { channel[frame] = -0.97 }
        }
    }

    private func renderVoice(
        _ index: Int,
        frames: Int,
        left: UnsafeMutablePointer<Float>?,
        right: UnsafeMutablePointer<Float>?
    ) {
        let sampleIndex = mix.pointee.voices[index].sampleIndex
        guard mix.pointee.samples.indices.contains(sampleIndex) else {
            mix.pointee.voices[index].active = false
            return
        }
        let sample = mix.pointee.samples[sampleIndex]
        let lastIndex = sample.frames.count - 1
        guard lastIndex > 1 else {
            mix.pointee.voices[index].active = false
            return
        }
        var voice = mix.pointee.voices[index]
        let master = mix.pointee.master
        let leftGain = master * (1 - voice.pan)
        let rightGain = master * (1 + voice.pan)
        let releaseStep = Float(1.0 / (Self.releaseSeconds * Self.renderRate))

        var position = voice.position
        var release = voice.release
        var finished = false
        for frame in 0..<frames {
            let base = Int(position)
            guard base < lastIndex else { finished = true; break }
            let frac = Float(position - Double(base))
            let value = sample.frames[base] + (sample.frames[base + 1] - sample.frames[base]) * frac
            if voice.releasing {
                release -= releaseStep
                if release <= 0 {
                    release = 0
                    finished = true
                }
            }
            let amplitude = value * voice.gain * release
            if let left { left[frame] += amplitude * leftGain }
            if let right { right[frame] += amplitude * rightGain }
            if finished { break }
            position += voice.rate
        }

        voice.position = position
        voice.release = release
        if finished || position >= Double(lastIndex) {
            voice.active = false
        }
        mix.pointee.voices[index] = voice
    }

    private func start(_ pitch: Int, velocity: Int) {
        guard let sampleIndex = nearestSample(to: pitch) else { return }
        let slot = freeVoice()
        let sample = mix.pointee.samples[sampleIndex]
        let semitones = Double(pitch - sample.pitch)
        let strength = Float(velocity) / 127
        mix.pointee.voices[slot] = Voice(
            active: true,
            sampleIndex: sampleIndex,
            position: 0,
            rate: pow(2, semitones / 12),
            gain: 0.12 + 0.62 * pow(strength, 1.7),
            // the keyboard reads wide in stereo: bass left, treble right,
            // gently, so a take does not sit in one point
            pan: max(-0.28, min(0.28, (Float(pitch) - 60) / 140)),
            release: 1,
            releasing: false
        )
    }

    private func release(_ pitch: Int) {
        for index in mix.pointee.voices.indices where mix.pointee.voices[index].active {
            let voice = mix.pointee.voices[index]
            guard !voice.releasing, mix.pointee.samples.indices.contains(voice.sampleIndex) else { continue }
            let sounding = Double(mix.pointee.samples[voice.sampleIndex].pitch) + 12 * log2(voice.rate)
            if abs(sounding - Double(pitch)) < 0.5 {
                mix.pointee.voices[index].releasing = true
            }
        }
    }

    /// The closest recorded note: any pitch within six semitones gets the
    /// full body of a real string rather than a stretched compromise.
    private func nearestSample(to pitch: Int) -> Int? {
        let samples = mix.pointee.samples
        guard !samples.isEmpty else { return nil }
        var best = 0
        var distance = Int.max
        for (index, sample) in samples.enumerated() {
            let d = abs(sample.pitch - pitch)
            if d < distance { distance = d; best = index }
        }
        return best
    }

    /// A free voice, else the first released one, else the oldest.
    private func freeVoice() -> Int {
        if let free = mix.pointee.voices.firstIndex(where: { !$0.active }) { return free }
        if let released = mix.pointee.voices.firstIndex(where: { $0.releasing }) { return released }
        return 0
    }
}

/// The session piano: a small sampled grand that plays recorded sessions
/// inside Cadenza, so a take does not have to be handed to whatever synth
/// the system happens to own.
///
/// Eight notes of a Schulze Pollmann grand (CC0, see Resources/Piano) cover
/// A0-C8, each stretched at most six semitones, mixed by `PianoMixer`
/// through one `AVAudioSourceNode`: no plugin, no soundfont runtime, 2.4 MB
/// of samples on disk and about 6 MB in RAM. Nothing runs until a session is
/// played back, and the engine parks itself again when playback stops.
@MainActor
final class PianoSampler {
    private let engine = AVAudioEngine()
    private let mixer = PianoMixer()
    private var source: AVAudioSourceNode?
    private var running = false
    private var samplesLoaded = false

    // MARK: public surface

    /// Loads the samples and starts the engine. Idempotent, and cheap after
    /// the first call: a session's Play button calls this every time.
    func prepare() {
        if !samplesLoaded {
            guard let directory = Self.samplesDirectory() else { return }
            loadSamples(from: directory)
            samplesLoaded = mixer.hasSamples
        }
        guard samplesLoaded, !running else { return }
        startEngine()
    }

    /// A note from a recorded take sounds.
    func noteOn(pitch: Int, velocity: Int) {
        prepare()
        mixer.enqueue(PianoMixer.Event(
            kind: .on,
            pitch: max(0, min(127, pitch)),
            velocity: max(1, min(127, velocity))
        ))
    }

    /// The key lifts: the voice releases over a short fade.
    func noteOff(pitch: Int) {
        mixer.enqueue(PianoMixer.Event(kind: .off, pitch: max(0, min(127, pitch)), velocity: 0))
    }

    /// Every voice lets go: pause, stop, panic.
    func silence() {
        mixer.enqueue(PianoMixer.Event(kind: .silence, pitch: 0, velocity: 0))
    }

    /// Playback ended: the voices ring out their release, then the engine
    /// parks so an idle app costs nothing.
    func park() {
        guard running else { return }
        silence()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !self.running else { return }
            self.engine.pause()
            self.mixer.silenceVoices()
        }
    }

    // MARK: loading

    /// The bundle's samples, or the repository's during `swift run`. One
    /// place knows the layout, so the offline probe finds the same wavs.
    static func samplesDirectory() -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("Piano", isDirectory: true))
        }
        if let executable = Bundle.main.executableURL {
            var dir = executable.deletingLastPathComponent()
            for _ in 0..<6 {
                candidates.append(dir.appendingPathComponent("Resources/Piano", isDirectory: true))
                dir = dir.deletingLastPathComponent()
            }
        }
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for _ in 0..<6 {
            candidates.append(dir.appendingPathComponent("Resources/Piano", isDirectory: true))
            dir = dir.deletingLastPathComponent()
        }
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path)
        }
    }

    private func loadSamples(from directory: URL) {
        let samples = PianoMixer.loadSamples(from: directory)
        mixer.install(samples)
        let megabytes = samples.reduce(0) { $0 + $1.frames.count } * 4 / 1_000_000
        print("[piano] loaded \(samples.count) samples, \(megabytes) MB resident")
    }

    // MARK: engine

    private func startEngine() {
        if source == nil {
            guard let format = AVAudioFormat(
                standardFormatWithSampleRate: PianoMixer.renderRate,
                channels: 2
            ) else { return }
            let mixer = self.mixer
            // @Sendable: without it this literal would inherit the enclosing
            // main-actor isolation and trap the moment CoreAudio renders from
            // its own thread
            let node = AVAudioSourceNode(format: format) { @Sendable isSilence, _, frameCount, audioBufferList in
                isSilence.pointee = false
                mixer.render(
                    frames: Int(frameCount),
                    into: UnsafeMutableAudioBufferListPointer(audioBufferList)
                )
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            source = node
        }
        engine.prepare()
        do {
            try engine.start()
            running = true
        } catch {
            print("[piano] engine start failed: \(error.localizedDescription)")
        }
    }
}
