import AppKit
import CadenzaCore

/// The session panel: the running clock, the numbers, the breathing level
/// line, the sessions archive with its play controls, and the transport,
/// gathered in one glass lens. The lens is a pure glass backdrop; the rows
/// render through the regular subview chain on top of it, so the panel can
/// never collapse into nothing.
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
    /// the archive: one row per preserved session, newest on top
    private let sessionRows = NSStackView()
    private let sessionsCaption = makeInkLabel(
        "Sessions",
        font: .systemFont(ofSize: 11, weight: .medium),
        color: PaperTheme.secondaryInk
    )
    private let noSessionsLabel = makeInkLabel(
        "No sessions yet",
        font: .systemFont(ofSize: 12, weight: .regular),
        color: PaperTheme.secondaryInk
    )
    private let listenButton = NSButton(title: "New session", target: nil, action: nil)
    private let exportButton = NSButton(title: "Export", target: nil, action: nil)
    private let importButton = NSButton(title: "Import MIDI", target: nil, action: nil)
    /// the transport under the timer: play/pause the session in hand, stop it
    private let playPauseButton = NSButton(title: "Play", target: nil, action: nil)
    private let stopPlaybackButton = NSButton(title: "Stop", target: nil, action: nil)
    /// the loop row, visible while a session plays: marks, toggle, rate
    private let loopAButton = NSButton(title: "Set A", target: nil, action: nil)
    private let loopBButton = NSButton(title: "Set B", target: nil, action: nil)
    private let loopToggleButton = NSButton(title: "Loop", target: nil, action: nil)
    private let ratePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var loopRow: NSStackView?
    /// the practice summary, revealed when the panel expands
    private let practiceCaption = makeInkLabel(
        "Practice",
        font: .systemFont(ofSize: 11, weight: .medium),
        color: PaperTheme.secondaryInk
    )
    private let practiceLabel = makeInkLabel(
        "No practice recorded yet",
        font: .systemFont(ofSize: 12, weight: .regular),
        color: PaperTheme.secondaryInk
    )
    private var importButtons: NSStackView!
    private var latestSessions: [SessionRecord] = []
    private var latestPlaying: SessionRecord?
    /// true while the panel shows the per-session action rows
    private var expanded = false
    /// set by the screen: a tap on the panel's paper (never on a button —
    /// those stay named shortcuts) asks for the panel to move to the center
    /// and unfold its details
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
        for button in [listenButton, exportButton, importButton, playPauseButton, stopPlaybackButton, loopAButton, loopBButton, loopToggleButton] {
            button.isBordered = false
            button.font = .systemFont(ofSize: loopAButton == button ? 11 : 13, weight: .medium)
            button.contentTintColor = PaperTheme.ink
        }
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
        sessionRows.orientation = .vertical
        sessionRows.alignment = .leading
        sessionRows.spacing = 3
        rows.setContentHuggingPriority(.required, for: .vertical)
        let divider = HairlineView()
        let buttons = NSStackView(views: [listenButton, exportButton])
        buttons.orientation = .horizontal
        buttons.spacing = 20
        importButtons = NSStackView(views: [importButton])
        importButtons.orientation = .horizontal
        importButtons.spacing = 20
        let playbackButtons = NSStackView(views: [playPauseButton, stopPlaybackButton])
        playbackButtons.orientation = .horizontal
        playbackButtons.spacing = 20
        playbackButtons.alignment = .firstBaseline
        let loopRow = NSStackView(views: [loopAButton, loopBButton, loopToggleButton, ratePopup])
        loopRow.orientation = .horizontal
        loopRow.spacing = 10
        loopRow.alignment = .firstBaseline
        loopRow.isHidden = true
        self.loopRow = loopRow
        addSubview(backdrop)
        addSubview(rows)
        rows.addArrangedSubview(Self.captionedRow("Session", timeLabel))
        rows.addArrangedSubview(playbackButtons)
        rows.addArrangedSubview(loopRow)
        rows.addArrangedSubview(Self.captionedRow("Notes", countLabel))
        rows.addArrangedSubview(Self.captionedRow("Level", levelLine))
        rows.addArrangedSubview(divider)
        rows.addArrangedSubview(practiceCaption)
        rows.addArrangedSubview(practiceLabel)
        rows.addArrangedSubview(sessionsCaption)
        rows.addArrangedSubview(sessionRows)
        rows.addArrangedSubview(buttons)
        rows.addArrangedSubview(importButtons)
        // the docked panel stays compact: unfolding reveals the practice
        // summary and the import action
        importButtons.isHidden = true
        practiceCaption.isHidden = true
        practiceLabel.isHidden = true
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.topAnchor.constraint(equalTo: topAnchor),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor),
            levelLine.widthAnchor.constraint(equalToConstant: 216),
            divider.widthAnchor.constraint(equalToConstant: 216),
        ])

        listenButton.target = self
        listenButton.action = #selector(listenTapped)
        exportButton.target = self
        exportButton.action = #selector(exportTapped)
        importButton.target = self
        importButton.action = #selector(importTapped)
        playPauseButton.target = self
        playPauseButton.action = #selector(playPauseTapped)
        stopPlaybackButton.target = self
        stopPlaybackButton.action = #selector(stopPlaybackTapped)
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
        loopRow?.isHidden = !(playing && expanded)
        loopToggleButton.contentTintColor = transport.loopActive() ? PaperTheme.stamp : PaperTheme.ink
    }

    /// true while a play-along (listening and playing together) runs; the
    /// play/pause button serves it too.
    var playAlongRunning = false

    func setSession(time: String, notes: String, level: Double, sounding: Bool) {
        timeLabel.stringValue = time
        countLabel.stringValue = notes
        levelLine.setFractionTarget(level)
        levelLine.sounding = sounding
    }

    /// Rebuilds the archive list: one quiet row per preserved session, the
    /// playing one carrying the stamp, none of them crowding the panel.
    /// Also recomputes the practice summary and resets the loop buttons
    /// when the playing session changed.
    func setSessions(_ sessions: [SessionRecord], playing: SessionRecord?) {
        let playingChanged = playing?.id != latestPlaying?.id
        latestSessions = sessions
        latestPlaying = playing
        practiceLabel.stringValue = Self.practiceSummary(sessions)
        if playingChanged {
            for button in [loopAButton, loopBButton, loopToggleButton] {
                button.contentTintColor = PaperTheme.ink
            }
        }
        let playingID = playing?.id
        for view in sessionRows.arrangedSubviews {
            sessionRows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard !sessions.isEmpty else {
            sessionRows.addArrangedSubview(noSessionsLabel)
            // the archive changed: the transport under the timer may have a
            // session to offer now, or the playing one may have ended
            syncTransport()
            return
        }
        for record in sessions.prefix(4) {
            let playButton = NSButton(title: record.id == playingID ? "Stop" : "Play", target: self, action: #selector(playTapped(_:)))
            playButton.isBordered = false
            playButton.font = .systemFont(ofSize: 12, weight: .medium)
            playButton.contentTintColor = record.id == playingID ? PaperTheme.stamp : PaperTheme.ink
            playButton.identifier = NSUserInterfaceItemIdentifier(record.id.uuidString)
            let label = makeInkLabel(
                record.label,
                font: .systemFont(ofSize: 12, weight: .regular),
                color: record.id == playingID ? PaperTheme.ink : PaperTheme.secondaryInk
            )
            let row = NSStackView(views: [playButton, label])
            row.orientation = .horizontal
            row.spacing = 8
            row.setContentHuggingPriority(.required, for: .vertical)
            row.setClippingResistancePriority(.required, for: .vertical)
            if expanded {
                let actions = NSStackView()
                actions.orientation = .horizontal
                actions.spacing = 12
                actions.alignment = .firstBaseline
                for (title, action) in [
                    ("Rename", #selector(renameTapped(_:))),
                    ("Copy MIDI", #selector(copyTapped(_:))),
                    ("Sheet", #selector(sheetTapped(_:))),
                    ("Play along", #selector(playAlongTapped(_:))),
                    ("Export", #selector(exportSessionTapped(_:))),
                ] {
                    let button = NSButton(title: title, target: self, action: action)
                    button.isBordered = false
                    button.font = .systemFont(ofSize: 11, weight: .medium)
                    button.contentTintColor = PaperTheme.secondaryInk
                    button.identifier = NSUserInterfaceItemIdentifier(record.id.uuidString)
                    actions.addArrangedSubview(button)
                }
                let entry = NSStackView(views: [row, actions])
                entry.orientation = .vertical
                entry.alignment = .leading
                entry.spacing = 3
                entry.setContentHuggingPriority(.required, for: .vertical)
                entry.setClippingResistancePriority(.required, for: .vertical)
                sessionRows.addArrangedSubview(entry)
            } else {
                sessionRows.addArrangedSubview(row)
            }
        }
        // the archive changed: the transport under the timer may have a
        // session to offer now, or the playing one may have ended
        syncTransport()
    }

    /// The practice summary: time and note count of today, then the week.
    static func practiceSummary(_ sessions: [SessionRecord]) -> String {
        // the canonical calendar math lives with the statistics section
        PracticeStats.summaryLine(sessions)
    }

    /// A tap on the panel's paper (the window delivers mouse events to the
    /// deepest view, so the buttons keep their own clicks as named
    /// shortcuts) asks the screen to open the big centered glass panel.
    override func mouseDown(with event: NSEvent) {
        onRequestExpand?()
    }

    var isExpanded: Bool { expanded }

    /// Shows or hides the per-session action rows. The big centered panel
    /// opens with expanded rows; the small dock panel starts collapsed.
    func setExpanded(_ newValue: Bool) {
        guard expanded != newValue else { return }
        expanded = newValue
        importButtons.isHidden = !newValue
        practiceCaption.isHidden = !newValue
        practiceLabel.isHidden = !newValue
        setSessions(latestSessions, playing: latestPlaying)
    }

    private func record(for sender: NSButton) -> SessionRecord? {
        guard let identifier = sender.identifier?.rawValue else { return nil }
        return latestSessions.first(where: { $0.id.uuidString == identifier })
    }

    @objc private func renameTapped(_ sender: NSButton) {
        guard let record = record(for: sender) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename session"
        alert.informativeText = "Give “\(record.label)” a name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        field.stringValue = record.name ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        transport.renameSession(record, field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @objc private func copyTapped(_ sender: NSButton) {
        guard let record = record(for: sender) else { return }
        transport.copySessionMIDI(record)
    }

    /// Export asks what to hand over in the glass choice popover: the MIDI
    /// file always, the audio recording when the session kept one, or both.
    @objc private func exportSessionTapped(_ sender: NSButton) {
        guard let record = record(for: sender) else { return }
        let popover = ExportChoicesPopover(hasAudio: transport.sessionHasAudio(record)) { [weak self] choice in
            guard let self else { return }
            switch choice {
            case .midi: self.transport.exportSessionMIDI(record)
            case .audio: self.transport.exportSessionAudio(record)
            case .both: self.transport.exportSessionBoth(record)
            }
        }
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    @objc private func sheetTapped(_ sender: NSButton) {
        guard let record = record(for: sender) else { return }
        transport.openSessionSheet(record)
    }

    @objc private func playAlongTapped(_ sender: NSButton) {
        guard let record = record(for: sender) else { return }
        transport.playAlong(record)
    }

    @objc private func importTapped() {
        transport.importMIDI()
    }

    // MARK: loop and rate

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

    @objc private func stopPlaybackTapped() {
        transport.stopPlayback()
        syncTransport()
    }

    @objc private func playTapped(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue,
              let record = latestSessions.first(where: { $0.id.uuidString == identifier }) else { return }
        transport.playSession(record)
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
