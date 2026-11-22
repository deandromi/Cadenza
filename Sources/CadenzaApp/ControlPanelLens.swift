import AppKit
import CadenzaCore

/// The docked control panel: the running clock, the numbers, the breathing
/// level line, the transport and the two doors — one to the session archive,
/// one to export. It hugs its content: no blank air is ever reserved for rows
/// that are not there, and the archive itself lives in the sessions overlay
/// where there is room for every session instead of the first four.
final class ControlPanelLens: NSView {
    private let shell: PracticeShell
    private let rows = NSStackView()
    /// the stopwatch reads big and steady: it is the panel's heartbeat
    private let timeLabel = makeInkLabel(
        "0:00",
        font: .monospacedDigitSystemFont(ofSize: 46, weight: .regular),
        color: PaperTheme.ink
    )
    private let countLabel = makeInkLabel(
        "0 notes",
        font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular),
        color: PaperTheme.secondaryInk
    )
    private let levelLine = LevelLineView()
    private let sessionsButton = NSButton(title: "Sessions", target: nil, action: nil)
    private let listenButton = NSButton(title: "New session", target: nil, action: nil)
    private let exportButton = NSButton(title: "Export", target: nil, action: nil)
    /// the transport under the timer: play/pause the session in hand, stop it
    private let playPauseButton = NSButton(title: "Play", target: nil, action: nil)
    private let stopPlaybackButton = NSButton(title: "Stop", target: nil, action: nil)
    /// the practice click, on its own line: a click that runs while you play
    private let metronomeButton = NSButton(title: "Metronome", target: nil, action: nil)
    /// retroactive capture: keep what the last minute held, after the fact
    private let keepButton = NSButton(title: "Keep last minute", target: nil, action: nil)
    /// the loop row, visible while a session plays: marks, toggle, rate
    private let loopAButton = NSButton(title: "Set A", target: nil, action: nil)
    private let loopBButton = NSButton(title: "Set B", target: nil, action: nil)
    private let loopToggleButton = NSButton(title: "Loop", target: nil, action: nil)
    private let ratePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// the time machine: drag through the take, the keys follow
    private let scrubSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private var loopRow: NSStackView?
    private var metronomePopover: NSPopover?
    private var latestSessions: [SessionRecord] = []
    /// A tap on the panel's glass asks the shell for the session archive;
    /// buttons keep their own clicks as named shortcuts.
    var onRequestExpand: (() -> Void)?
    private let backdrop = NSGlassEffectView()

    init(shell: PracticeShell) {
        self.shell = shell
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // views and their relationships are built only after super.init on
        // this OS build: mutation before it orphans subtrees from the live
        // layout engine
        for button in [listenButton, exportButton, sessionsButton, playPauseButton, stopPlaybackButton, metronomeButton, keepButton, loopAButton, loopBButton, loopToggleButton] {
            button.isBordered = false
            button.font = .systemFont(ofSize: loopAButton == button ? 11 : 13, weight: .medium)
            button.contentTintColor = PaperTheme.ink
        }
        sessionsButton.font = .systemFont(ofSize: 12, weight: .medium)
        sessionsButton.contentTintColor = PaperTheme.secondaryInk
        ratePopup.addItems(withTitles: ["100%", "75%", "50%"])
        ratePopup.font = .systemFont(ofSize: 11, weight: .medium)
        ratePopup.contentTintColor = PaperTheme.ink
        ratePopup.target = self
        ratePopup.action = #selector(rateChanged)

        // on this OS build, pinning a view never auto-disables its
        // autoresizing mask: do it by hand or the view stays at zero
        rows.translatesAutoresizingMaskIntoConstraints = false
        backdrop.translatesAutoresizingMaskIntoConstraints = false

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 12
        rows.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        rows.setContentHuggingPriority(.required, for: .vertical)
        let divider = HairlineView()
        let buttons = NSStackView(views: [listenButton, exportButton])
        buttons.orientation = .horizontal
        buttons.spacing = 20
        buttons.alignment = .firstBaseline
        let playbackButtons = NSStackView(views: [playPauseButton, stopPlaybackButton])
        playbackButtons.orientation = .horizontal
        playbackButtons.spacing = 20
        playbackButtons.alignment = .firstBaseline
        let loopRow = NSStackView(views: [scrubSlider, loopAButton, loopBButton, loopToggleButton, ratePopup])
        loopRow.orientation = .horizontal
        loopRow.spacing = 10
        loopRow.alignment = .firstBaseline
        loopRow.isHidden = true
        self.loopRow = loopRow
        scrubSlider.isContinuous = true
        scrubSlider.controlSize = .small
        scrubSlider.target = self
        scrubSlider.action = #selector(scrubChanged)
        scrubSlider.translatesAutoresizingMaskIntoConstraints = false
        scrubSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        // the lens carries the rows: the content sits inside the material,
        // in the view AppKit guarantees is within the glass
        backdrop.style = .regular
        backdrop.cornerRadius = LensRadius.panel
        setGlassInteractive(backdrop, true)
        backdrop.contentView = rows
        addSubview(backdrop)
        rows.addArrangedSubview(Self.captionedRow("Session", timeLabel))
        rows.addArrangedSubview(playbackButtons)
        rows.addArrangedSubview(metronomeButton)
        rows.addArrangedSubview(keepButton)
        rows.addArrangedSubview(loopRow)
        rows.addArrangedSubview(Self.captionedRow("Notes", countLabel))
        rows.addArrangedSubview(Self.captionedRow("Level", levelLine))
        rows.addArrangedSubview(divider)
        rows.addArrangedSubview(sessionsButton)
        rows.addArrangedSubview(buttons)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            levelLine.widthAnchor.constraint(equalToConstant: 192),
            divider.widthAnchor.constraint(equalToConstant: 192),
        ])

        listenButton.target = self
        listenButton.action = #selector(listenTapped)
        exportButton.target = self
        exportButton.action = #selector(exportTapped)
        sessionsButton.target = self
        sessionsButton.action = #selector(sessionsTapped)
        playPauseButton.target = self
        playPauseButton.action = #selector(playPauseTapped)
        stopPlaybackButton.target = self
        stopPlaybackButton.action = #selector(stopPlaybackTapped)
        metronomeButton.target = self
        metronomeButton.action = #selector(metronomeTapped)
        keepButton.target = self
        keepButton.action = #selector(keepTapped)
        loopAButton.target = self
        loopAButton.action = #selector(loopATapped)
        loopBButton.target = self
        loopBButton.action = #selector(loopBTapped)
        loopToggleButton.target = self
        loopToggleButton.action = #selector(loopToggleTapped)
        syncTransport()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Caption over value, the panel's rhythm. Rows never stretch: their
    /// vertical hugging is required, so spare panel height can only pool
    /// as still air between sections, never inside a row.
    private static func captionedRow(_ caption: String, _ value: NSView) -> NSStackView {
        let label = makeInkLabel(
            caption,
            font: .systemFont(ofSize: 11, weight: .medium),
            color: PaperTheme.secondaryInk
        )
        let stack = NSStackView(views: [label, value])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.setContentHuggingPriority(.required, for: .vertical)
        stack.setClippingResistancePriority(.required, for: .vertical)
        return stack
    }

    /// The panel lives by its content: the rows are a direct subview, so
    /// their fitting size is the panel's intrinsic size.
    override var intrinsicContentSize: NSSize {
        rows.fittingSize
    }

    /// Rereads the transport after the owner's state changed out from
    /// under the button: the session's title is Stop while it runs, and
    /// the stamp tint carries that running state.
    func syncTransport() {
        let listening = shell.isListening
        let playing = shell.playingSession != nil
        // the lens carries the session's state: it warms toward the stamp
        // while a take runs or a session plays, and is plain glass at rest.
        // Tint is state here, never decoration.
        backdrop.tintColor = (listening || playing)
            ? PaperTheme.stamp.withAlphaComponent(0.16)
            : nil
        listenButton.title = listening ? "Stop" : "New session"
        listenButton.contentTintColor = listening ? PaperTheme.stamp : PaperTheme.ink
        exportButton.isEnabled = shell.exportEnabled
        let paused = shell.playbackPaused
        playPauseButton.title = playing ? (paused ? "Resume" : "Pause") : "Play"
        playPauseButton.isEnabled = listening ? playAlongRunning : (playing || !latestSessions.isEmpty)
        playPauseButton.contentTintColor = playing ? PaperTheme.stamp : PaperTheme.ink
        stopPlaybackButton.isEnabled = playing
        let clicking = shell.metronomeActive
        metronomeButton.title = "Metronome · \(Int(shell.metronomeTempo.rounded()))"
        metronomeButton.contentTintColor = clicking ? PaperTheme.stamp : PaperTheme.ink
        keepButton.isHidden = !shell.keepMinuteEnabled
        keepButton.isEnabled = shell.canKeepLastMinute
        loopRow?.isHidden = !playing
        loopToggleButton.contentTintColor = shell.loopActive ? PaperTheme.stamp : PaperTheme.ink
        sessionsButton.title = latestSessions.isEmpty
            ? "Sessions"
            : "Sessions · \(latestSessions.count)"
    }

    /// true while a play-along (listening while a session plays) runs; the
    /// play/pause button serves it too.
    var playAlongRunning = false

    func setSession(time: String, notes: String, level: Double, sounding: Bool) {
        timeLabel.stringValue = time
        countLabel.stringValue = notes
        levelLine.setFractionTarget(level)
        levelLine.sounding = sounding
        // the scrub hand follows playback, but never fights the user's own
        // drag: while the mouse is down the slider belongs to the pointer
        if NSEvent.pressedMouseButtons == 0, !scrubSlider.isHidden {
            scrubSlider.doubleValue = shell.playbackProgress
        }
    }

    /// The archive changed elsewhere: the door shows how many sessions it
    /// leads to, and the transport knows whether there is anything to play.
    func setSessions(_ sessions: [SessionRecord], playing: SessionRecord?) {
        latestSessions = sessions
        syncTransport()
    }

    override func mouseDown(with event: NSEvent) {
        onRequestExpand?()
    }

    @objc private func sessionsTapped() {
        onRequestExpand?()
    }

    // MARK: loop and rate

    @objc private func scrubChanged() {
        shell.scrubPlayback(scrubSlider.doubleValue)
    }

    @objc private func loopATapped() {
        shell.setLoopPoint(isA: true)
        loopAButton.contentTintColor = PaperTheme.stamp
    }

    @objc private func loopBTapped() {
        shell.setLoopPoint(isA: false)
        loopBButton.contentTintColor = PaperTheme.stamp
    }

    @objc private func loopToggleTapped() {
        shell.toggleLoop()
        loopToggleButton.contentTintColor = shell.loopActive ? PaperTheme.stamp : PaperTheme.ink
    }

    @objc private func rateChanged() {
        let title = ratePopup.titleOfSelectedItem ?? "100%"
        shell.setPlaybackRate((Double(title.dropLast()) ?? 100) / 100.0)
    }

    /// Play starts the newest session when nothing is playing; while one
    /// plays, the same button pauses and resumes it.
    @objc private func playPauseTapped() {
        if shell.playingSession != nil {
            shell.togglePlayPause()
        } else if let newest = latestSessions.first {
            shell.playSession(newest)
        }
        syncTransport()
    }

    @objc private func keepTapped() {
        shell.keepLastMinute()
        syncTransport()
    }

    /// The click's card: start or stop it and set its tempo from here, so the
    /// home screen owns the click instead of sending the player to Settings.
    @objc private func metronomeTapped() {
        let popover = MetronomePopover(
            isRunning: shell.metronomeActive,
            bpm: shell.metronomeTempo,
            onToggle: { [weak self] in
                self?.shell.toggleMetronome()
                self?.syncTransport()
            },
            onTempo: { [weak self] bpm in
                self?.shell.setMetronomeTempo(bpm)
                self?.syncTransport()
            })
        metronomePopover = popover
        popover.show(relativeTo: metronomeButton.bounds, of: metronomeButton, preferredEdge: .minY)
    }

    @objc private func stopPlaybackTapped() {
        shell.stopPlayback()
        syncTransport()
    }

    func reportLayout(prefix: String) {
        print("\(prefix)panel rows frame \(rows.frame)")
        for case let row as NSStackView in rows.arrangedSubviews {
            print("\(prefix)panel row \(row.frame)")
        }
        print("\(prefix)panel time label \(timeLabel.frame)")
    }

    /// Frames of everything that carries ink, in lens coordinates: the shot
    /// diagnostics scan these for the darkest rendered pixel, which proves
    /// text reaches the screen instead of measuring paper again.
    func contentRects() -> [(String, NSRect)] {
        // label and button frames belong to their own superviews: convert
        // them into lens coordinates before handing them out
        func inLens(_ view: NSView) -> NSRect {
            convert(view.bounds, from: view)
        }
        return [
            ("panel time", inLens(timeLabel)),
            ("panel count", inLens(countLabel)),
            ("play pause button", inLens(playPauseButton)),
            ("stop playback button", inLens(stopPlaybackButton)),
            ("metronome button", inLens(metronomeButton)),
            ("scrub slider", inLens(scrubSlider)),
            ("keep last minute button", inLens(keepButton)),
            ("listen button", inLens(listenButton)),
            ("export button", inLens(exportButton)),
        ]
    }

    @objc private func listenTapped() {
        shell.toggleListening()
        syncTransport()
    }

    @objc private func exportTapped() {
        shell.export()
    }
}
