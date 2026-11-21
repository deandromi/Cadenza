import AppKit
import CadenzaCore

/// The session archive, on glass inside the main window: every session the
/// user kept, newest first, one line each, with the playing one carrying the
/// stamp. A row plays on click and carries its own menu for everything else,
/// so nothing is hidden behind an "expanded" mode and no list is ever cut at
/// four.
@MainActor
final class SessionsOverlayView: NSView {
    private let transport: PanelTransport
    private let titleLabel = makeInkLabel(
        "Sessions",
        font: PaperTheme.displaySerif(26, weight: .semibold),
        color: PaperTheme.ink
    )
    private let countLabel = makeInkLabel(
        "",
        font: .systemFont(ofSize: 11, weight: .medium),
        color: PaperTheme.secondaryInk
    )
    private let newSessionButton = NSButton(title: "New session", target: nil, action: nil)
    private let scroll = NSScrollView()
    private let list = FlippedStackView()
    private let emptyLabel = makeInkLabel(
        "No sessions yet. Press New session and play, and it lands here.",
        font: .systemFont(ofSize: 12, weight: .regular),
        color: PaperTheme.secondaryInk
    )
    private var sessions: [SessionRecord] = []
    private var playingID: UUID?
    private var rows: [SessionRow] = []

    /// Told the shell to close the overlay, for actions that open something
    /// else (a session's sheet).
    var onLeave: (() -> Void)?

    init(transport: PanelTransport, sessions: [SessionRecord], playing: SessionRecord?) {
        self.transport = transport
        self.sessions = sessions
        self.playingID = playing?.id
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        newSessionButton.isBordered = false
        newSessionButton.font = .systemFont(ofSize: 12, weight: .medium)
        newSessionButton.contentTintColor = PaperTheme.stamp
        newSessionButton.target = self
        newSessionButton.action = #selector(newSessionTapped)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = list
        scroll.translatesAutoresizingMaskIntoConstraints = false
        list.translatesAutoresizingMaskIntoConstraints = false
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)

        let header = NSStackView(views: [titleLabel, countLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 2
        header.translatesAutoresizingMaskIntoConstraints = false

        let top = NSStackView(views: [header, NSView(), newSessionButton])
        top.orientation = .horizontal
        top.alignment = .firstBaseline
        top.spacing = 12
        top.translatesAutoresizingMaskIntoConstraints = false

        addSubview(top)
        addSubview(scroll)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
            top.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -30),
            top.topAnchor.constraint(equalTo: topAnchor, constant: 26),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 16),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor, constant: 12),
            list.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor, constant: -12),
            list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -30),
            emptyLabel.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 8),
        ])
        rebuild()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The archive moved while the overlay was open (a rename, a new take).
    func update(sessions: [SessionRecord], playing: SessionRecord?) {
        self.sessions = sessions
        self.playingID = playing?.id
        rebuild()
    }

    func syncTransport() {
        let listening = transport.isListening()
        newSessionButton.title = listening ? "Stop session" : "New session"
        newSessionButton.contentTintColor = PaperTheme.stamp
        for row in rows { row.refresh(playingID: playingID) }
    }

    private func rebuild() {
        for row in rows {
            list.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        rows = []
        countLabel.stringValue = sessions.isEmpty
            ? "nothing recorded yet"
            : "\(sessions.count) saved"
        emptyLabel.isHidden = !sessions.isEmpty
        for record in sessions {
            let row = SessionRow(record: record,
                                 isPlaying: record.id == playingID,
                                 hasAudio: record.hasAudio)
            row.onPlay = { [weak self] in
                guard let self else { return }
                self.transport.playSession(record)
                self.playingID = self.transport.playingSession()?.id
                self.syncTransport()
            }
            row.onSheet = { [weak self] in
                self?.onLeave?()
                self?.transport.openSessionSheet(record)
            }
            row.onRename = { [weak self] in self?.rename(record) }
            row.onCopyMIDI = { [weak self] in self?.transport.copySessionMIDI(record) }
            row.onPlayAlong = { [weak self] in
                self?.onLeave?()
                self?.transport.playAlong(record)
            }
            row.onExport = { [weak self] choice in
                guard let self else { return }
                switch choice {
                case .midi: self.transport.exportSessionMIDI(record)
                case .audio: self.transport.exportSessionAudio(record)
                case .both: self.transport.exportSessionBoth(record)
                }
            }
            rows.append(row)
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        syncTransport()
    }

    private func rename(_ record: SessionRecord) {
        let alert = NSAlert()
        alert.messageText = "Rename session"
        alert.informativeText = "Give “\(record.label)” a name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        field.stringValue = record.name ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        transport.renameSession(record, field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @objc private func newSessionTapped() {
        transport.toggleListening()
        syncTransport()
    }
}

/// A stack view that fills its scroll view from the top: AppKit's document
/// views grow upward unless they say otherwise, and a list that starts at the
/// bottom of an empty scroll view reads as broken.
@MainActor
final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// One session, one line: play, name, when and how big, and a menu for the
/// rest. Hovering lifts a wash under the row; the playing row keeps it.
@MainActor
final class SessionRow: NSView {
    private let record: SessionRecord
    private let playButton = NSButton()
    private let nameLabel: NSTextField
    private let metaLabel: NSTextField
    private let menuButton = NSButton()
    private var isPlaying: Bool
    private var tracking: NSTrackingArea?
    private var hovered = false {
        didSet { needsDisplay = true }
    }
    var onPlay: (() -> Void)?
    var onSheet: (() -> Void)?
    var onRename: (() -> Void)?
    var onCopyMIDI: (() -> Void)?
    var onPlayAlong: (() -> Void)?
    var onExport: ((ExportChoice) -> Void)?

    init(record: SessionRecord, isPlaying: Bool, hasAudio: Bool) {
        self.record = record
        self.isPlaying = isPlaying
        let title = record.name?.isEmpty == false
            ? record.name!
            : (record.folderName ?? "Untitled take")
        nameLabel = makeInkLabel(title,
                                 font: .systemFont(ofSize: 13, weight: .medium),
                                 color: PaperTheme.ink)
        let stamp = SessionStamp.panel.string(from: record.startedAt)
        metaLabel = makeInkLabel(
            "\(stamp) · \(sessionTimeString(record.durationSeconds)) · \(record.noteCount) notes"
                + (hasAudio ? "" : " · MIDI only"),
            font: .systemFont(ofSize: 11, weight: .regular),
            color: PaperTheme.secondaryInk
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        playButton.isBordered = false
        playButton.imagePosition = .imageOnly
        playButton.image = NSImage(systemSymbolName: isPlaying ? "stop.fill" : "play.fill",
                                   accessibilityDescription: isPlaying ? "Stop" : "Play")
        playButton.contentTintColor = isPlaying ? PaperTheme.stamp : PaperTheme.ink
        playButton.target = self
        playButton.action = #selector(playTapped)

        menuButton.isBordered = false
        menuButton.imagePosition = .imageOnly
        menuButton.image = NSImage(systemSymbolName: "ellipsis",
                                   accessibilityDescription: "Session actions")
        menuButton.contentTintColor = PaperTheme.secondaryInk
        menuButton.target = self
        menuButton.action = #selector(menuTapped)

        for view in [playButton, nameLabel, metaLabel, menuButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 46),
            playButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            playButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 18),
            nameLabel.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: 12),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: menuButton.leadingAnchor, constant: -10),
            metaLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            metaLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            metaLabel.trailingAnchor.constraint(lessThanOrEqualTo: menuButton.leadingAnchor, constant: -10),
            menuButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            menuButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            menuButton.widthAnchor.constraint(equalToConstant: 22),
        ])
        refresh(playingID: isPlaying ? record.id : nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func refresh(playingID: UUID?) {
        isPlaying = playingID == record.id
        playButton.image = NSImage(systemSymbolName: isPlaying ? "stop.fill" : "play.fill",
                                   accessibilityDescription: isPlaying ? "Stop" : "Play")
        playButton.contentTintColor = isPlaying ? PaperTheme.stamp : PaperTheme.ink
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered || isPlaying else { return }
        let wash = isPlaying
            ? PaperTheme.stamp.withAlphaComponent(0.10)
            : PaperTheme.ink.withAlphaComponent(0.05)
        wash.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseDown(with event: NSEvent) {
        onPlay?()
    }

    /// The whole line is the play target, labels included: only the two
    /// controls keep their own clicks, so clicking a session never lands on
    /// empty paper.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        let hit = super.hitTest(point)
        if hit === playButton || hit === menuButton { return hit }
        return self
    }

    @objc private func playTapped() {
        onPlay?()
    }

    @objc private func menuTapped() {
        let menu = NSMenu()
        let sheet = menu.addItem(withTitle: "Open sheet", action: #selector(sheetTapped), keyEquivalent: "")
        sheet.target = self
        let copy = menu.addItem(withTitle: "Copy MIDI", action: #selector(copyTapped), keyEquivalent: "")
        copy.target = self
        let rename = menu.addItem(withTitle: "Rename…", action: #selector(renameTapped), keyEquivalent: "")
        rename.target = self
        menu.addItem(.separator())
        let midi = menu.addItem(withTitle: "Export MIDI…", action: #selector(exportMIDITapped), keyEquivalent: "")
        midi.target = self
        let audio = menu.addItem(withTitle: "Export audio…", action: #selector(exportAudioTapped), keyEquivalent: "")
        audio.target = self
        let both = menu.addItem(withTitle: "Export MIDI and audio…", action: #selector(exportBothTapped), keyEquivalent: "")
        both.target = self
        menu.addItem(.separator())
        let along = menu.addItem(withTitle: "Play along", action: #selector(playAlongTapped), keyEquivalent: "")
        along.target = self
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.maxX - 20, y: 8), in: self)
    }

    @objc private func sheetTapped() { onSheet?() }
    @objc private func copyTapped() { onCopyMIDI?() }
    @objc private func renameTapped() { onRename?() }
    @objc private func playAlongTapped() { onPlayAlong?() }
    @objc private func exportMIDITapped() { onExport?(.midi) }
    @objc private func exportAudioTapped() { onExport?(.audio) }
    @objc private func exportBothTapped() { onExport?(.both) }
}
