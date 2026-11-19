import AppKit

/// What the control panel asks of its owner. Closures keep the panel
/// ignorant of engines and clocks: the gallery feeds it a simulated
/// transport, the app the real one. Listening is recording — the one
/// action starts and stops the session that export hands over.
struct PanelTransport {
    var isListening: () -> Bool
    var toggleListening: () -> Void
    var exportEnabled: () -> Bool
    var export: () -> Void
    /// Play or stop a preserved session, owned by the app shell.
    var playSession: (SessionRecord) -> Void = { _ in }
    /// Whether one session is playing right now.
    var playingSession: () -> SessionRecord? = { nil }
    /// Pause a playing session, or resume a paused one; with nothing
    /// playing, starts the newest session.
    var togglePlayPause: () -> Void = { }
    /// Stop playback outright, paused or not.
    var stopPlayback: () -> Void = { }
    /// Whether playback is paused right now.
    var playbackPaused: () -> Bool = { false }
    /// Per-session actions, revealed when the panel expands: rename the
    /// session, copy its MIDI file to the clipboard, open its sheet, play
    /// along with it, export MIDI, audio or both.
    var renameSession: (SessionRecord, String) -> Void = { _, _ in }
    var copySessionMIDI: (SessionRecord) -> Void = { _ in }
    var openSessionSheet: (SessionRecord) -> Void = { _ in }
    var playAlong: (SessionRecord) -> Void = { _ in }
    var exportSessionMIDI: (SessionRecord) -> Void = { _ in }
    var exportSessionAudio: (SessionRecord) -> Void = { _ in }
    var exportSessionBoth: (SessionRecord) -> Void = { _ in }
    /// Whether the session folder holds an audio recording.
    var sessionHasAudio: (SessionRecord) -> Bool = { _ in false }
    /// Import a MIDI file as a session.
    var importMIDI: () -> Void = { }
    /// A-B looping over the playing session: marks at the current moment,
    /// the loop toggle, and the practice rate.
    var setLoopPoint: (Bool) -> Void = { _ in }   // true = A, false = B
    var toggleLoop: () -> Void = { }
    var loopActive: () -> Bool = { false }
    var setPlaybackRate: (Double) -> Void = { _ in }
}

/// What an export hands over, chosen in the export popover.
enum ExportChoice {
    case midi
    case audio
    case both
}

/// The export choice popover: one glass lens asking what a session hands
/// over — its MIDI file, its audio recording, or both.
@MainActor
final class ExportChoicesPopover: NSPopover {
    private let onChoice: (ExportChoice) -> Void
    private let hasAudio: Bool

    init(hasAudio: Bool, onChoice: @escaping (ExportChoice) -> Void) {
        self.hasAudio = hasAudio
        self.onChoice = onChoice
        super.init()
        behavior = .transient
        let controller = NSViewController()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 190, height: hasAudio ? 118 : 82))
        let backdrop = makeGlassBackdrop(cornerRadius: 14, interactive: false)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(backdrop)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        for (title, choice) in [("MIDI file", ExportChoice.midi)]
            + (hasAudio ? [("Audio recording", ExportChoice.audio)] : [])
            + (hasAudio ? [("MIDI and audio", ExportChoice.both)] : []) {
            let button = NSButton(title: title, target: self, action: #selector(chose(_:)))
            button.isBordered = false
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.contentTintColor = PaperTheme.ink
            button.identifier = NSUserInterfaceItemIdentifier(switchChoice(choice))
            stack.addArrangedSubview(button)
        }
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: root.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        controller.view = root
        contentViewController = controller
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func switchChoice(_ choice: ExportChoice) -> String {
        switch choice {
        case .midi: return "midi"
        case .audio: return "audio"
        case .both: return "both"
        }
    }

    @objc private func chose(_ sender: NSButton) {
        let id = sender.identifier?.rawValue ?? "midi"
        performClose(nil)
        switch id {
        case "audio": onChoice(.audio)
        case "both": onChoice(.both)
        default: onChoice(.midi)
        }
    }
}

/// Shot diagnostics shared by every screen carrying the practice chrome:
/// the rectangles where label and button ink should reach the screen, in
/// the given view's coordinates, so the live capture can prove it did.
@MainActor
func paperInkRects(
    panel: ControlPanelLens,
    wordmark: NSView,
    in view: NSView
) -> [(String, NSRect)] {
    var rects = panel.contentRects().map { name, rect in
        (name, panel.convert(rect, to: view))
    }
    rects.append(("wordmark", view.convert(wordmark.frame, to: view)))
    return rects
}

/// The wordmark's terminal dot: the stamp speaking once, quietly.
final class StampDot: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        PaperTheme.stamp.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// Top-right glass pill opening the menu of the app's sections. Sheet music
/// is live; the rest stay disabled until those sections exist.
final class MenuLens: NSView {
    private let menuButton = NSButton(title: "Menu", target: nil, action: nil)
    private var pill: NSStackView?
    private var backdrop: NSView?
    private let menuItems = ["Sheet music", "Sessions", "MIDI routing", "Settings"]
    private let onSheetMusic: (() -> Void)?
    private let onSettings: (() -> Void)?

    init(onSheetMusic: (() -> Void)? = nil, onSettings: (() -> Void)? = nil) {
        self.onSheetMusic = onSheetMusic
        self.onSettings = onSettings
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        menuButton.isBordered = false
        menuButton.font = .systemFont(ofSize: 13, weight: .medium)
        menuButton.contentTintColor = PaperTheme.ink
        menuButton.target = self
        menuButton.action = #selector(openMenu)
        // views never mutate before super.init on this OS build: doing so
        // orphans them from the live layout engine
        let newPill = padForLens(menuButton, horizontal: 18, vertical: 12)
        let newBackdrop = makeGlassBackdrop(cornerRadius: 20, interactive: true)
        // on this OS build, pinning a view never auto-disables its
        // autoresizing mask: do it by hand or the view stays at zero
        newPill.translatesAutoresizingMaskIntoConstraints = false
        newBackdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(newBackdrop)
        addSubview(newPill)
        pill = newPill
        backdrop = newBackdrop
        if let pill, let backdrop {
            NSLayoutConstraint.activate([
                backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
                backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
                backdrop.topAnchor.constraint(equalTo: topAnchor),
                backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
                pill.leadingAnchor.constraint(equalTo: leadingAnchor),
                pill.trailingAnchor.constraint(equalTo: trailingAnchor),
                pill.topAnchor.constraint(equalTo: topAnchor),
                pill.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        pill?.fittingSize ?? fittingSize
    }

    @objc private func openMenu() {
        let menu = NSMenu()
        for title in menuItems {
            let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            if title == "Sheet music" {
                item.isEnabled = onSheetMusic != nil
                item.target = self
                item.action = #selector(sheetMusicTapped)
            } else if title == "Settings" {
                item.isEnabled = onSettings != nil
                item.target = self
                item.action = #selector(settingsTapped)
            } else {
                // items stay disabled: the sections are future work, the
                // menu shows where they will live
                item.isEnabled = false
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: menuButton.bounds.minY - 8), in: menuButton)
    }

    @objc private func sheetMusicTapped() {
        onSheetMusic?()
    }

    @objc private func settingsTapped() {
        onSettings?()
    }
}

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
        guard !sessions.isEmpty else { return "No practice recorded yet" }
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: startOfToday)) ?? startOfToday
        var todaySeconds = 0.0
        var todayNotes = 0
        var weekSeconds = 0.0
        var weekNotes = 0
        var weekSessions = 0
        for session in sessions {
            if session.startedAt >= startOfWeek {
                weekSeconds += session.durationSeconds
                weekNotes += session.noteCount
                weekSessions += 1
            }
            if session.startedAt >= startOfToday {
                todaySeconds += session.durationSeconds
                todayNotes += session.noteCount
            }
        }
        func minutes(_ seconds: Double) -> String {
            Int(seconds / 60) >= 60
                ? "\(Int(seconds / 3600)) h \(Int(seconds / 60) % 60) min"
                : "\(max(1, Int(seconds / 60))) min"
        }
        if todaySeconds < 1, weekSeconds < 1 { return "No practice recorded yet" }
        var line = todaySeconds >= 1 ? "Today \(minutes(todaySeconds)) · \(todayNotes) notes" : "Nothing today"
        line += weekSessions > 0 ? " · week \(minutes(weekSeconds)) · \(weekNotes) notes" : ""
        return line
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

/// The 88-key bed along the bottom: warm ivory naturals with a front lip,
/// warm ink sharps with authentic offsets and a lacquer ridge, the stamp
/// carrying whichever pitches sound right now, and the shadow the fallboard
/// casts across the top of the bed.
final class KeybedView: NSView {
    private static let naturals = 52

    /// the dark bed the keys sit in; it shows through every seam
    private static let keybed = NSColor(name: "cadenzaKeybed") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.04, alpha: 1.0)
            : NSColor(calibratedRed: 0.129, green: 0.122, blue: 0.114, alpha: 1.0)
    }

    /// where each sharp really sits relative to its boundary, in fractions
    /// of a natural's width, the way a piano's action is actually laid out
    private static let accidentalOffsets: [Int: CGFloat] = [
        1: -0.09,
        3: 0.09,
        6: -0.11,
        8: 0.0,
        10: 0.11,
    ]

    private static let ivory = NSColor(name: "cadenzaKeyIvory") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.22, alpha: 1.0)
            : NSColor(calibratedRed: 0.988, green: 0.98, blue: 0.961, alpha: 1.0)
    }

    private static let ivoryShade = NSColor(name: "cadenzaKeyIvoryShade") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.16, alpha: 1.0)
            : NSColor(calibratedRed: 0.918, green: 0.898, blue: 0.867, alpha: 1.0)
    }

    private static let ebony = NSColor(name: "cadenzaKeyEbony") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.06, alpha: 1.0)
            : NSColor(calibratedRed: 0.243, green: 0.231, blue: 0.220, alpha: 1.0)
    }

    /// pitches sounding right now; stamp-tinted keys follow
    var soundingPitches: Set<Int> = [] {
        didSet { needsDisplay = true }
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        let naturalWidth = bounds.width / CGFloat(Self.naturals)
        Self.keybed.setFill()
        bounds.fill()
        drawNaturals(width: naturalWidth)
        drawAccidentals(width: naturalWidth)
        drawFallboardShadow()
    }

    /// A key front: rounded at the player's edge, square at the fallboard.
    private func keyFront(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + radius))
        path.appendArc(
            from: NSPoint(x: rect.minX, y: rect.minY),
            to: NSPoint(x: rect.minX + radius, y: rect.minY),
            radius: radius
        )
        path.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
        path.appendArc(
            from: NSPoint(x: rect.maxX, y: rect.minY),
            to: NSPoint(x: rect.maxX, y: rect.minY + radius),
            radius: radius
        )
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.close()
        return path
    }

    private func drawNaturals(width: CGFloat) {
        let keyHeight = bounds.height
        // the seam: dark bed showing between ivory blocks
        let seam: CGFloat = 0.8
        var index = 0
        for pitch in PianoRange.firstPitch...PianoRange.lastPitch where Self.isNatural(pitch) {
            let rect = NSRect(
                x: CGFloat(index) * width + seam,
                y: 0,
                width: width - seam * 2,
                height: keyHeight
            )
            let key = keyFront(rect, radius: 2.5)
            Self.ivory.setFill()
            key.fill()
            if soundingPitches.contains(pitch) {
                PaperTheme.stamp.withAlphaComponent(0.14).setFill()
                key.fill()
            }
            // the front face dips out of the light: shade washing up from
            // the foot, breaking at a crisp seam line
            let lip = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 9)
            if let gradient = NSGradient(colors: [
                Self.ivoryShade,
                Self.ivoryShade.withAlphaComponent(0.0),
            ]) {
                gradient.draw(in: lip, angle: 90)
            }
            Self.ivoryShade.withAlphaComponent(0.55).setFill()
            NSRect(x: rect.minX, y: lip.maxY, width: rect.width, height: 1).fill()
            index += 1
        }
    }

    private func drawAccidentals(width: CGFloat) {
        let accidentalWidth = width * 0.55
        let accidentalHeight = bounds.height * 0.62
        var naturalsPassed = 0
        for pitch in PianoRange.firstPitch...PianoRange.lastPitch {
            if Self.isNatural(pitch) {
                naturalsPassed += 1
                continue
            }
            // the sharp leans the way a real action does, never dead-center
            let drift = Self.accidentalOffsets[pitch % 12] ?? 0
            let center = CGFloat(naturalsPassed) * width + drift * width
            let rect = NSRect(
                x: center - accidentalWidth / 2,
                y: bounds.height - accidentalHeight,
                width: accidentalWidth,
                height: accidentalHeight
            )
            let key = keyFront(rect, radius: 2)
            // the sharp leans over the naturals: a heavy cast shadow first
            NSGraphicsContext.current?.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1.5)
            shadow.set()
            Self.ebony.setFill()
            key.fill()
            NSGraphicsContext.current?.restoreGraphicsState()
            if soundingPitches.contains(pitch) {
                PaperTheme.stamp.withAlphaComponent(0.88).setFill()
                key.fill()
            }
            // lacquer: one vertical gloss ridge where the light rolls off
            if let gloss = NSGradient(colors: [
                NSColor.white.withAlphaComponent(0.30),
                NSColor.white.withAlphaComponent(0.04),
            ]) {
                gloss.draw(
                    in: NSRect(
                        x: rect.minX + 1.2,
                        y: rect.minY + 2,
                        width: 1.8,
                        height: rect.height - 4
                    ),
                    angle: -90
                )
            }
            PaperTheme.hairline.withAlphaComponent(0.30).setStroke()
            key.lineWidth = 1
            key.stroke()
        }
    }

    /// The case above the keys: no felt, only the shadow the fallboard casts
    /// across the top of the bed.
    private func drawFallboardShadow() {
        if let shadow = NSGradient(colors: [
            NSColor.black.withAlphaComponent(0.18),
            NSColor.black.withAlphaComponent(0.0),
        ]) {
            shadow.draw(
                in: NSRect(x: 0, y: bounds.height - 6, width: bounds.width, height: 6),
                angle: -90
            )
        }
    }

    private static func isNatural(_ pitch: Int) -> Bool {
        [0, 2, 4, 5, 7, 9, 11].contains(pitch % 12)
    }
}

/// One blooming musical note, hand-drawn: tilted ellipse head with a light
/// inner sheen, tapered stem, and for single notes a full curved flag; bass
/// voices come as beamed pairs. Tinted stamp while sounding, warm ink once
/// released, resting on a whisper of shadow.
final class NoteGlyphView: NSView {
    enum Phase {
        case sounding
        case released
    }

    enum Shape {
        case single
        case beamedPair
    }

    let shape: Shape
    var phase: Phase = .sounding {
        didSet { needsDisplay = true }
    }

    init(shape: Shape, height: CGFloat, rotation: CGFloat) {
        self.shape = shape
        let width = height * (shape == .beamedPair ? 0.98 : 0.72)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        frameRotation = rotation
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        let ink: NSColor = phase == .sounding ? PaperTheme.stamp : PaperTheme.ink
        let sheen = NSColor.white.withAlphaComponent(0.30)
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()

        switch shape {
        case .single:
            drawSingleNote(in: bounds, ink: ink, sheen: sheen)
        case .beamedPair:
            drawBeamedPair(in: bounds, ink: ink, sheen: sheen)
        }
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    /// Head as a tilted ellipse, engraved with a hint of light.
    private func head(center: NSPoint, unit: CGFloat) -> NSBezierPath {
        tiltedEllipse(
            center: center,
            radiusX: 0.145 * unit,
            radiusY: 0.088 * unit,
            tilt: -22
        )
    }

    private func drawSingleNote(in bounds: NSRect, ink: NSColor, sheen: NSColor) {
        let unit = bounds.height
        ink.setFill()
        head(center: NSPoint(x: 0.23 * unit, y: 0.225 * unit), unit: unit).fill()
        sheen.setFill()
        tiltedEllipse(
            center: NSPoint(x: 0.21 * unit, y: 0.245 * unit),
            radiusX: 0.07 * unit,
            radiusY: 0.04 * unit,
            tilt: -22
        ).fill()
        taperedStem(
            bottomX: 0.331 * unit,
            fromY: 0.20 * unit,
            toY: 0.94 * unit,
            widthAtBottom: 0.038 * unit,
            widthAtTop: 0.030 * unit,
            ink: ink
        )
        drawFlag(unit: unit, ink: ink)
    }

    /// The classic eighth-note flag, two sweeping cubic curves.
    private func drawFlag(unit: CGFloat, ink: NSColor) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0.365 * unit, y: 0.94 * unit))
        path.curve(
            to: NSPoint(x: 0.548 * unit, y: 0.818 * unit),
            controlPoint1: NSPoint(x: 0.46 * unit, y: 0.925 * unit),
            controlPoint2: NSPoint(x: 0.535 * unit, y: 0.885 * unit)
        )
        path.curve(
            to: NSPoint(x: 0.503 * unit, y: 0.657 * unit),
            controlPoint1: NSPoint(x: 0.558 * unit, y: 0.77 * unit),
            controlPoint2: NSPoint(x: 0.535 * unit, y: 0.715 * unit)
        )
        path.curve(
            to: NSPoint(x: 0.447 * unit, y: 0.662 * unit),
            controlPoint1: NSPoint(x: 0.487 * unit, y: 0.64 * unit),
            controlPoint2: NSPoint(x: 0.462 * unit, y: 0.648 * unit)
        )
        path.curve(
            to: NSPoint(x: 0.393 * unit, y: 0.762 * unit),
            controlPoint1: NSPoint(x: 0.428 * unit, y: 0.68 * unit),
            controlPoint2: NSPoint(x: 0.404 * unit, y: 0.728 * unit)
        )
        path.line(to: NSPoint(x: 0.365 * unit, y: 0.772 * unit))
        path.line(to: NSPoint(x: 0.365 * unit, y: 0.94 * unit))
        path.close()
        ink.setFill()
        path.fill()
    }

    private func drawBeamedPair(in bounds: NSRect, ink: NSColor, sheen: NSColor) {
        let unit = bounds.height
        ink.setFill()
        head(center: NSPoint(x: 0.16 * unit, y: 0.315 * unit), unit: unit).fill()
        head(center: NSPoint(x: 0.60 * unit, y: 0.225 * unit), unit: unit).fill()
        sheen.setFill()
        tiltedEllipse(
            center: NSPoint(x: 0.14 * unit, y: 0.335 * unit),
            radiusX: 0.07 * unit,
            radiusY: 0.04 * unit,
            tilt: -22
        ).fill()
        tiltedEllipse(
            center: NSPoint(x: 0.58 * unit, y: 0.245 * unit),
            radiusX: 0.07 * unit,
            radiusY: 0.04 * unit,
            tilt: -22
        ).fill()

        stemQuad(x: 0.261 * unit, fromY: 0.29 * unit, toY: 0.90 * unit, width: 0.034 * unit, ink: ink)
        stemQuad(x: 0.70 * unit, fromY: 0.205 * unit, toY: 0.855 * unit, width: 0.034 * unit, ink: ink)

        // the beam slants gently down toward the second head
        let beam = NSBezierPath()
        beam.move(to: NSPoint(x: 0.261 * unit, y: 0.90 * unit))
        beam.line(to: NSPoint(x: 0.734 * unit, y: 0.855 * unit))
        beam.line(to: NSPoint(x: 0.734 * unit, y: 0.79 * unit))
        beam.line(to: NSPoint(x: 0.261 * unit, y: 0.835 * unit))
        beam.close()
        ink.setFill()
        beam.fill()
    }

    private func stemQuad(x: CGFloat, fromY: CGFloat, toY: CGFloat, width: CGFloat, ink: NSColor) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: fromY))
        path.line(to: NSPoint(x: x, y: toY))
        path.line(to: NSPoint(x: x + width, y: toY))
        path.line(to: NSPoint(x: x + width, y: fromY))
        path.close()
        ink.setFill()
        path.fill()
    }

    private func taperedStem(
        bottomX: CGFloat,
        fromY: CGFloat,
        toY: CGFloat,
        widthAtBottom: CGFloat,
        widthAtTop: CGFloat,
        ink: NSColor
    ) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bottomX, y: fromY))
        path.line(to: NSPoint(x: bottomX, y: toY))
        path.line(to: NSPoint(x: bottomX + widthAtTop, y: toY))
        path.line(to: NSPoint(x: bottomX + widthAtBottom, y: fromY))
        path.close()
        ink.setFill()
        path.fill()
    }

    private func tiltedEllipse(
        center: NSPoint,
        radiusX: CGFloat,
        radiusY: CGFloat,
        tilt: CGFloat
    ) -> NSBezierPath {
        let path = NSBezierPath(ovalIn: NSRect(
            x: center.x - radiusX,
            y: center.y - radiusY,
            width: radiusX * 2,
            height: radiusY * 2
        ))
        var transform = AffineTransform(translationByX: center.x, byY: center.y)
        transform.rotate(byDegrees: tilt)
        transform.translate(x: -center.x, y: -center.y)
        path.transform(using: transform)
        return path
    }
}

/// Where playing becomes visible: large musical notes falling into the field
/// in a soft cascade, placed the way notation places them so they never
/// crowd, drifting up gently while the chord holds, then dissolving out of
/// the paper. Bass left, treble right, faint staff lines wash underneath.
final class NoteBloomView: NSView {
    private struct Petal {
        let glyph: NoteGlyphView
        let pitch: Int
        let x: CGFloat
        let yBase: CGFloat
        let spawnAt: Double
        var releaseAt: Double?
    }

    private static let maxPetals = 18
    private static let tickInterval = 1.0 / 30.0
    private static let appearOver = 0.7
    private static let fadeOver = 2.6
    private static let cascadeStep = 0.12
    private static let riseWhileHeld = 6.0
    private static let riseAfterRelease = 9.0

    private var petals: [Petal] = []
    private var timer: Timer?
    private var elapsed = 0.0

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        // the staff wash: hairlines the notes sit among, barely-there
        let wash = PaperTheme.ink.withAlphaComponent(0.045)
        wash.setFill()
        let lines = 9
        let gap = bounds.height / CGFloat(lines + 1)
        for index in 1...lines {
            NSRect(x: 0, y: CGFloat(index) * gap, width: bounds.width, height: 1).fill()
        }
    }

    /// Spawns one note per pitch of a freshly struck chord, cascading.
    func strike(pitches: [Int], serial: Int) {
        startTimerIfNeeded()
        for (offset, pitch) in pitches.enumerated() {
            let glyph = NoteGlyphView(
                shape: pitch < 60 ? .beamedPair : .single,
                height: Self.glyphHeight(pitch, in: bounds.height),
                rotation: Self.rotation(pitch, serial: serial)
            )
            glyph.alphaValue = 0
            addSubview(glyph)
            petals.append(Petal(
                glyph: glyph,
                pitch: pitch,
                x: Self.glyphX(pitch, serial: serial, in: bounds.width),
                yBase: Self.glyphY(pitch, in: bounds.height),
                spawnAt: elapsed + Double(offset) * Self.cascadeStep,
                releaseAt: nil
            ))
        }
        while petals.count > Self.maxPetals {
            petals.removeFirst().glyph.removeFromSuperview()
        }
        tick()
    }

    /// Hands one pitch back to the ink: its blooming notes start their fade.
    func release(pitch: Int) {
        for index in petals.indices where petals[index].releaseAt == nil && petals[index].pitch == pitch {
            petals[index].releaseAt = elapsed
            petals[index].glyph.phase = .released
        }
    }

    /// Releases every blooming note: back to ink, then into the fade.
    func releaseAll() {
        for index in petals.indices where petals[index].releaseAt == nil {
            petals[index].releaseAt = elapsed
            petals[index].glyph.phase = .released
        }
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        elapsed += Self.tickInterval
        var expired: [Int] = []
        for (index, petal) in petals.enumerated() {
            let age = elapsed - petal.spawnAt
            let appear = Self.smoothstep(min(1, max(0, age / Self.appearOver)))
            let fade: Double
            if let releaseAt = petal.releaseAt {
                fade = 1 - min(1, (elapsed - releaseAt) / Self.fadeOver)
            } else {
                fade = 1
            }
            let driftAfterRelease = petal.releaseAt.map {
                Self.riseAfterRelease * (elapsed - $0)
            } ?? 0
            let rise = Self.riseWhileHeld * max(0, age) + driftAfterRelease

            petal.glyph.alphaValue = CGFloat(0.98 * appear * fade)
            petal.glyph.setFrameOrigin(NSPoint(
                x: petal.x - petal.glyph.bounds.width / 2,
                y: petal.yBase + CGFloat(rise)
            ))
            if fade <= 0 { expired.append(index) }
        }
        for index in expired.reversed() {
            petals.remove(at: index).glyph.removeFromSuperview()
        }
    }

    private static func smoothstep(_ p: Double) -> Double {
        p * p * (3 - 2 * p)
    }

    /// Notes run from a sixth to a third of the field, by pitch.
    private static func glyphHeight(_ pitch: Int, in height: CGFloat) -> CGFloat {
        let variance = Double((pitch * 13) % 7) * 0.022
        return CGFloat(Double(height) * (0.16 + variance))
    }

    /// Pitch mirrored across the field the way the keybed lays it out, using
    /// nearly the full width, each strike slightly reseeded.
    private static func glyphX(_ pitch: Int, serial: Int, in width: CGFloat) -> CGFloat {
        let fraction = Double(pitch - PianoRange.firstPitch)
            / Double(PianoRange.lastPitch - PianoRange.firstPitch)
        let jitter = Double((pitch * 53 + serial * 97) % 33 - 16)
        return CGFloat(Double(width) * (0.09 + 0.78 * fraction) + jitter)
    }

    /// Notation logic: high pitches bloom high, low pitches near the keys.
    private static func glyphY(_ pitch: Int, in height: CGFloat) -> CGFloat {
        let fraction = Double(pitch - PianoRange.firstPitch)
            / Double(PianoRange.lastPitch - PianoRange.firstPitch)
        return CGFloat(Double(height) * (0.10 + 0.42 * fraction))
    }

    private static func rotation(_ pitch: Int, serial: Int) -> CGFloat {
        CGFloat((pitch * 29 + serial * 11) % 13 - 6)
    }
}
