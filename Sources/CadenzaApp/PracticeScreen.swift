import AppKit
import CadenzaCore

/// The real practice screen: the approved draft's composition, driven by the
/// transcription engine instead of the gallery's simulated clock. The keybed
/// carries whatever sounds, notes bloom into the field as chords are struck
/// and dissolve as they release, and the panel holds the session's numbers.
/// The transport closures carry the panel's actions up to the app shell,
/// which owns the engine.
@MainActor
final class PracticeScreenView: NSView {
    private let keybed = KeybedView()
    private let bloom = NoteBloomView()
    private let panel: ControlPanelLens
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
    /// pitches struck since the last flush, batched into one bloom strike
    private var pendingStrikes: [Int] = []
    private var strikeFlushTimer: Timer?
    private var strikeSerial = 0
    /// the last chord the engine heard, staying on the panel until replaced
    private var chordSymbol: String?
    private var noteCount = 0
    /// the whisper next to the wordmark: an error, a save, a take
    private var statusText = ""
    private var sessionStart: Date?
    private var sessionSeconds: Double = 0
    private var clockTimer: Timer?

    /// how long the panel waits for co-struck notes to batch into one
    /// bloom strike; the engine groups onsets at 50 ms, so 60 ms catches
    /// a full chord in one cascade
    private static let strikeBatchWindow = 0.06

    init(transport: PanelTransport, onSheetMusic: (() -> Void)? = nil) {
        panel = ControlPanelLens(transport: transport)
        menuLens = MenuLens(onSheetMusic: onSheetMusic)
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
        addSubview(bloom)

        wordmark.translatesAutoresizingMaskIntoConstraints = false
        addSubview(wordmark)
        let dot = StampDot()
        addSubview(dot)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        addSubview(panel)
        addSubview(menuLens)

        NSLayoutConstraint.activate([
            keybed.leadingAnchor.constraint(equalTo: leadingAnchor),
            keybed.trailingAnchor.constraint(equalTo: trailingAnchor),
            keybed.bottomAnchor.constraint(equalTo: bottomAnchor),
            keybed.heightAnchor.constraint(equalToConstant: 118),

            bloom.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36),
            bloom.trailingAnchor.constraint(lessThanOrEqualTo: centerXAnchor, constant: -40),
            bloom.topAnchor.constraint(equalTo: wordmark.bottomAnchor, constant: 8),
            bloom.bottomAnchor.constraint(equalTo: keybed.topAnchor, constant: -30),

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

            panel.widthAnchor.constraint(equalToConstant: 240),
            panel.heightAnchor.constraint(equalToConstant: 251),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -30),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -26),
        ])
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: engine events

    /// A note begins sounding: light the key, queue its bloom.
    func noteStruck(_ event: NoteEvent) {
        soundingPitches.insert(event.pitch)
        keybed.soundingPitches = soundingPitches
        pendingStrikes.append(event.pitch)
        if strikeFlushTimer == nil {
            strikeFlushTimer = Timer.scheduledTimer(
                withTimeInterval: Self.strikeBatchWindow,
                repeats: false
            ) { [weak self] _ in
                Task { @MainActor in self?.flushStrikes() }
            }
        }
        refresh()
    }

    /// A note stops sounding: hand its blooming notes back to the ink.
    func noteReleased(_ event: NoteEvent) {
        soundingPitches.remove(event.pitch)
        keybed.soundingPitches = soundingPitches
        bloom.release(pitch: event.pitch)
        refresh()
    }

    func setChord(_ symbol: String?) {
        chordSymbol = symbol
        refresh()
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

    /// Listening ended: the clock settles, nothing stays lit, every blooming
    /// note drifts out of the paper.
    func sessionStopped() {
        clockTimer?.invalidate()
        clockTimer = nil
        strikeFlushTimer?.invalidate()
        strikeFlushTimer = nil
        flushStrikes()
        sessionStart = nil
        soundingPitches = []
        keybed.soundingPitches = []
        bloom.releaseAll()
        refresh()
    }

    // MARK: session internals

    private func flushStrikes() {
        guard !pendingStrikes.isEmpty else { return }
        bloom.strike(pitches: pendingStrikes, serial: strikeSerial)
        strikeSerial += 1
        pendingStrikes = []
    }

    private func tickClock() {
        guard let sessionStart else { return }
        sessionSeconds = Date().timeIntervalSince(sessionStart)
        refresh()
    }

    /// The panel reads the whole session state each time any of it moves.
    private func refresh() {
        panel.setSession(
            time: sessionTimeString(sessionSeconds),
            chord: chordSymbol ?? "—",
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
