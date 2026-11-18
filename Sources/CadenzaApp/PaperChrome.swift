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

/// Top-right glass pill opening the menu of future sections, shown disabled
/// until those sections exist. The lens is a pure glass backdrop; the pill
/// renders through the regular subview chain on top of it.
final class MenuLens: NSView {
    private let menuButton = NSButton(title: "Menu", target: nil, action: nil)
    private var pill: NSStackView?
    private var backdrop: NSView?
    private let menuItems = ["Sheet music", "Sessions", "MIDI routing", "Settings"]

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
            menu.addItem(withTitle: title, action: nil, keyEquivalent: "").isEnabled = false
        }
        // items stay disabled: the sections are future work, the menu shows
        // where they will live
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: menuButton.bounds.minY - 8), in: menuButton)
    }
}

/// The control panel: the session's numbers, the chord being heard, the
/// breathing level line, and the transport, gathered in one glass lens. The
/// lens is a pure glass backdrop; the rows render through the regular
/// subview chain on top of it, so the panel can never collapse into nothing.
final class ControlPanelLens: NSView {
    private let transport: PanelTransport
    private let rows = NSStackView()
    private let timeLabel = makeInkLabel(
        "0:00",
        font: .monospacedDigitSystemFont(ofSize: 19, weight: .regular),
        color: PaperTheme.ink
    )
    private let chordLabel = makeInkLabel(
        "—",
        font: PaperTheme.displaySerif(24),
        color: PaperTheme.secondaryInk
    )
    private let countLabel = makeInkLabel(
        "0 notes",
        font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular),
        color: PaperTheme.secondaryInk
    )
    private let levelLine = LevelLineView()
    private let listenButton = NSButton(title: "Listen", target: nil, action: nil)
    private let exportButton = NSButton(title: "Export", target: nil, action: nil)
    private let backdrop: NSGlassEffectView

    init(transport: PanelTransport) {
        self.transport = transport
        backdrop = makeGlassBackdrop(cornerRadius: 18, interactive: true)

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // views and their relationships are built only after super.init on
        // this OS build: mutation before it orphans subtrees from the live
        // layout engine
        for button in [listenButton, exportButton] {
            button.isBordered = false
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.contentTintColor = PaperTheme.ink
        }

        // on this OS build, pinning a view never auto-disables its
        // autoresizing mask: do it by hand or the view stays at zero
        rows.translatesAutoresizingMaskIntoConstraints = false
        backdrop.translatesAutoresizingMaskIntoConstraints = false

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 12
        rows.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        let divider = HairlineView()
        let buttons = NSStackView(views: [listenButton, exportButton])
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
        listenButton.action = #selector(listenTapped)
        exportButton.target = self
        exportButton.action = #selector(exportTapped)
        syncTransport()
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

    /// Rereads the transport after the owner's state changed out from
    /// under the button: the session's title is Stop while it runs, and
    /// the stamp tint carries that running state.
    func syncTransport() {
        let listening = transport.isListening()
        listenButton.title = listening ? "Stop" : "Listen"
        listenButton.contentTintColor = listening ? PaperTheme.stamp : PaperTheme.ink
        exportButton.isEnabled = transport.exportEnabled()
    }

    func setSession(time: String, chord: String, notes: String, level: Double, sounding: Bool) {
        timeLabel.stringValue = time
        chordLabel.stringValue = chord
        chordLabel.textColor = sounding ? PaperTheme.stamp : PaperTheme.secondaryInk
        countLabel.stringValue = notes
        levelLine.setFractionTarget(level)
        levelLine.sounding = sounding
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
            ("panel chord", inLens(chordLabel)),
            ("panel count", inLens(countLabel)),
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
