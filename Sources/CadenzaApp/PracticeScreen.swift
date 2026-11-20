import AppKit
import CadenzaCore

/// The real practice screen: the approved draft's composition, driven by the
/// transcription engine instead of the gallery's simulated clock. The
/// endless measure runs its notation across the middle of the paper - fresh
/// notes engraved at the now line, drifting left - while the keybed carries
/// whatever sounds and the panel holds the session's numbers. The transport
/// closures carry the panel's actions up to the app shell, which owns the
/// engine.
@MainActor
final class PracticeScreenView: NSView {
    private let keybed = KeybedView()
    private let staffLens: StaffLensView
    private let panel: ControlPanelLens
    /// the panel's two geometries: docked narrow at the right edge, or
    /// centered and wide with its details unfolded
    private var panelDockWidth: NSLayoutConstraint?
    private var panelDockTrailing: NSLayoutConstraint?
    private var panelCenterX: NSLayoutConstraint?
    private var panelUnfoldedWidth: NSLayoutConstraint?
    private var panelIsUnfolded = false
    private var panelMorphing = false
    private let menuLens: MenuLens
    private let wordmark = makeInkLabel(
        "Cadenza",
        font: PaperTheme.displaySerif(27, weight: .semibold),
        color: PaperTheme.ink
    )
    private let statusLabel = makeInkLabel(
        "",
        font: .systemFont(ofSize: 12, weight: .medium),
        color: PaperTheme.secondaryInk
    )

    // MARK: session state

    /// pitches sounding right now, from the engine's note events
    private var soundingPitches: Set<Int> = []
    private var noteCount = 0
    /// the whisper next to the wordmark: an error, a save, a take
    private var statusText = ""
    private var sessionStart: Date?
    private var sessionSeconds: Double = 0
    private var clockTimer: Timer?

    init(transport: PanelTransport, onSheetMusic: (() -> Void)? = nil,
         onStatistics: (() -> Void)? = nil, onSettings: (() -> Void)? = nil) {
        panel = ControlPanelLens(transport: transport)
        menuLens = MenuLens(onSheetMusic: onSheetMusic, onStatistics: onStatistics, onSettings: onSettings)
        // the measure opens the engraved sheet: same door as the menu
        staffLens = StaffLensView(onOpen: onSheetMusic ?? {})
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let paper = PaperView()
        paper.translatesAutoresizingMaskIntoConstraints = false
        addSubview(paper)
        NSLayoutConstraint.activate([
            paper.leadingAnchor.constraint(equalTo: leadingAnchor),
            paper.trailingAnchor.constraint(equalTo: trailingAnchor),
            paper.topAnchor.constraint(equalTo: topAnchor),
            paper.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        addSubview(keybed)
        addSubview(staffLens)

        wordmark.translatesAutoresizingMaskIntoConstraints = false
        addSubview(wordmark)
        let dot = StampDot()
        addSubview(dot)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        addSubview(panel)
        addSubview(menuLens)
        panel.onRequestExpand = { [weak self] in self?.showExpandedPanel(!(self?.panelIsUnfolded ?? true)) }

        NSLayoutConstraint.activate([
            keybed.leadingAnchor.constraint(equalTo: leadingAnchor),
            keybed.trailingAnchor.constraint(equalTo: trailingAnchor),
            keybed.bottomAnchor.constraint(equalTo: bottomAnchor),
            keybed.heightAnchor.constraint(equalToConstant: 118),

            staffLens.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36),
            // the measure keeps its own width, independent of the panel's
            // dock/center morph: tying it to the panel made the staff jump
            // when the panel moved
            staffLens.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -300),
            staffLens.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
            staffLens.topAnchor.constraint(equalTo: wordmark.bottomAnchor, constant: 14),
            staffLens.bottomAnchor.constraint(equalTo: keybed.topAnchor, constant: -34),

            wordmark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 38),
            wordmark.topAnchor.constraint(equalTo: topAnchor, constant: 22),

            dot.leadingAnchor.constraint(equalTo: wordmark.trailingAnchor, constant: 7),
            dot.bottomAnchor.constraint(equalTo: wordmark.bottomAnchor, constant: -6),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),

            statusLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 14),
            statusLabel.bottomAnchor.constraint(equalTo: wordmark.bottomAnchor, constant: -3),

            // the two floating lenses carry explicit sizes at required
            // priority: intrinsic consultation proved unreliable here, so
            // geometry is pinned, never guessed
            menuLens.widthAnchor.constraint(equalToConstant: 75),
            menuLens.heightAnchor.constraint(equalToConstant: 40),
            menuLens.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            menuLens.topAnchor.constraint(equalTo: topAnchor, constant: 20),

            // the panel is only as tall as its rows: the lens wraps the
            // content instead of stretching blank air around it
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        panelDockWidth = panel.widthAnchor.constraint(equalToConstant: 240)
        panelDockTrailing = panel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -30)
        panelCenterX = panel.centerXAnchor.constraint(equalTo: centerXAnchor)
        panelUnfoldedWidth = panel.widthAnchor.constraint(equalToConstant: 520)
        panelDockWidth?.isActive = true
        panelDockTrailing?.isActive = true
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: engine events

    /// A note begins sounding: light the key, engrave it at the now line.
    func noteStruck(_ event: NoteEvent) {
        soundingPitches.insert(event.pitch)
        keybed.soundingPitches = soundingPitches
        staffLens.stripView.noteStruck(pitch: event.pitch)
        refresh()
    }

    /// A note stops sounding: hand its notation back to the ink.
    func noteReleased(_ event: NoteEvent) {
        soundingPitches.remove(event.pitch)
        keybed.soundingPitches = soundingPitches
        staffLens.stripView.noteReleased(pitch: event.pitch)
        refresh()
    }

    func setSessions(_ sessions: [SessionRecord], playing: SessionRecord?) {
        panel.setSessions(sessions, playing: playing)
    }

    /// The panel itself moves: docked at the right edge when collapsed,
    /// centered and wide when unfolded. The morph is a single compositor
    /// animation on the real lens — a pure translation from the dock
    /// position plus a fade — the same thing as dragging a glass window,
    /// which the material handles cleanly. No scaling, no stretching, no
    /// subview rebuilds mid-flight: the lens is laid out in its final
    /// geometry at once (hidden), then slides/fades into place.
    func showExpandedPanel(_ show: Bool, animated: Bool = true) {
        guard show != panelIsUnfolded, !panelMorphing else { return }
        panelIsUnfolded = show
        panelMorphing = true
        panel.wantsLayer = true

        func swapGeometry() {
            panelDockWidth?.isActive = !show
            panelDockTrailing?.isActive = !show
            panelCenterX?.isActive = show
            panelUnfoldedWidth?.isActive = show
            panel.setExpanded(show)
            layoutSubtreeIfNeeded()
        }
        func setTap(_ unfold: Bool) {
            panel.onRequestExpand = { [weak self] in self?.showExpandedPanel(unfold) }
        }
        /// layer-space translation (y is up in layer coordinates) that puts
        /// the lens's final center on its dock center
        func dockDelta(from fromFrame: NSRect, to toFrame: NSRect) -> CATransform3D {
            let dx = fromFrame.midX - toFrame.midX
            let dy = fromFrame.midY - toFrame.midY
            return CATransform3DMakeTranslation(dx, -dy, 0)
        }

        if !animated {
            swapGeometry()
            panelMorphing = false
            setTap(!show)
            return
        }

        let fromFrame = panel.frame
        if show {
            swapGeometry()
            let toFrame = panel.frame
            let start = dockDelta(from: fromFrame, to: toFrame)
            panel.alphaValue = 0
            panel.layer?.transform = start
            let move = CABasicAnimation(keyPath: "transform")
            move.fromValue = NSValue(caTransform3D: start)
            move.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            move.duration = 0.34
            move.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.26
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.layer?.add(move, forKey: "move")
            panel.layer?.add(fade, forKey: "fade")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { [weak self] in
                guard let self else { return }
                panel.layer?.removeAllAnimations()
                panel.layer?.transform = CATransform3DIdentity
                panel.alphaValue = 1
                panelMorphing = false
                setTap(false)
            }
        } else {
            let toFrame = NSRect(
                x: bounds.width - 30 - fromFrame.width,
                y: (bounds.height - fromFrame.height) / 2,
                width: fromFrame.width,
                height: fromFrame.height
            )
            let target = dockDelta(from: toFrame, to: fromFrame)
            let move = CABasicAnimation(keyPath: "transform")
            move.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
            move.toValue = NSValue(caTransform3D: target)
            move.duration = 0.3
            move.timingFunction = CAMediaTimingFunction(name: .easeIn)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.3
            move.isRemovedOnCompletion = false
            fade.isRemovedOnCompletion = false
            panel.layer?.add(move, forKey: "move")
            panel.layer?.add(fade, forKey: "fade")
            panel.layer?.transform = target
            panel.alphaValue = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                panel.layer?.removeAllAnimations()
                swapGeometry()
                panel.layer?.transform = CATransform3DIdentity
                panel.alphaValue = 1
                panelMorphing = false
                setTap(true)
            }
        }
    }

    func setNoteCount(_ count: Int) {
        noteCount = count
        refresh()
    }

    /// The whisper next to the wordmark; empty means nothing to say.
    func setStatus(_ text: String, error: Bool) {
        statusText = text
        statusLabel.stringValue = text
        statusLabel.textColor = error ? PaperTheme.stamp : PaperTheme.secondaryInk
    }

    func syncTransport() {
        panel.syncTransport()
    }

    /// Whether a play-along (listening while a session plays) runs; the
    /// panel's play/pause button stays usable during one.
    func panelPlayAlong(_ running: Bool) {
        panel.playAlongRunning = running
        panel.syncTransport()
    }

    /// Listening began: the session clock runs.
    func sessionStarted() {
        sessionStart = Date()
        sessionSeconds = 0
        refresh()
        guard clockTimer == nil else { return }
        clockTimer = Clock.every(1.0) { [weak self] in self?.tickClock() }
    }

    /// Listening ended: the clock settles, nothing stays lit, the running
    /// notation becomes blank paper again.
    func sessionStopped() {
        clockTimer?.invalidate()
        clockTimer = nil
        sessionStart = nil
        soundingPitches = []
        keybed.soundingPitches = []
        staffLens.stripView.clear()
        refresh()
    }

    // MARK: session internals

    private func tickClock() {
        guard let sessionStart else { return }
        sessionSeconds = Date().timeIntervalSince(sessionStart)
        refresh()
    }

    /// The panel reads the whole session state each time any of it moves.
    private func refresh() {
        panel.setSession(
            time: sessionTimeString(sessionSeconds),
            notes: "\(noteCount) notes",
            level: levelTarget,
            sounding: !soundingPitches.isEmpty
        )
    }

    /// The level reads how much of the instrument sounds: one note as a
    /// whisper, a two-hand chord near the top.
    private var levelTarget: Double {
        min(1, Double(soundingPitches.count) / 8)
    }

    // MARK: shot diagnostics

    /// Rectangles where the practice screen's ink should reach the screen,
    /// for the gallery's live capture report.
    func inkRects() -> [(String, NSRect)] {
        paperInkRects(panel: panel, wordmark: wordmark, in: self)
    }
}
