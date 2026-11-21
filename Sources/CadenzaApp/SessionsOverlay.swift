import AppKit
import CadenzaCore

/// The session archive, on glass inside the main window: every session the
/// user kept, newest first, one line each, with the playing one carrying the
/// stamp. A row plays on click and carries its own menu for everything else,
/// so nothing is hidden behind an "expanded" mode and no list is ever cut at
/// four.
@MainActor
final class SessionsOverlayView: NSView, SessionRowActions {
    private let shell: PracticeShell
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
    /// Shift-clicked rows: the archive acts on all of them at once.
    private var selected: Set<UUID> = []
    private let selectionBar = NSStackView()
    private let selectionLabel = makeInkLabel(
        "",
        font: .systemFont(ofSize: 11, weight: .medium),
        color: PaperTheme.secondaryInk
    )

    /// Told the shell to close the overlay, for actions that open something
    /// else (a session's sheet).
    var onLeave: (() -> Void)?

    init(shell: PracticeShell, sessions: [SessionRecord], playing: SessionRecord?) {
        self.shell = shell
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

        let renameAll = NSButton(title: "Rename…", target: self, action: #selector(renameSelectionTapped))
        let deleteAll = NSButton(title: "Delete", target: self, action: #selector(deleteSelectionTapped))
        for button in [renameAll, deleteAll] {
            button.isBordered = false
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.contentTintColor = PaperTheme.ink
        }
        deleteAll.contentTintColor = PaperTheme.stamp
        selectionBar.orientation = .horizontal
        selectionBar.alignment = .firstBaseline
        selectionBar.spacing = 14
        selectionBar.addArrangedSubview(selectionLabel)
        selectionBar.addArrangedSubview(renameAll)
        selectionBar.addArrangedSubview(deleteAll)
        selectionBar.isHidden = true
        selectionBar.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [top, selectionBar, scroll])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.edgeInsets = NSEdgeInsets(top: 26, left: 30, bottom: 20, right: 30)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            top.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 30),
            top.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -30),
            selectionBar.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 30),
            scroll.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -18),
            scroll.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -36),
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

    /// Shift-click: a row joins or leaves the selection instead of playing.
    private func toggleSelection(_ record: SessionRecord) {
        if selected.contains(record.id) {
            selected.remove(record.id)
        } else {
            selected.insert(record.id)
        }
        for row in rows { row.setSelected(selected.contains(row.recordID)) }
        syncSelectionBar()
    }

    private var selectedRecords: [SessionRecord] {
        // the list's own order, newest first, is the order the names follow
        sessions.filter { selected.contains($0.id) }
    }

    private func syncSelectionBar() {
        selectionLabel.stringValue = "\(selected.count) selected"
        selectionBar.isHidden = selected.isEmpty
    }

    func syncTransport() {
        let listening = shell.isListening
        newSessionButton.title = listening ? "Stop session" : "New session"
        newSessionButton.contentTintColor = PaperTheme.stamp
        for row in rows { row.refresh(playingID: playingID) }
    }

    private func rebuild() {
        selected = selected.filter { id in sessions.contains { $0.id == id } }
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
                                 isSelected: selected.contains(record.id),
                                 hasAudio: record.hasAudio)
            row.actions = self
            rows.append(row)
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        syncTransport()
        syncSelectionBar()
    }

    /// Renames every selected take at once: the typed title is the stem and
    /// the archive numbers them -1, -2 in list order, so a batch of takes
    /// stays sorted instead of colliding on one name.
    @objc private func renameSelectionTapped() {
        let records = selectedRecords
        guard !records.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = records.count == 1 ? "Rename session" : "Rename \(records.count) sessions"
        alert.informativeText = records.count == 1
            ? "Give “\(records[0].label)” a name."
            : "One title for all of them; they are numbered -1, -2 and so on."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        field.stringValue = records.count == 1 ? (records[0].name ?? "") : ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let base = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return }
        shell.renameSessions(records, base: base)
        selected.removeAll()
        syncSelectionBar()
    }

    @objc private func deleteSelectionTapped() {
        let records = selectedRecords
        guard !records.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = records.count == 1 ? "Delete session" : "Delete \(records.count) sessions"
        alert.informativeText = records.count == 1
            ? "“\(records[0].label)” and its files go away for good."
            : "All \(records.count) of them, with their MIDI, audio and sheet files, go away for good."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        shell.deleteSessions(records)
        selected.removeAll()
        syncSelectionBar()
    }

    // MARK: the rows

    func rowPlayed(_ record: SessionRecord) {
        shell.playSession(record)
        playingID = shell.playingSession?.id
        syncTransport()
    }

    func rowShiftClicked(_ record: SessionRecord) { toggleSelection(record) }

    func rowOpenedSheet(_ record: SessionRecord) {
        onLeave?()
        shell.openSessionSheet(record)
    }

    func rowRenamed(_ record: SessionRecord) { rename(record) }

    func rowDeleted(_ record: SessionRecord) { delete(record) }

    func rowDescribed(_ record: SessionRecord, from anchor: NSView) { describe(record, from: anchor) }

    func rowCopiedMIDI(_ record: SessionRecord) { shell.copySessionMIDI(record) }

    func rowPlayedAlong(_ record: SessionRecord) {
        onLeave?()
        shell.playAlong(record)
    }

    func rowExported(_ record: SessionRecord, choice: ExportChoice) {
        shell.exportSession(record, choice: choice)
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
        shell.renameSession(record, to: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The take describes itself: the row asks the shell to read the MIDI
    /// back and hands the lines to a glass card anchored on the row.
    private func describe(_ record: SessionRecord, from anchor: NSView) {
        guard let description = shell.describeSession(record) else {
            shell.showStatus("That session has no notes to describe", isError: true)
            return
        }
        let popover = TakeDescriptionPopover(description, title: record.name ?? "This take")
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
    }

    private func delete(_ record: SessionRecord) {
        let alert = NSAlert()
        alert.messageText = "Delete session"
        alert.informativeText = "“\(record.label)” and its files — MIDI, audio and sheet — go away for good."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        shell.deleteSession(record)
    }

    @objc private func newSessionTapped() {
        shell.toggleListening()
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
    private var isSelected: Bool
    private var tracking: NSTrackingArea?
    var recordID: UUID { record.id }
    private var hovered = false {
        didSet { needsDisplay = true }
    }
    /// Everything the row can ask for, answered by the archive that owns it.
    /// The row hands itself back, so the archive never captures a record it
    /// has to keep in step with the list.
    weak var actions: SessionRowActions?

    init(record: SessionRecord, isPlaying: Bool, isSelected: Bool, hasAudio: Bool) {
        self.record = record
        self.isPlaying = isPlaying
        self.isSelected = isSelected
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

    /// The selection moved elsewhere: only the wash changes.
    func setSelected(_ selected: Bool) {
        guard isSelected != selected else { return }
        isSelected = selected
        needsDisplay = true
    }

    func refresh(playingID: UUID?) {
        isPlaying = playingID == record.id
        playButton.image = NSImage(systemSymbolName: isPlaying ? "stop.fill" : "play.fill",
                                   accessibilityDescription: isPlaying ? "Stop" : "Play")
        playButton.contentTintColor = isPlaying ? PaperTheme.stamp : PaperTheme.ink
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered || isPlaying || isSelected else { return }
        let wash: NSColor
        if isSelected {
            wash = PaperTheme.stamp.withAlphaComponent(0.14)
        } else if isPlaying {
            wash = PaperTheme.stamp.withAlphaComponent(0.10)
        } else {
            wash = PaperTheme.ink.withAlphaComponent(0.05)
        }
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
        if event.modifierFlags.contains(.shift) {
            actions?.rowShiftClicked(record)
        } else {
            actions?.rowPlayed(record)
        }
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
        actions?.rowPlayed(record)
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
        menu.addItem(.separator())
        let describe = menu.addItem(withTitle: "Describe take", action: #selector(describeTapped), keyEquivalent: "")
        describe.target = self
        menu.addItem(.separator())
        let remove = menu.addItem(withTitle: "Delete…", action: #selector(deleteTapped), keyEquivalent: "")
        remove.target = self
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.maxX - 20, y: 8), in: self)
    }

    @objc private func sheetTapped() { actions?.rowOpenedSheet(record) }
    @objc private func copyTapped() { actions?.rowCopiedMIDI(record) }
    @objc private func renameTapped() { actions?.rowRenamed(record) }
    @objc private func deleteTapped() { actions?.rowDeleted(record) }
    @objc private func describeTapped() { actions?.rowDescribed(record, from: self) }
    @objc private func playAlongTapped() { actions?.rowPlayedAlong(record) }
    @objc private func exportMIDITapped() { actions?.rowExported(record, choice: .midi) }
    @objc private func exportAudioTapped() { actions?.rowExported(record, choice: .audio) }
    @objc private func exportBothTapped() { actions?.rowExported(record, choice: .both) }
}

/// What a session row can ask of the archive that owns it. The row knows its
/// own record and hands it back, so the archive answers with a method instead
/// of the row holding a closure per menu item.
@MainActor
protocol SessionRowActions: AnyObject {
    func rowPlayed(_ record: SessionRecord)
    func rowShiftClicked(_ record: SessionRecord)
    func rowOpenedSheet(_ record: SessionRecord)
    func rowRenamed(_ record: SessionRecord)
    func rowDeleted(_ record: SessionRecord)
    func rowDescribed(_ record: SessionRecord, from anchor: NSView)
    func rowCopiedMIDI(_ record: SessionRecord)
    func rowPlayedAlong(_ record: SessionRecord)
    func rowExported(_ record: SessionRecord, choice: ExportChoice)
}
