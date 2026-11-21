import AppKit
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

/// The click's own glass card on the practice screen: start or stop it and
/// set its tempo without opening Settings. The slider writes through on every
/// step, so a running click follows the hand.
@MainActor
final class MetronomePopover: NSPopover {
    private let valueLabel = makeInkLabel("", font: .systemFont(ofSize: 12, weight: .medium),
                                          color: PaperTheme.secondaryInk)
    private let toggleButton = NSButton(title: "Start", target: nil, action: nil)
    private let slider = NSSlider(value: 96, minValue: 40, maxValue: 208, target: nil, action: nil)
    private let onToggle: () -> Void
    private let onTempo: (Double) -> Void

    init(isRunning: Bool, bpm: Double, onToggle: @escaping () -> Void, onTempo: @escaping (Double) -> Void) {
        self.onToggle = onToggle
        self.onTempo = onTempo
        super.init()
        behavior = .transient

        let width: CGFloat = 240
        let controller = NSViewController()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 118))
        let backdrop = makeGlassBackdrop(cornerRadius: 16, interactive: true)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(backdrop)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        let caption = makeInkLabel("Click", font: .systemFont(ofSize: 11, weight: .medium),
                                   color: PaperTheme.secondaryInk)
        let topRow = NSStackView(views: [caption, NSView(), valueLabel])
        topRow.orientation = .horizontal
        topRow.alignment = .firstBaseline
        topRow.spacing = 8
        topRow.translatesAutoresizingMaskIntoConstraints = false

        toggleButton.title = isRunning ? "Stop" : "Start"
        toggleButton.isBordered = false
        toggleButton.font = .systemFont(ofSize: 13, weight: .medium)
        toggleButton.contentTintColor = isRunning ? PaperTheme.stamp : PaperTheme.ink
        toggleButton.target = self
        toggleButton.action = #selector(toggleTapped)

        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(tempoChanged)
        slider.doubleValue = bpm
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: width - 32).isActive = true
        valueLabel.stringValue = "\(Int(bpm.rounded())) bpm"

        stack.addArrangedSubview(topRow)
        stack.addArrangedSubview(slider)
        stack.addArrangedSubview(toggleButton)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: root.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.widthAnchor.constraint(equalToConstant: width),
            topRow.widthAnchor.constraint(equalToConstant: width - 32),
        ])
        controller.view = root
        contentViewController = controller
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func toggleTapped() {
        onToggle()
        performClose(nil)
    }

    @objc private func tempoChanged() {
        let bpm = (slider.doubleValue / 4).rounded() * 4
        slider.doubleValue = bpm
        valueLabel.stringValue = "\(Int(bpm)) bpm"
        onTempo(bpm)
    }
}
