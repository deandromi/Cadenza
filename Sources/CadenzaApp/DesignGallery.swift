import AppKit

/// The design gallery: one inspectable draft of the practice screen running a
/// simulated session. Launch with `--designs`.
@MainActor
final class DesignGalleryController: NSObject, NSApplicationDelegate {
    private let clock = DesignSessionClock()
    private var window: NSWindow?
    private var draftHandler: ((DesignSessionClock.Moment) -> Void)?

    /// Called directly from main before the run loop starts: the gallery
    /// owns its launch order, so it does not depend on the
    /// applicationDidFinishLaunching callback.
    func openGallery() {
        let draft = KeyboardBloomDraft(clock: clock)

        let newWindow = NSWindow(
            contentRect: NSRect(x: 160, y: 120, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Design draft"
        newWindow.minSize = NSSize(width: 900, height: 620)
        // every lens in the draft negotiates blending through one container,
        // the way the glass rules require
        let container = NSGlassEffectContainerView(frame: NSRect(x: 0, y: 0, width: 1080, height: 720))
        container.addSubview(draft)
        NSLayoutConstraint.activate([
            draft.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            draft.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            draft.topAnchor.constraint(equalTo: container.topAnchor),
            draft.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        newWindow.contentView = container
        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        print("[designs] draft window opened")
        fflush(stdout)

        draftHandler = draft.handle
        clock.onUpdate = { [weak self] moment in
            self?.dispatch(moment)
        }
        clock.start()
        NSApplication.shared.activate(ignoringOtherApps: true)
        print("[designs] session clock started, gallery running")
        fflush(stdout)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func dispatch(_ moment: DesignSessionClock.Moment) {
        draftHandler?(moment)
    }
}

/// The practice screen draft: the keybed along the bottom, musical notes
/// blooming in the left field while they sound, the control panel as a glass
/// lens at the right, the wordmark and a menu for future sections on top.
final class KeyboardBloomDraft: NSView {
    private let clock: DesignSessionClock
    private let keybed = KeybedView()
    private let bloom = NoteBloomView()
    private let panel: ControlPanelLens
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
        addSubview(panel)

        let wordmark = makeInkLabel(
            "Cadenza",
            font: PaperTheme.displaySerif(27, weight: .semibold),
            color: PaperTheme.ink
        )
        let logo = NSStackView(views: [wordmark, StampDot()])
        logo.orientation = .horizontal
        logo.alignment = .bottom
        logo.spacing = 7
        addSubview(logo)

        let menuLens = MenuLens()
        addSubview(menuLens)

        NSLayoutConstraint.activate([
            keybed.leadingAnchor.constraint(equalTo: leadingAnchor),
            keybed.trailingAnchor.constraint(equalTo: trailingAnchor),
            keybed.bottomAnchor.constraint(equalTo: bottomAnchor),
            keybed.heightAnchor.constraint(equalToConstant: 118),

            logo.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 38),
            logo.topAnchor.constraint(equalTo: topAnchor, constant: 22),

            menuLens.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            menuLens.topAnchor.constraint(equalTo: topAnchor, constant: 20),

            bloom.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36),
            bloom.trailingAnchor.constraint(lessThanOrEqualTo: centerXAnchor, constant: -40),
            bloom.topAnchor.constraint(equalTo: logo.bottomAnchor, constant: 8),
            bloom.bottomAnchor.constraint(equalTo: keybed.topAnchor, constant: -30),

            panel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -30),
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: centerXAnchor, constant: 30),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -26),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func handle(_ moment: DesignSessionClock.Moment) {
        keybed.soundingPitches = moment.sounding ? Set(moment.pitches) : []
        if moment.sounding, !wasSounding {
            bloom.strike(pitches: moment.pitches)
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
/// until those sections exist. The pill's fitting size is the lens' and the
/// wrapper's, so the lens never collapses.
final class MenuLens: NSView {
    private let menuButton = NSButton(title: "Menu", target: nil, action: nil)
    private let pill: NSStackView
    private let lens: NSGlassEffectView

    init() {
        menuButton.isBordered = false
        menuButton.font = .systemFont(ofSize: 13, weight: .medium)
        menuButton.contentTintColor = PaperTheme.ink
        pill = padForLens(menuButton, horizontal: 18, vertical: 12)
        lens = makeLens(style: .regular, interactive: true, cornerRadius: 20, contentView: pill)

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        menuButton.target = self
        menuButton.action = #selector(openMenu)
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

    override var intrinsicContentSize: NSSize {
        pill.fittingSize
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
/// breathing level line, and the transport, gathered in one glass lens.
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
    private let divider = HairlineView()
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

        let hearingCaption = makeInkLabel(
            "Hearing",
            font: .systemFont(ofSize: 11, weight: .medium),
            color: PaperTheme.secondaryInk
        )
        let hearing = NSStackView(views: [hearingCaption, chordLabel])
        hearing.orientation = .vertical
        hearing.alignment = .leading
        hearing.spacing = 2

        let buttons = NSStackView(views: [listenButton, recordButton, exportButton])
        buttons.orientation = .horizontal
        buttons.spacing = 20

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 11
        rows.edgeInsets = NSEdgeInsets(top: 18, left: 22, bottom: 18, right: 22)
        rows.addArrangedSubview(timeLabel)
        rows.addArrangedSubview(hearing)
        rows.addArrangedSubview(countLabel)
        rows.addArrangedSubview(levelLine)
        rows.addArrangedSubview(divider)
        rows.addArrangedSubview(buttons)
        lens = makeLens(style: .regular, interactive: true, cornerRadius: 26, contentView: rows)

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(lens)
        NSLayoutConstraint.activate([
            lens.leadingAnchor.constraint(equalTo: leadingAnchor),
            lens.trailingAnchor.constraint(equalTo: trailingAnchor),
            lens.topAnchor.constraint(equalTo: topAnchor),
            lens.bottomAnchor.constraint(equalTo: bottomAnchor),
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

    /// The panel lives by its content: without an intrinsic size the lens
    /// has no source of measure and collapses to nothing.
    override var intrinsicContentSize: NSSize {
        rows.fittingSize
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
        lens.tintColor = recording ? PaperTheme.stamp.withAlphaComponent(0.16) : nil
        recordButton.contentTintColor = recording ? PaperTheme.stamp : PaperTheme.ink
    }
}

/// The 88-key bed along the bottom: warm ivory naturals, warm ink sharps,
/// the stamp carrying whichever pitches sound right now.
final class KeybedView: NSView {
    private static let naturals = 52

    private static let ivory = NSColor(name: "cadenzaKeyIvory") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.22, alpha: 1.0)
            : NSColor(calibratedRed: 0.988, green: 0.98, blue: 0.961, alpha: 1.0)
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
        drawFallRule()
    }

    private func drawNaturals(width: CGFloat) {
        var index = 0
        for pitch in PianoRange.firstPitch...PianoRange.lastPitch where Self.isNatural(pitch) {
            let rect = NSRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height)
            Self.ivory.setFill()
            rect.fill()
            if soundingPitches.contains(pitch) {
                PaperTheme.stamp.withAlphaComponent(0.16).setFill()
                rect.fill()
            }
            index += 1
        }
    }

    private func drawSeparators(width: CGFloat) {
        PaperTheme.hairline.withAlphaComponent(0.55).setStroke()
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

    private func drawFallRule() {
        NSColor(calibratedWhite: 0, alpha: 0.03).setFill()
        NSRect(x: 0, y: bounds.height - 3, width: bounds.width, height: 3).fill()
    }

    private static func isNatural(_ pitch: Int) -> Bool {
        [0, 2, 4, 5, 7, 9, 11].contains(pitch % 12)
    }
}

/// One blooming musical note: the system music-note symbol rendered large,
/// tinted stamp while it sounds and warm ink once released, resting on a
/// whisper of shadow.
final class NoteGlyphView: NSView {
    enum Phase {
        case sounding
        case released
    }

    private static let symbol = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Note")

    init(height: CGFloat, rotation: CGFloat) {
        let configured = Self.symbol?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: height, weight: .regular)
        )
        let size = configured?.size ?? NSSize(width: height * 0.75, height: height)
        let aspect = size.width / max(size.height, 1)
        super.init(frame: NSRect(x: 0, y: 0, width: height * aspect, height: height))
        frameRotation = rotation
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var phase: Phase = .sounding {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let base = Self.symbol else { return }
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.10)
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        let ink: NSColor = phase == .sounding ? PaperTheme.stamp : PaperTheme.ink
        let image = base.withSymbolConfiguration(
            NSImage.SymbolConfiguration(paletteColors: [ink])
        ) ?? base
        image.draw(in: bounds)
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

/// Where playing becomes visible: one large musical note per sounding pitch,
/// falling into the field in a soft cascade, drifting up gently while the
/// chord holds, then dissolving out of the paper. Bass left, treble right,
/// mirroring the keybed, sizes and tilts varied so the field breathes.
final class NoteBloomView: NSView {
    private struct Petal {
        let glyph: NoteGlyphView
        let x: CGFloat
        let yBase: CGFloat
        let spawnAt: Double
        var releaseAt: Double?
    }

    private static let maxPetals = 30
    private static let tickInterval = 1.0 / 30.0
    private static let appearOver = 0.7
    private static let fadeOver = 2.6
    private static let cascadeStep = 0.09
    private static let riseWhileHeld = 9.0
    private static let riseAfterRelease = 11.0

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

    /// Spawns one note per pitch of a freshly struck chord, cascading.
    func strike(pitches: [Int]) {
        startTimerIfNeeded()
        for (offset, pitch) in pitches.enumerated() {
            let glyph = NoteGlyphView(
                height: Self.glyphHeight(pitch, in: bounds.height),
                rotation: Self.rotation(pitch)
            )
            glyph.alphaValue = 0
            addSubview(glyph)
            petals.append(Petal(
                glyph: glyph,
                x: Self.glyphX(pitch, in: bounds.width),
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

            petal.glyph.alphaValue = CGFloat(0.95 * appear * fade)
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

    /// Notes run from a fifth to close to half the field, by pitch.
    private static func glyphHeight(_ pitch: Int, in height: CGFloat) -> CGFloat {
        let variance = Double((pitch * 13) % 7) * 0.027
        return CGFloat(Double(height) * (0.22 + variance))
    }

    /// Pitch mirrored across the field the way the keybed lays it out, using
    /// nearly the full width.
    private static func glyphX(_ pitch: Int, in width: CGFloat) -> CGFloat {
        let fraction = Double(pitch - PianoRange.firstPitch)
            / Double(PianoRange.lastPitch - PianoRange.firstPitch)
        return CGFloat(Double(width) * (0.08 + 0.84 * fraction))
    }

    private static func glyphY(_ pitch: Int, in height: CGFloat) -> CGFloat {
        let spread = Double((pitch * 31) % 100) / 100
        return CGFloat(Double(height) * (0.08 + 0.24 * spread))
    }

    private static func rotation(_ pitch: Int) -> CGFloat {
        CGFloat((pitch * 29) % 13 - 6)
    }
}
