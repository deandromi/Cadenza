import AppKit
import CadenzaCore

/// The docked control panel: the running clock, the numbers, the breathing
/// level line, the transport and the two doors — one to the session archive,
/// one to export. It hugs its content: no blank air is ever reserved for rows
/// that are not there, and the archive itself lives in the sessions overlay
/// where there is room for every session instead of the first four.
final class ControlPanelLens: NSView {
    private let transport: PanelTransport
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
    private var latestSessions: [SessionRecord] = []
    /// A tap on the panel's paper asks the shell for the session archive;
    /// buttons keep their own clicks as named shortcuts.
    var onRequestExpand: (() -> Void)?
    private let backdrop: NSGlassEffectView

    init(transport: PanelTransport) {
        self.transport = transport
        backdrop = makeGlassBackdrop(cornerRadius: 18, interactive: true)

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
        addSubview(backdrop)
        addSubview(rows)
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
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.topAnchor.constraint(equalTo: topAnchor),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor),
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
        let listening = transport.isListening()
        listenButton.title = listening ? "Stop" : "New session"
        listenButton.contentTintColor = listening ? PaperTheme.stamp : PaperTheme.ink
        exportButton.isEnabled = transport.exportEnabled()
        let playing = transport.playingSession() != nil
        let paused = transport.playbackPaused()
        playPauseButton.title = playing ? (paused ? "Resume" : "Pause") : "Play"
        playPauseButton.isEnabled = listening ? playAlongRunning : (playing || !latestSessions.isEmpty)
        playPauseButton.contentTintColor = playing ? PaperTheme.stamp : PaperTheme.ink
        stopPlaybackButton.isEnabled = playing
        let clicking = transport.metronomeActive()
        metronomeButton.title = "Metronome · \(Int(transport.metronomeTempo().rounded()))"
        metronomeButton.contentTintColor = clicking ? PaperTheme.stamp : PaperTheme.ink
        keepButton.isEnabled = transport.canKeepLastMinute()
        loopRow?.isHidden = !playing
        loopToggleButton.contentTintColor = transport.loopActive() ? PaperTheme.stamp : PaperTheme.ink
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
            scrubSlider.doubleValue = transport.playbackProgress()
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
        transport.scrubPlayback(scrubSlider.doubleValue)
    }

    @objc private func loopATapped() {
        transport.setLoopPoint(true)
        loopAButton.contentTintColor = PaperTheme.stamp
    }

    @objc private func loopBTapped() {
        transport.setLoopPoint(false)
        loopBButton.contentTintColor = PaperTheme.stamp
    }

    @objc private func loopToggleTapped() {
        transport.toggleLoop()
        loopToggleButton.contentTintColor = transport.loopActive() ? PaperTheme.stamp : PaperTheme.ink
    }

    @objc private func rateChanged() {
        let title = ratePopup.titleOfSelectedItem ?? "100%"
        transport.setPlaybackRate((Double(title.dropLast()) ?? 100) / 100.0)
    }

    /// Play starts the newest session when nothing is playing; while one
    /// plays, the same button pauses and resumes it.
    @objc private func playPauseTapped() {
        if transport.playingSession() != nil {
            transport.togglePlayPause()
        } else if let newest = latestSessions.first {
            transport.playSession(newest)
        }
        syncTransport()
    }

    @objc private func keepTapped() {
        transport.keepLastMinute()
        syncTransport()
    }

    @objc private func metronomeTapped() {
        transport.toggleMetronome()
        syncTransport()
    }

    @objc private func stopPlaybackTapped() {
        transport.stopPlayback()
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
        transport.toggleListening()
        syncTransport()
    }

    @objc private func exportTapped() {
        transport.export()
    }
}
