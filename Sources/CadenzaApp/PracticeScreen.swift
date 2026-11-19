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

    init(transport: PanelTransport, onSheetMusic: (() -> Void)? = nil, onSettings: (() -> Void)? = nil) {
        panel = ControlPanelLens(transport: transport)
        menuLens = MenuLens(onSheetMusic: onSheetMusic, onSettings: onSettings)
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
    /// centered and wide when unfolded. The glass lens is never animated —
    /// a snapshot image of it (a plain NSImageView on top, which cannot
    /// glitch) travels from the dock to the center while the real lens is
    /// laid out hidden in its final geometry, then revealed on arrival.
    func showExpandedPanel(_ show: Bool, animated: Bool = true) {
        guard show != panelIsUnfolded, !panelMorphing else { return }
        panelIsUnfolded = show
        panelMorphing = true

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
        func snapshotImage() -> NSImage? {
            let scale = window?.backingScaleFactor ?? 2
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(panel.bounds.width * scale),
                pixelsHigh: Int(panel.bounds.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            panel.cacheDisplay(in: panel.bounds, to: rep)
            let image = NSImage(size: panel.bounds.size)
            image.addRepresentation(rep)
            return image
        }

        if !animated {
            swapGeometry()
            panelMorphing = false
            setTap(!show)
            return
        }

        let fromFrame = panel.frame
        let image = snapshotImage()
        swapGeometry()
        let toFrame = panel.frame
        guard let image, toFrame != fromFrame else {
            panelMorphing = false
            setTap(!show)
            return
        }

        panel.isHidden = true
        let snapshot = NSImageView(frame: fromFrame)
        snapshot.image = image
        snapshot.wantsLayer = true
        addSubview(snapshot)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.42
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            snapshot.frame = toFrame
        }, completionHandler: { [weak self] in
            guard let self else { return }
            snapshot.removeFromSuperview()
            panel.isHidden = false
            panelMorphing = false
            setTap(!show)
        })
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

    /// Listening began: the session clock runs.
    func sessionStarted() {
        sessionStart = Date()
        sessionSeconds = 0
        refresh()
        guard clockTimer == nil else { return }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickClock() }
        }
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
