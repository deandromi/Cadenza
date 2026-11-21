import AVFoundation
import Foundation

/// The practice click: one bar of clicks as a single sample-accurate loop,
/// with the downbeat accented. It runs on its own small engine so it can
/// click over a session, over playback, or on its own before you start.
///
/// The pattern is synthesised, not sampled: a short sine with a fast decay
/// reads as a woodblock click and costs one small buffer of memory. Nothing
/// runs until the metronome is switched on, and stopping parks the engine.
@MainActor
final class Metronome {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var pattern: AVAudioPCMBuffer?
    private var patternKey: String = ""
    private var running = false

    /// What the click follows: tempo in beats per minute and the top of the
    /// meter (4 for 4/4, 6 for 6/8). Read from settings at every start.
    var bpm: Double = 96
    var beatsPerBar: Int = 4

    private static let rate = 44_100.0

    var isRunning: Bool { running }

    /// Starts the click, or retunes it when it already runs with another
    /// tempo or meter. A count-in needs nothing special here: the click
    /// sounds the same, the caller waits one bar before it starts a session.
    func start() {
        let key = "\(Int(bpm.rounded()))-\(beatsPerBar)"
        if running, key == patternKey { return }
        if running { stop() }
        guard buildPattern(key: key) else { return }
        if player.engine == nil {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: pattern?.format)
        }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            print("[metronome] engine start failed: \(error.localizedDescription)")
            return
        }
        guard let pattern else { return }
        player.stop()
        player.scheduleBuffer(pattern, at: nil, options: .loops)
        player.play()
        running = true
        patternKey = key
    }

    func stop() {
        guard running else { return }
        player.stop()
        engine.pause()
        running = false
    }

    func toggle() {
        running ? stop() : start()
    }

    /// Seconds one bar of the current tempo lasts: what a count-in waits.
    var barSeconds: Double { Double(beatsPerBar) * 60.0 / max(30, bpm) }

    // MARK: synthesis

    private func buildPattern(key: String) -> Bool {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1) else {
            return false
        }
        let beatFrames = max(1, Int((60.0 / max(30, bpm)) * Self.rate))
        let bars = max(1, beatsPerBar)
        let total = beatFrames * bars
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(total)) else { return false }
        buffer.frameLength = AVAudioFrameCount(total)
        guard let data = buffer.floatChannelData?[0] else { return false }
        for frame in 0..<total { data[frame] = 0 }
        for beat in 0..<bars {
            let accent = beat == 0
            let start = beat * beatFrames
            let length = min(beatFrames, Int(0.06 * Self.rate))
            let hertz = accent ? 1_760.0 : 1_320.0
            let amplitude = accent ? 0.34 : 0.2
            for offset in 0..<length {
                let t = Double(offset) / Self.rate
                // an attack of 1 ms and a decay of 45 ms: a click, not a tone
                let attack = min(1.0, t / 0.001)
                let decay = exp(-t / 0.045)
                let value = sin(2 * .pi * hertz * t) * attack * decay * amplitude
                data[start + offset] += Float(value)
            }
        }
        pattern = buffer
        return true
    }
}
