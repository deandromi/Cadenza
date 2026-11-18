import AppKit

/// The design gallery: one inspectable draft of the practice screen running a
/// simulated session. Launch with `--designs`; add `--designs-shot` to print
/// a layout report with pixel probes and exit instead of staying open.
@MainActor
final class DesignGalleryController: NSObject, NSApplicationDelegate {
    private let clock = DesignSessionClock()
    private var window: NSWindow?
    private var draft: KeyboardBloomDraft?

    /// The gallery builds inside applicationDidFinishLaunching, the same
    /// lifecycle the working main app uses: a window built before the run
    /// loop starts never joins the live layout engine, and its nested
    /// views stay at zero frames forever.
    func applicationDidFinishLaunching(_ notification: Notification) {
        openGallery()
    }

    /// Cell test: window, frame-driven root, one pinned stack with one
    /// button. If the button renders, the engine lives and the poison is
    /// somewhere in the real gallery tree.
    /// Assembles the window and starts the simulated session; called from
    /// applicationDidFinishLaunching once the run loop owns the app.
    func openGallery() {
        // the gallery is a paper world: it always renders in light mode,
        // whatever the system prefers
        NSApplication.shared.appearance = NSAppearance(named: .aqua)

        let newDraft = KeyboardBloomDraft(clock: clock)
        draft = newDraft

        let newWindow = NSWindow(
            contentRect: NSRect(x: 160, y: 120, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Design draft"
        newWindow.minSize = NSSize(width: 900, height: 620)
        // the window's content is a frame-driven root with autoresizing,
        // exactly like the working main app: a constraint-pinned content
        // view breaks the deeper layout passes on this OS build
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1080, height: 720))
        root.autoresizingMask = [.width, .height]
        newWindow.contentView = root
        root.addSubview(newDraft)
        NSLayoutConstraint.activate([
            newDraft.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            newDraft.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            newDraft.topAnchor.constraint(equalTo: root.topAnchor),
            newDraft.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window = newWindow
        window?.makeKeyAndOrderFront(nil)
        print("[designs] draft window opened")
        fflush(stdout)

        clock.onUpdate = { [weak self] moment in
            self?.draft?.handle(moment)
        }
        clock.start()
        NSApplication.shared.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--designs-shot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                self?.shoot()
            }
        }
        print("[designs] session clock started, gallery running")
        fflush(stdout)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Probes inside the panel where label and button ink should be.
    private func draftingPanelContentProbes() -> [KeyboardBloomDraft.PixelProbe] {
        [
            KeyboardBloomDraft.PixelProbe(label: "panel caption row", point: NSPoint(x: 838, y: 470)),
            KeyboardBloomDraft.PixelProbe(label: "panel time digits", point: NSPoint(x: 840, y: 440)),
            KeyboardBloomDraft.PixelProbe(label: "panel level line", point: NSPoint(x: 940, y: 360)),
            KeyboardBloomDraft.PixelProbe(label: "panel buttons row", point: NSPoint(x: 845, y: 292)),
            KeyboardBloomDraft.PixelProbe(label: "menu buttons", point: NSPoint(x: 992, y: 680)),
            KeyboardBloomDraft.PixelProbe(label: "bloom staff wash", point: NSPoint(x: 260, y: 380)),
        ]
    }

    /// Layout report plus pixel probes over the captured draft, written to
    /// the gallery log. Nothing is trusted until the pixels say so.
    private func shoot() {
        print("[shot] --- layout report ---")
        if let theWindow = window {
            print("[shot] window frame \(theWindow.frame)")
            if let content = theWindow.contentView {
                print("[shot] content view frame \(content.frame)")
            }
        }
        draft?.reportLayout()
        guard let contentView = window?.contentView else {
            print("[shot] no content view")
            fflush(stdout)
            exit(0)
        }
        let bounds = contentView.bounds
        guard let bitmap = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            print("[shot] no bitmap")
            fflush(stdout)
            exit(0)
        }
        contentView.cacheDisplay(in: bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "/tmp/cadenza_draft.png"))
            print("[shot] png written to /tmp/cadenza_draft.png (\(png.count) bytes)")
        }
        /// view coordinates are bottom-up, bitmap rows run top-down
        func sample(_ point: NSPoint) -> String {
            let x = Int(point.x)
            let y = Int(bitmap.pixelsHigh) - 1 - Int(point.y)
            if x < 0 || y < 0 || x >= Int(bitmap.pixelsWide) || y >= Int(bitmap.pixelsHigh) {
                return "out of bounds"
            }
            guard let color = bitmap.colorAt(x: x, y: y) else { return "no color" }
            return String(
                format: "(%.3f %.3f %.3f)",
                color.redComponent, color.greenComponent, color.blueComponent
            )
        }
        print("[shot] paper reference at (60, 640): \(sample(NSPoint(x: 60, y: 640)))")
        for probe in draftingPanelContentProbes() {
            print("[shot] probe \(probe.label) at \(Int(probe.point.x)),\(Int(probe.point.y)): \(sample(probe.point))")
        }
        for probe in draft?.pixelProbes() ?? [] {
            print("[shot] probe \(probe.label) at \(Int(probe.point.x)),\(Int(probe.point.y)): \(sample(probe.point))")
        }
        print("[shot] --- end ---")
        fflush(stdout)
        exit(0)
    }
}

/// The practice screen draft: the keybed along the bottom, musical notes
/// blooming in the left field while they sound, the control panel as a glass
/// lens at the right, the wordmark and a menu for future sections on top.
/// The draft is the window's content; the lenses sit far apart, so the glass
/// contract asks for no container and the window keeps its given size.
final class KeyboardBloomDraft: NSView {
    private let clock: DesignSessionClock
    private let keybed = KeybedView()
    private let bloom = NoteBloomView()
    private let panel: ControlPanelLens
    private let menuLens = MenuLens()
    private let wordmark = makeInkLabel(
        "Cadenza",
        font: PaperTheme.displaySerif(27, weight: .semibold),
        color: PaperTheme.ink
    )
    private var wasSounding = false

    init(clock: DesignSessionClock) {
        self.clock = clock
        panel = ControlPanelLens(clock: clock)
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
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func handle(_ moment: DesignSessionClock.Moment) {
        keybed.soundingPitches = moment.sounding ? Set(moment.pitches) : []
        if moment.sounding, !wasSounding {
            bloom.strike(pitches: moment.pitches, serial: moment.noteCount)
        }
        if !moment.sounding, wasSounding {
            bloom.releaseAll()
        }
        wasSounding = moment.sounding
        panel.setSession(
            time: sessionTimeString(moment.seconds),
            chord: moment.symbol,
            notes: "\(moment.noteCount) notes",
            level: moment.level,
            sounding: moment.sounding
        )
    }

    // MARK: shot diagnostics

    func reportLayout() {
        print("[shot] draft bounds \(bounds.width)x\(bounds.height)")
        print("[shot] draft fitting \(fittingSize)")
        subviews.forEach { child in
            print("[shot] child \(type(of: child)) frame \(child.frame), fitting \(child.fittingSize)")
        }
        print("[shot] keybed frame \(keybed.frame)")
        print("[shot] bloom frame \(bloom.frame)")
        print("[shot] wordmark frame \(wordmark.frame)")
        print("[shot] panel frame \(panel.frame), intrinsic \(panel.intrinsicContentSize)")
        print("[shot] menu frame \(menuLens.frame), intrinsic \(menuLens.intrinsicContentSize)")
        panel.reportLayout(prefix: "[shot] ")
    }

    struct PixelProbe {
        let label: String
        let point: NSPoint
    }

    /// Probes the panel and keybed regions inside draft coordinates.
    func pixelProbes() -> [PixelProbe] {
        let panelFrame = panel.frame
        let inset = min(panelFrame.width, panelFrame.height) / 4
        return [
            PixelProbe(label: "panel center", point: NSPoint(
                x: panelFrame.midX, y: panelFrame.midY
            )),
            PixelProbe(label: "panel inside corner", point: NSPoint(
                x: panelFrame.minX + inset, y: panelFrame.minY + inset
            )),
            PixelProbe(label: "keybed midway", point: NSPoint(
                x: bounds.width / 2, y: keybed.frame.midY
            )),
        ]
    }
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

/// Top-right glass pill opening the menu of future sections, shown disabled
/// until those sections exist. The lens is pure backdrop; the pill renders
/// through the regular subview chain on top of it.
final class MenuLens: NSView {
    private let menuButton = NSButton(title: "Menu", target: nil, action: nil)
    private var pill: NSStackView?
    private var backdrop: NSView?

    init() {
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
        let newBackdrop = NSView()
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
        for title in ["Sheet music", "Sessions", "MIDI routing", "Settings"] {
            menu.addItem(withTitle: title, action: nil, keyEquivalent: "").isEnabled = false
        }
        // items stay disabled: the sections are future work, the menu shows
        // where they will live
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: menuButton.bounds.minY - 8), in: menuButton)
    }
}

/// The control panel: the session's numbers, the chord being heard, the
/// breathing level line, and the transport, gathered in one glass lens. The
/// lens is pure backdrop; the rows render through the regular subview chain
/// on top of it, so the panel can never collapse into nothing.
final class ControlPanelLens: NSView {
    private let clock: DesignSessionClock
    private let rows = NSStackView()
    private let timeLabel = makeInkLabel(
        "0:47",
        font: .monospacedDigitSystemFont(ofSize: 19, weight: .regular),
        color: PaperTheme.ink
    )
    private let chordLabel = makeInkLabel(
        "C",
        font: PaperTheme.displaySerif(24),
        color: PaperTheme.secondaryInk
    )
    private let countLabel = makeInkLabel(
        "10 notes",
        font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular),
        color: PaperTheme.secondaryInk
    )
    private let levelLine = LevelLineView()
    private let listenButton = NSButton(title: "Listen", target: nil, action: nil)
    private let recordButton = NSButton(title: "Record", target: nil, action: nil)
    private let exportButton = NSButton(title: "Export", target: nil, action: nil)
    private let backdrop: NSView
    private var recording = false

    init(clock: DesignSessionClock) {
        self.clock = clock
        backdrop = NSView()

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // views and their relationships are built only after super.init on
        // this OS build: mutation before it orphans subtrees from the live
        // layout engine
        for button in [listenButton, recordButton, exportButton] {
            button.isBordered = false
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.contentTintColor = PaperTheme.ink
        }
        exportButton.isEnabled = false

        // on this OS build, pinning a view never auto-disables its
        // autoresizing mask: do it by hand or the view stays at zero
        rows.translatesAutoresizingMaskIntoConstraints = false
        backdrop.translatesAutoresizingMaskIntoConstraints = false

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 12
        rows.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        let divider = HairlineView()
        let buttons = NSStackView(views: [listenButton, recordButton, exportButton])
        buttons.orientation = .horizontal
        buttons.spacing = 20
        addSubview(backdrop)
        addSubview(rows)
        rows.addArrangedSubview(Self.captionedRow("Session", timeLabel))
        rows.addArrangedSubview(Self.captionedRow("Hearing", chordLabel))
        rows.addArrangedSubview(Self.captionedRow("Notes so far", countLabel))
        rows.addArrangedSubview(Self.captionedRow("Level", levelLine))
        rows.addArrangedSubview(divider)
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
            levelLine.widthAnchor.constraint(equalToConstant: 216),
            divider.widthAnchor.constraint(equalToConstant: 216),
        ])

        listenButton.target = self
        listenButton.action = #selector(toggleListening)
        recordButton.target = self
        recordButton.action = #selector(toggleRecording)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Caption over value, the panel's rhythm.
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
        return stack
    }

    /// The panel lives by its content: the rows are a direct subview, so
    /// their fitting size is the panel's intrinsic size.
    override var intrinsicContentSize: NSSize {
        rows.fittingSize
    }

    func reportLayout(prefix: String) {
        print("\(prefix)panel rows frame \(rows.frame)")
        for case let row as NSStackView in rows.arrangedSubviews {
            print("\(prefix)panel row \(row.frame)")
        }
        print("\(prefix)panel time label \(timeLabel.frame)")
    }

    func setSession(time: String, chord: String, notes: String, level: Double, sounding: Bool) {
        timeLabel.stringValue = time
        chordLabel.stringValue = chord
        chordLabel.textColor = sounding ? PaperTheme.stamp : PaperTheme.secondaryInk
        countLabel.stringValue = notes
        levelLine.fraction = level
        levelLine.sounding = sounding
    }

    @objc private func toggleListening() {
        clock.toggleRunning()
        listenButton.title = clock.isRunning ? "Stop" : "Listen"
    }

    @objc private func toggleRecording() {
        recording.toggle()
        recordButton.contentTintColor = recording ? PaperTheme.stamp : PaperTheme.ink
    }
}

/// The 88-key bed along the bottom: warm ivory naturals, warm ink sharps,
/// the stamp carrying whichever pitches sound right now, red felt across the
/// top the way a real piano wears it.
final class KeybedView: NSView {
    private static let naturals = 52
    private static let feltHeight: CGFloat = 5

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
        drawNaturals(width: naturalWidth)
        drawSeparators(width: naturalWidth)
        drawAccidentals(width: naturalWidth)
        drawFelt()
    }

    private func drawNaturals(width: CGFloat) {
        let keyHeight = bounds.height
        var index = 0
        for pitch in PianoRange.firstPitch...PianoRange.lastPitch where Self.isNatural(pitch) {
            let rect = NSRect(x: CGFloat(index) * width, y: 0, width: width, height: keyHeight)
            Self.ivory.setFill()
            rect.fill()
            if soundingPitches.contains(pitch) {
                PaperTheme.stamp.withAlphaComponent(0.16).setFill()
                rect.fill()
            }
            // key bevel: a shaded foot gives each key depth
            Self.ivoryShade.setFill()
            NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 3).fill()
            index += 1
        }
    }

    private func drawSeparators(width: CGFloat) {
        PaperTheme.hairline.withAlphaComponent(0.6).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        for index in 1...Self.naturals - 1 {
            let x = CGFloat(index) * width
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x, y: bounds.height))
        }
        path.stroke()
    }

    private func drawAccidentals(width: CGFloat) {
        let accidentalWidth = width * 0.58
        let accidentalHeight = bounds.height * 0.62
        var naturalsPassed = 0
        for pitch in PianoRange.firstPitch...PianoRange.lastPitch {
            if Self.isNatural(pitch) {
                naturalsPassed += 1
                continue
            }
            // each accidental rides the boundary its natural just left
            let center = CGFloat(naturalsPassed) * width
            let rect = NSRect(
                x: center - accidentalWidth / 2,
                y: bounds.height - accidentalHeight,
                width: accidentalWidth,
                height: accidentalHeight
            )
            Self.ebony.setFill()
            rect.fill()
            if soundingPitches.contains(pitch) {
                PaperTheme.stamp.withAlphaComponent(0.85).setFill()
                rect.fill()
            }
            PaperTheme.hairline.withAlphaComponent(0.4).setStroke()
            NSBezierPath(rect: rect).stroke()
        }
    }

    /// The red felt strip across the top of the keys.
    private func drawFelt() {
        let felt = NSRect(x: 0, y: bounds.height - Self.feltHeight, width: bounds.width, height: Self.feltHeight)
        PaperTheme.stamp.withAlphaComponent(0.5).setFill()
        felt.fill()
        NSColor(calibratedWhite: 0, alpha: 0.08).setFill()
        NSRect(x: felt.minX, y: felt.minY - 2, width: felt.width, height: 2).fill()
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
