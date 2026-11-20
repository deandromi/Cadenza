import AVFoundation
import CadenzaCore
import Foundation
import QuartzCore

/// Offline check of the session piano: loads the bundled samples, renders a
/// short take through the mixer without an audio device, and reports what it
/// cost and whether it is actually in tune. Run with `--piano-probe`.
@MainActor
enum PianoProbe {
    private static let frames = 512

    static func run() {
        guard let directory = PianoSampler.samplesDirectory() else {
            print("piano-probe: no samples found")
            return
        }
        let loadBegan = CACurrentMediaTime()
        let samples = PianoMixer.loadSamples(from: directory)
        let loadMilliseconds = (CACurrentMediaTime() - loadBegan) * 1000
        let megabytes = Double(samples.reduce(0) { $0 + $1.frames.count }) * 4 / 1_000_000
        print(String(format: "piano-probe: %d samples, %.1f MB resident, loaded in %.0f ms",
                     samples.count, megabytes, loadMilliseconds))
        guard !samples.isEmpty else { return }

        let list = AudioBufferList.allocate(maximumBuffers: 2)
        for index in 0..<2 {
            list[index] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer.allocate(
                    byteCount: frames * MemoryLayout<Float>.size,
                    alignment: MemoryLayout<Float>.alignment
                )
            )
        }
        defer {
            for index in 0..<2 { list[index].mData?.deallocate() }
            free(list.unsafeMutablePointer)
        }

        tune(samples: samples, list: list)
        cost(samples: samples, list: list)
    }

    /// Plays a short arpeggio through the real engine, so the wiring that
    /// touches the audio device is exercised too and the instrument can be
    /// heard without a session: `--piano-play`.
    static func play() {
        let piano = PianoSampler()
        piano.prepare()
        for (index, pitch) in [60, 64, 67, 72].enumerated() {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(index) * 180_000_000)
                piano.noteOn(pitch: pitch, velocity: 92)
                try? await Task.sleep(nanoseconds: 900_000_000)
                piano.noteOff(pitch: pitch)
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(3.0))
        piano.silence()
    }

    /// A single C4 must come out at 261.63 Hz. Measured by autocorrelation,
    /// because a piano tone crosses zero many times per period and counting
    /// crossings reads an octave-and-a-half high on a bright sample.
    private static func tune(samples: [PianoMixer.Sample], list: UnsafeMutableAudioBufferListPointer) {
        let mixer = PianoMixer()
        mixer.install(samples)
        mixer.enqueue(PianoMixer.Event(kind: .on, pitch: 60, velocity: 100))
        var mono: [Float] = []
        mono.reserveCapacity(44_100)
        for _ in 0..<86 {   // 86 * 512 / 44100 ≈ 1 s
            mixer.render(frames: frames, into: list)
            let channel = list[0].mData!.assumingMemoryBound(to: Float.self)
            mono.append(contentsOf: UnsafeBufferPointer(start: channel, count: frames))
        }
        guard mono.count > 8192 else { return }

        // the first 8192 samples of the attack hold the pitch plainly
        let window = Array(mono[1024..<9216])
        var bestLag = 0
        var best = -Double.infinity
        let lowestLag = Int(PianoMixer.renderRate / 800)
        let highestLag = Int(PianoMixer.renderRate / 80)
        for lag in lowestLag...highestLag {
            var sum = 0.0
            for index in 0..<(window.count - lag) {
                sum += Double(window[index]) * Double(window[index + lag])
            }
            sum /= Double(window.count - lag)
            if sum > best {
                best = sum
                bestLag = lag
            }
        }
        let hertz = bestLag > 0 ? PianoMixer.renderRate / Double(bestLag) : 0
        print(String(format: "piano-probe: C4 renders at %.1f Hz (expected 261.6)", hertz))
    }

    /// A short arpeggio, timed: the number that says whether playback can ever
    /// be the reason a laptop gets warm.
    private static func cost(samples: [PianoMixer.Sample], list: UnsafeMutableAudioBufferListPointer) {
        let mixer = PianoMixer()
        mixer.install(samples)
        let pitches = [48, 52, 55, 60, 64, 67, 72, 76, 79, 84]
        var releases: [(buffer: Int, pitch: Int)] = []
        var peak: Float = 0
        var energy = 0.0
        var count = 0
        let batches = 500   // ≈ 5.8 s
        let began = CACurrentMediaTime()
        for index in 0..<batches {
            if index % 4 == 0 {
                let pitch = pitches[(index / 4) % pitches.count]
                mixer.enqueue(PianoMixer.Event(kind: .on, pitch: pitch, velocity: 88))
                releases.append((index + 12, pitch))
            }
            releases.removeAll { pending in
                guard pending.buffer <= index else { return false }
                mixer.enqueue(PianoMixer.Event(kind: .off, pitch: pending.pitch, velocity: 0))
                return true
            }
            mixer.render(frames: frames, into: list)
            for channel in 0..<2 {
                let pointer = list[channel].mData!.assumingMemoryBound(to: Float.self)
                for frame in 0..<frames {
                    let value = pointer[frame]
                    peak = max(peak, abs(value))
                    energy += Double(value) * Double(value)
                    count += 1
                }
            }
        }
        let wall = CACurrentMediaTime() - began
        let audio = Double(batches * frames) / PianoMixer.renderRate
        let rms = (energy / Double(count)).squareRoot()
        print(String(format: "piano-probe: %.2f s of audio in %.0f ms (%.2f%% of one core), peak %.3f, rms %.4f",
                     audio, wall * 1000, wall / audio * 100, peak, rms))
    }
}
