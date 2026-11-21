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
    /// Every section — the archive, the sheet, statistics, settings — opens
    /// here, on frozen glass inside this one window, never in a window of its
    /// own and never by moving the practice screen out from under the user.
    private let overlay = OverlayHost()
    /// One glass container hosts every floating control, so Apple's material
    /// can blend and react across lenses the way it is meant to: the panel
    /// and the menu are one glass surface family, not two islands.
    private let glassContainer = NSGlassEffectContainerView()
    /// asked by the panel and the menu for the session archive; the shell
    /// answers, since it owns the sessions
    private let onSessions: (() -> Void)?
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

    init(shell: PracticeShell, onSessions: (() -> Void)? = nil,
         onSheetMusic: (() -> Void)? = nil,
         onStatistics: (() -> Void)? = nil, onRefreshMIDI: (() -> Void)? = nil,
         onSettings: (() -> Void)? = nil) {
        panel = ControlPanelLens(shell: shell)
        self.onSessions = onSessions
        menuLens = MenuLens(onSessions: onSessions, onSheetMusic: onSheetMusic,
                            onStatistics: onStatistics,
                            onRefreshMIDI: onRefreshMIDI, onSettings: onSettings)
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

        glassContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glassContainer)

        addSubview(keybed)
        addSubview(staffLens)

        wordmark.translatesAutoresizingMaskIntoConstraints = false
        addSubview(wordmark)
        let dot = StampDot()
        addSubview(dot)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        glassContainer.addSubview(panel)
        glassContainer.addSubview(menuLens)
        panel.onRequestExpand = { [weak self] in self?.onSessions?() }

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
            glassContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassContainer.topAnchor.constraint(equalTo: topAnchor),
            glassContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            menuLens.widthAnchor.constraint(equalToConstant: 75),
            menuLens.heightAnchor.constraint(equalToConstant: 40),
            menuLens.trailingAnchor.constraint(equalTo: glassContainer.trailingAnchor, constant: -28),
            menuLens.topAnchor.constraint(equalTo: glassContainer.topAnchor, constant: 20),

            // the panel is only as tall as its rows: the lens wraps the
            // content instead of stretching blank air around it
            panel.centerYAnchor.constraint(equalTo: glassContainer.centerYAnchor),
            panel.trailingAnchor.constraint(equalTo: glassContainer.trailingAnchor, constant: -30),
            panel.widthAnchor.constraint(equalToConstant: 240),
        ])

        // the overlay sits above every other layer: one window, one place
        // where a section can appear
        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: engine events

    /// A note begins sounding: light the key, engrave it at the now line.
    func noteStruck(_ event: NoteEvent) {
        soundingPitches.insert(event.pitch)
        keybed.press(pitch: event.pitch, velocity: event.velocity)
        staffLens.stripView.noteStruck(pitch: event.pitch)
        refresh()
    }

    /// A note stops sounding: hand its notation back to the ink.
    func noteReleased(_ event: NoteEvent) {
        soundingPitches.remove(event.pitch)
        keybed.release(pitch: event.pitch)
        staffLens.stripView.noteReleased(pitch: event.pitch)
        refresh()
    }

    func setSessions(_ sessions: [SessionRecord], playing: SessionRecord?) {
        panel.setSessions(sessions, playing: playing)
    }

    // MARK: sections on frozen glass

    /// Shows a section in the card: the room freezes behind it, the card
    /// arrives with the app's one spring, a click outside or Escape closes it.
    func presentOverlay(_ content: NSView, size: NSSize, onDismiss: (() -> Void)? = nil) {
        overlay.present(content, size: size, onDismiss: onDismiss)
    }

    func dismissOverlay(animated: Bool = true) {
        overlay.dismiss(animated: animated)
    }

    var overlayPresented: Bool { overlay.isPresented }

    /// A section may be rebuilt in place while it is open — the archive after
    /// a rename, the sheet while notes land.
    func refreshOverlayContent(_ content: NSView) {
        overlay.replaceContent(content)
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
        keybed.releaseAll()
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
