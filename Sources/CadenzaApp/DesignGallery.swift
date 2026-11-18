import AppKit

/// The design gallery: three drafts of the practice screen, each a full
/// window running the same simulated session, so the paper world and the
/// glass chrome can be inspected side by side before the app adopts a
/// direction. Launch with `--designs`.
@MainActor
final class DesignGalleryController: NSObject, NSApplicationDelegate {
    private let clock = DesignSessionClock()
    private var draftHandlers: [(DesignSessionClock.Moment) -> Void] = []
    /// draft windows must be strongly retained or AppKit releases them
    private var windows: [NSWindow] = []

    /// Called directly from main before the run loop starts: the gallery
    /// owns its launch order, so it does not depend on the
    /// applicationDidFinishLaunching callback.
    func openGallery() {
        let practice = PracticeRoomDraft(clock: clock)
        let recital = RecitalDraft(clock: clock)
        let studio = StudioLogDraft(clock: clock)

        let drafts: [(title: String, view: NSView)] = [
            ("Draft A · practice room", practice),
            ("Draft B · recital", recital),
            ("Draft C · studio log", studio),
        ]
        draftHandlers = [practice.handle, recital.handle, studio.handle]

        var offset: CGFloat = 0
        for draft in drafts {
            let window = NSWindow(
                contentRect: NSRect(x: 120 + offset, y: 140 + offset, width: 960, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = draft.title
            window.minSize = NSSize(width: 760, height: 480)
            // every lens in the draft negotiates blending through one
            // container, the way the glass rules require
            let container = NSGlassEffectContainerView(frame: NSRect(x: 0, y: 0, width: 960, height: 620))
            container.addSubview(draft.view)
            draft.view.leadingAnchor.constraint(equalTo: container.leadingAnchor).isActive = true
            draft.view.trailingAnchor.constraint(equalTo: container.trailingAnchor).isActive = true
            draft.view.topAnchor.constraint(equalTo: container.topAnchor).isActive = true
            draft.view.bottomAnchor.constraint(equalTo: container.bottomAnchor).isActive = true
            window.contentView = container
            windows.append(window)
            window.makeKeyAndOrderFront(nil)
            offset += 44
            print("[designs] window opened: \(draft.title)")
            fflush(stdout)
        }

        clock.onUpdate = { [weak self] moment in
            self?.dispatch(moment)
        }
        clock.start()
        NSApplication.shared.activate(ignoringOtherApps: true)
        print("[designs] session clock started, gallery running")
        fflush(stdout)
    }

    private func dispatch(_ moment: DesignSessionClock.Moment) {
        for handle in draftHandlers {
            handle(moment)
        }
    }
}

/// Shared transport lens: the interactive glass pill with listen and record
/// wired to the simulated session, and the stamp record tint. Every draft
/// floats the same chrome; each draft decides where it sits.
final class TransportLens: NSView {
    private let clock: DesignSessionClock
    private let listenButton = NSButton(title: "Listen", target: nil, action: nil)
    private let recordButton = NSButton(title: "Record", target: nil, action: nil)
    private let exportButton = NSButton(title: "Export", target: nil, action: nil)
    private let lens: NSGlassEffectView
    private var recording = false

    init(clock: DesignSessionClock) {
        self.clock = clock
        for button in [listenButton, recordButton, exportButton] {
            button.isBordered = false
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.contentTintColor = PaperTheme.ink
        }
        exportButton.isEnabled = false

        let stack = NSStackView(views: [listenButton, recordButton, exportButton])
        stack.orientation = .horizontal
        stack.spacing = 22
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 22, bottom: 12, right: 22)
        lens = makeLens(style: .regular, interactive: true, cornerRadius: 26, contentView: stack)

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        listenButton.action = #selector(toggleListening)
        listenButton.target = self
        recordButton.action = #selector(toggleRecording)
        recordButton.target = self
        addSubview(lens)
        NSLayoutConstraint.activate([
            lens.leadingAnchor.constraint(equalTo: leadingAnchor),
            lens.trailingAnchor.constraint(equalTo: trailingAnchor),
            lens.topAnchor.constraint(equalTo: topAnchor),
            lens.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func toggleListening() {
        clock.toggleRunning()
        listenButton.title = clock.isRunning ? "Suspend" : "Listen"
    }

    @objc private func toggleRecording() {
        recording.toggle()
        lens.tintColor = recording ? PaperTheme.stamp.withAlphaComponent(0.16) : nil
        recordButton.contentTintColor = recording ? PaperTheme.stamp : PaperTheme.ink
    }
}

/// Draft A, the spec-faithful practice room: session label and hairline,
/// the giant serif chord carrying state in ink and stamp, the history with
/// minute hairlines fading into paper at its top edge, transport pill
/// bottom center, meta lens top right.
final class PracticeRoomDraft: NSView {
    private let clock: DesignSessionClock
    private let chordLabel = makeInkLabel("C", font: PaperTheme.displaySerif(96), color: PaperTheme.ink)
    private let sessionLabel = makeInkLabel("Session", font: .systemFont(ofSize: 12, weight: .medium), color: PaperTheme.secondaryInk)
    private let rowsStack = NSStackView()
    private let scrollView = NSScrollView()
    private let timeLabel = makeInkLabel("0:47", font: .monospacedDigitSystemFont(ofSize: 13, weight: .regular), color: PaperTheme.ink)
    private let countLabel = makeInkLabel("10 notes", font: .monospacedDigitSystemFont(ofSize: 13, weight: .regular), color: PaperTheme.secondaryInk)
    private let levelLine = LevelLineView()
    private var lastRowCount = 0

    init(clock: DesignSessionClock) {
        self.clock = clock
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

        sessionLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sessionLabel)
        chordLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chordLabel)
        let hairline = HairlineView()
        addSubview(hairline)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 8
        rowsStack.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 16, right: 0)
        scrollView.documentView = rowsStack
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        let fade = TopFadeView()
        addSubview(fade)

        let metaLens = metaLens()
        addSubview(metaLens)

        let transport = TransportLens(clock: clock)
        addSubview(transport)

        NSLayoutConstraint.activate([
            sessionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36),
            sessionLabel.topAnchor.constraint(equalTo: topAnchor, constant: 24),

            hairline.topAnchor.constraint(equalTo: sessionLabel.bottomAnchor, constant: 8),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -36),

            chordLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36),
            chordLabel.topAnchor.constraint(equalTo: hairline.bottomAnchor, constant: 14),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -36),
            scrollView.topAnchor.constraint(equalTo: chordLabel.bottomAnchor, constant: 18),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            fade.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            fade.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            fade.heightAnchor.constraint(equalToConstant: 56),
            fade.topAnchor.constraint(equalTo: scrollView.topAnchor),

            metaLens.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            metaLens.topAnchor.constraint(equalTo: topAnchor, constant: 20),

            transport.centerXAnchor.constraint(equalTo: centerXAnchor),
            transport.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -26),
        ])

        rebuildRows()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Meta lens: clear glass, never interactive, the session at a glance.
    private func metaLens() -> NSGlassEffectView {
        let numbers = NSStackView(views: [timeLabel, countLabel])
        numbers.orientation = .vertical
        numbers.alignment = .leading
        numbers.spacing = 4
        let outer = NSStackView(views: [numbers, levelLine])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 10
        outer.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)
        return makeLens(style: .clear, interactive: false, cornerRadius: 20, contentView: outer)
    }

    func handle(_ moment: DesignSessionClock.Moment) {
        chordLabel.stringValue = moment.symbol
        chordLabel.textColor = moment.sounding ? PaperTheme.stamp : PaperTheme.ink
        timeLabel.stringValue = sessionTimeString(moment.seconds)
        countLabel.stringValue = "\(moment.rowCount) notes"
        levelLine.fraction = moment.level
        levelLine.sounding = moment.sounding
        if moment.rowCount != lastRowCount {
            lastRowCount = moment.rowCount
            rebuildRows()
        }
    }

    private func rebuildRows() {
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var lastRuleMinute = -1
        for row in clock.rows {
            let minute = Int(row.atSecond / 90)
            if minute != lastRuleMinute, lastRuleMinute >= 0 {
                let rule = HairlineView()
                rowsStack.addArrangedSubview(rule)
                // activate only once the rule shares a hierarchy with the clip view
                rule.widthAnchor.constraint(
                    equalTo: scrollView.contentView.widthAnchor, constant: -1
                ).isActive = true
            }
            lastRuleMinute = minute

            let time = makeInkLabel(
                sessionTimeString(row.atSecond),
                font: .monospacedDigitSystemFont(ofSize: 13, weight: .regular),
                color: PaperTheme.secondaryInk
            )
            time.setContentCompressionResistancePriority(.required, for: .horizontal)
            let symbol = makeInkLabel(row.symbol, font: PaperTheme.displaySerif(20), color: PaperTheme.ink)
            let line = NSStackView(views: [time, symbol])
            line.orientation = .horizontal
            line.spacing = 14
            line.alignment = .firstBaseline
            rowsStack.addArrangedSubview(line)
        }
        DispatchQueue.main.async { [weak self] in
            self?.scrollToLatest()
        }
    }

    private func scrollToLatest() {
        guard let documentView = scrollView.documentView else { return }
        let height = documentView.bounds.height
        let visible = scrollView.contentView.bounds.height
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(height - visible, 0)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

/// Draft B, the recital: the chord as the whole event, display serif
/// centered on one hairline like a notehead on a staff line, the recent
/// chorus as a single quiet line, glass reduced to the transport.
final class RecitalDraft: NSView {
    private let clock: DesignSessionClock
    private let chordLabel = makeInkLabel("C", font: PaperTheme.displaySerif(110), color: PaperTheme.ink)
    private let chorusLabel = makeInkLabel("", font: PaperTheme.displaySerif(20), color: PaperTheme.secondaryInk)
    private let notehead = NoteheadDot()

    init(clock: DesignSessionClock) {
        self.clock = clock
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

        let staffLine = HairlineView()
        addSubview(staffLine)
        addSubview(notehead)
        chordLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chordLabel)
        chordLabel.alignment = .center
        chorusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chorusLabel)
        chorusLabel.alignment = .center

        let transport = TransportLens(clock: clock)
        addSubview(transport)

        NSLayoutConstraint.activate([
            chordLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            chordLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 60),

            staffLine.centerXAnchor.constraint(equalTo: centerXAnchor),
            staffLine.widthAnchor.constraint(equalToConstant: 360),
            staffLine.bottomAnchor.constraint(equalTo: chordLabel.bottomAnchor, constant: -6),

            notehead.centerXAnchor.constraint(equalTo: chordLabel.leadingAnchor, constant: -22),
            notehead.centerYAnchor.constraint(equalTo: staffLine.centerYAnchor),
            notehead.widthAnchor.constraint(equalToConstant: 11),
            notehead.heightAnchor.constraint(equalToConstant: 11),

            chorusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            chorusLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: 150),

            transport.centerXAnchor.constraint(equalTo: centerXAnchor),
            transport.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -26),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func handle(_ moment: DesignSessionClock.Moment) {
        chordLabel.stringValue = moment.symbol
        chordLabel.textColor = moment.sounding ? PaperTheme.stamp : PaperTheme.ink
        notehead.visible = moment.sounding
        chorusLabel.stringValue = clock.rows.suffix(7).map(\.symbol).joined(separator: "  ·  ")
    }
}

/// The recital's notehead: the stamp dot sitting on the staff line while a
/// chord sounds.
final class NoteheadDot: NSView {
    var visible = false {
        didSet {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if !visible { return }
        PaperTheme.stamp.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// Draft C, the studio log: an editorial two-column sheet, the chord and
/// the session's numbers in the left column on paper, the dense history
/// with per-row hairlines on the right, one lens of glass only.
final class StudioLogDraft: NSView {
    private let clock: DesignSessionClock
    private let chordLabel = makeInkLabel("C", font: PaperTheme.displaySerif(84), color: PaperTheme.ink)
    private let timeLabel = makeInkLabel("0:47", font: .monospacedDigitSystemFont(ofSize: 13, weight: .regular), color: PaperTheme.ink)
    private let countLabel = makeInkLabel("10 notes", font: .monospacedDigitSystemFont(ofSize: 13, weight: .regular), color: PaperTheme.secondaryInk)
    private let levelLine = LevelLineView()
    private let rowsStack = NSStackView()
    private let rowsScroll = NSScrollView()
    private var lastRowCount = 0

    init(clock: DesignSessionClock) {
        self.clock = clock
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

        let columnRule = HairlineView()
        addSubview(columnRule)

        let meta = NSStackView(views: [timeLabel, countLabel])
        meta.orientation = .vertical
        meta.alignment = .leading
        meta.spacing = 4

        chordLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chordLabel)
        meta.translatesAutoresizingMaskIntoConstraints = false
        addSubview(meta)
        levelLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(levelLine)

        let timeHeader = makeInkLabel("Time", font: .systemFont(ofSize: 11, weight: .medium), color: PaperTheme.secondaryInk)
        let chordHeader = makeInkLabel("Chord", font: .systemFont(ofSize: 11, weight: .medium), color: PaperTheme.secondaryInk)
        let header = NSStackView(views: [timeHeader, chordHeader])
        header.orientation = .horizontal
        header.spacing = 92
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 8
        rowsScroll.documentView = rowsStack
        rowsScroll.hasVerticalScroller = true
        rowsScroll.drawsBackground = false
        rowsScroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowsScroll)

        let transport = TransportLens(clock: clock)
        addSubview(transport)

        NSLayoutConstraint.activate([
            columnRule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 344),
            columnRule.topAnchor.constraint(equalTo: topAnchor, constant: 92),
            columnRule.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -92),

            chordLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36),
            chordLabel.topAnchor.constraint(equalTo: topAnchor, constant: 40),

            meta.leadingAnchor.constraint(equalTo: chordLabel.leadingAnchor, constant: 4),
            meta.topAnchor.constraint(equalTo: chordLabel.bottomAnchor, constant: 18),

            levelLine.leadingAnchor.constraint(equalTo: meta.leadingAnchor),
            levelLine.trailingAnchor.constraint(equalTo: columnRule.leadingAnchor, constant: -36),
            levelLine.topAnchor.constraint(equalTo: meta.bottomAnchor, constant: 14),

            header.leadingAnchor.constraint(equalTo: columnRule.leadingAnchor, constant: 24),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 32),
            rowsScroll.leadingAnchor.constraint(equalTo: columnRule.leadingAnchor, constant: 24),
            rowsScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            rowsScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            rowsScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),

            transport.centerXAnchor.constraint(equalTo: centerXAnchor),
            transport.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -26),
        ])

        rebuildRows()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func handle(_ moment: DesignSessionClock.Moment) {
        chordLabel.stringValue = moment.symbol
        chordLabel.textColor = moment.sounding ? PaperTheme.stamp : PaperTheme.ink
        timeLabel.stringValue = sessionTimeString(moment.seconds)
        countLabel.stringValue = "\(moment.rowCount) notes"
        levelLine.fraction = moment.level
        levelLine.sounding = moment.sounding
        if moment.rowCount != lastRowCount {
            lastRowCount = moment.rowCount
            rebuildRows()
        }
    }

    private func rebuildRows() {
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for row in clock.rows {
            let time = makeInkLabel(
                sessionTimeString(row.atSecond),
                font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                color: PaperTheme.secondaryInk
            )
            time.setContentCompressionResistancePriority(.required, for: .horizontal)
            let symbol = makeInkLabel(row.symbol, font: PaperTheme.displaySerif(18), color: PaperTheme.ink)
            let line = NSStackView(views: [time, symbol])
            line.orientation = .horizontal
            line.spacing = 38
            line.alignment = .firstBaseline

            let rule = HairlineView()
            let cell = NSStackView(views: [line, rule])
            cell.orientation = .vertical
            cell.alignment = .leading
            cell.spacing = 7
            rowsStack.addArrangedSubview(cell)
            // activate only once the rule shares a hierarchy with the clip view
            rule.widthAnchor.constraint(
                equalTo: rowsScroll.contentView.widthAnchor, constant: -1
            ).isActive = true
        }
    }
}
