import AppKit
import CadenzaCore
import QuartzCore

/// The endless measure: a grand-staff band across the practice screen.
/// Notation flows in at the now line as the transcription pipeline confirms
/// it, and keeps drifting left while the next notes take its place: a
/// running portrait of what was just played, in real notation, on paper.
///
/// Time on this view is publication time, not performance time: a note
/// lands on the now line the moment the pipeline reports it and slides
/// away left like everything else, so the freshest musical ink is always
/// at the same place on the screen.
@MainActor
final class EndlessStaffView: NSView {
    // Bravura glyphs this strip engraves with
    private enum Glyph {
        static let gClef: UInt32 = 0xE050
        static let fClef: UInt32 = 0xE062
        static let noteheadBlack: UInt32 = 0xE0A4
        static let accidentalSharp: UInt32 = 0xE262
        static let accidentalFlat: UInt32 = 0xE260
        static let accidentalNatural: UInt32 = 0xE261
    }

    private struct StripNote {
        let pitch: Int
        /// wall-clock seconds at publication, the zero of this view's time
        let bornAt: Double
        /// wall-clock seconds when the key released, nil while sounding
        var releasedAt: Double?
    }

    /// staff line gap, the vertical unit of the whole strip
    private let gap: CGFloat = 7.5
    /// how fast notation travels left, in points per second
    private let pixelsPerSecond: CGFloat = 78
    /// the clear zone a fresh note needs before the panel edge
    private let rightMargin: CGFloat = 46

    private var notes: [StripNote] = []
    private var displayTimer: Timer?
    /// the lens hovers: the playhead warms up
    var nowLineHighlighted: Bool = false {
        didSet { needsDisplay = true }
    }
    /// the measure is pressed: the playhead carries the stamp for a beat
    var pressed: Bool = false {
        didSet { needsDisplay = true }
    }

    /// The now line rides at this x: fresh notes arrive at or left of it.
    private var nowX: CGFloat { bounds.width - rightMargin }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // pinned by constraints in the practice screen: without this the
        // autoresizing mask fights the layout engine and drags the window
        // frame down with it
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The strip's geometry runs top down, like reading notation off paper.
    override var isFlipped: Bool { true }

    // MARK: the pipeline feeds the strip

    /// A note was confirmed: it engraved itself at the now line.
    func noteStruck(pitch: Int) {
        noteStruck(pitch: pitch, age: 0)
    }

    /// The same strike, placed `age` seconds back in the strip's past -
    /// the shape a note has some time after the pipeline confirmed it.
    func noteStruck(pitch: Int, age: Double) {
        guard (21...108).contains(pitch) else { return }
        notes.append(StripNote(pitch: pitch, bornAt: CACurrentMediaTime() - age, releasedAt: nil))
        startClock()
        needsDisplay = true
    }

    /// The key rose: the note's ink settles into its released shade.
    func noteReleased(pitch: Int) {
        let stamp = CACurrentMediaTime()
        for index in notes.indices.reversed() where notes[index].pitch == pitch && notes[index].releasedAt == nil {
            notes[index].releasedAt = stamp
            break
        }
        needsDisplay = true
    }

    /// The session ends: the strip becomes blank paper again.
    func clear() {
        notes = []
        needsDisplay = true
    }

    // MARK: animation clock

    private func startClock() {
        guard displayTimer == nil else { return }
        displayTimer = Clock.every(1.0 / 30.0) { [weak self] in self?.tick() }
    }

    private func stopClock() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func tick() {
        needsDisplay = true
        // let the clock rest once every note has drifted off the paper
        let horizon = CACurrentMediaTime() - Double(bounds.width + 80) / Double(pixelsPerSecond)
        if notes.last?.bornAt ?? 0 < horizon {
            notes.removeAll { $0.bornAt < horizon }
            if notes.isEmpty { stopClock() }
        }
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 40, bounds.height > 60 else { return }
        let ink = self.ink
        let now = CACurrentMediaTime()
        let nowPoint = nowX

        // the staff system, centered: treble on top, bass below
        let systemHeight = 4 * gap + 3.2 * gap + 4 * gap
        let top = max((bounds.height - systemHeight) / 2, 8)
        let trebleBottom = top + 4 * gap
        let bassTop = trebleBottom + 3.2 * gap
        let bassBottom = bassTop + 4 * gap

        func yOnTreble(_ position: Int) -> CGFloat { trebleBottom - CGFloat(position) * gap / 2 }
        func yOnBass(_ position: Int) -> CGFloat { bassBottom - CGFloat(position) * gap / 2 }

        // staff lines fade toward both edges: notation breathes, the paper
        // underneath never changes. One path for all ten of them.
        ink.line.setStroke()
        let staff = NSBezierPath()
        for line in 0...4 {
            let y1 = top + CGFloat(line) * gap
            let y2 = bassTop + CGFloat(line) * gap
            staff.move(to: NSPoint(x: 0, y: y1))
            staff.line(to: NSPoint(x: bounds.width, y: y1))
            staff.move(to: NSPoint(x: 0, y: y2))
            staff.line(to: NSPoint(x: bounds.width, y: y2))
        }
        staff.lineWidth = 0.8
        staff.stroke()

        // clefs hold their post at the strip's left edge
        let clefX: CGFloat = 8
        drawGlyph(Glyph.gClef, baselineAt: NSPoint(x: clefX, y: yOnTreble(2)), font: musicFont, color: ink.clef)
        drawGlyph(Glyph.fClef, baselineAt: NSPoint(x: clefX, y: yOnBass(6)), font: musicFont, color: ink.clef)

        // the now line: where the pipeline's freshest word lands. Resting
        // warm under the pointer, stamp while pressed - the lens breathes
        let nowLine = pressed ? ink.nowStamp : nowLineHighlighted ? ink.nowWarm : ink.nowCalm
        nowLine.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: nowPoint, y: top - 7))
        path.line(to: NSPoint(x: nowPoint, y: bassBottom + 7))
        path.lineWidth = 1
        path.stroke()

        // ledgers and stems accumulate: one stroke each for the whole strip
        // instead of two bezier paths per note per frame
        let ledgers = NSBezierPath()
        let soundingStems = NSBezierPath()
        let releasedStems = NSBezierPath()

        let horizon = now - Double(bounds.width + 80) / Double(pixelsPerSecond)
        for note in notes where note.bornAt >= horizon {
            let age = CGFloat(now - note.bornAt)
            let x = nowPoint - age * pixelsPerSecond
            let sounding = note.releasedAt == nil

            let treble = ScoreLayout.isTreble(note.pitch)
            let position = treble ? ScoreLayout.treblePosition(note.pitch) : ScoreLayout.bassPosition(note.pitch)
            let cy = treble ? yOnTreble(position) : yOnBass(position)

            // accidentals in front of the head
            if let (codepoint, width) = accidental(for: note.pitch) {
                drawGlyph(codepoint, baselineAt: NSPoint(x: x - width - 0.7 * gap, y: cy),
                          font: musicFont,
                          color: sounding ? ink.accidentalOn : ink.accidentalOff)
            }

            // ledger lines beyond the staff
            if position < 0 || position > 8 {
                var p = position < 0 ? -2 : 10
                while position < 0 ? p >= position : p <= position {
                    let y = treble ? yOnTreble(p) : yOnBass(p)
                    ledgers.move(to: NSPoint(x: x - 1.35 * gap, y: y))
                    ledgers.line(to: NSPoint(x: x + 1.35 * gap, y: y))
                    p += position < 0 ? -2 : 2
                }
            }

            // the head
            drawGlyph(Glyph.noteheadBlack, baselineAt: NSPoint(x: x - headWidth / 2, y: cy),
                      font: musicFont, color: sounding ? ink.headOn : ink.headOff)

            // the stem: up below the staff's middle line, down above it
            let stemUp = position < 4
            let stemX = stemUp ? x + 0.5 * gap : x - 0.5 * gap
            let startDistance: CGFloat = 0.5
            let endpoint = stemUp ? cy - 3.25 * gap : cy + 3.25 * gap
            let stem = sounding ? soundingStems : releasedStems
            stem.move(to: NSPoint(x: stemX, y: cy + (stemUp ? startDistance : -startDistance)))
            stem.line(to: NSPoint(x: stemX, y: endpoint))
        }

        if !ledgers.isEmpty {
            ink.line.setStroke()
            ledgers.lineWidth = 0.8
            ledgers.stroke()
        }
        let stemWidth = 0.55 * gap / 4
        if !soundingStems.isEmpty {
            ink.headOn.setStroke()
            soundingStems.lineWidth = stemWidth
            soundingStems.stroke()
        }
        if !releasedStems.isEmpty {
            ink.headOff.setStroke()
            releasedStems.lineWidth = stemWidth
            releasedStems.stroke()
        }
    }

    /// Ink shades and glyph metrics, resolved once: the strip redraws thirty
    /// times a second and used to rebuild both on every frame.
    private struct Ink {
        let line: NSColor
        let clef: NSColor
        let nowCalm: NSColor
        let nowWarm: NSColor
        let nowStamp: NSColor
        let headOn: NSColor
        let headOff: NSColor
        let accidentalOn: NSColor
        let accidentalOff: NSColor
    }

    private lazy var ink = Ink(
        line: PaperTheme.ink.withAlphaComponent(0.42),
        clef: PaperTheme.ink.withAlphaComponent(0.8),
        nowCalm: PaperTheme.ink.withAlphaComponent(0.30),
        nowWarm: PaperTheme.ink.withAlphaComponent(0.6),
        nowStamp: PaperTheme.stamp,
        headOn: PaperTheme.ink,
        headOff: PaperTheme.ink.withAlphaComponent(0.55),
        accidentalOn: PaperTheme.ink.withAlphaComponent(0.85),
        accidentalOff: PaperTheme.ink.withAlphaComponent(0.85 * 0.55)
    )

    /// Glyph metrics of the four shapes the strip engraves, measured once at
    /// its own size; a dictionary lookup per note per frame added up.
    private struct Metrics {
        let headWidth: CGFloat
        let sharpWidth: CGFloat
        let flatWidth: CGFloat
        let naturalWidth: CGFloat
    }

    private lazy var metrics: Metrics = {
        let fontSize = self.fontSize
        func width(_ codepoint: UInt32, fallback: CGFloat) -> CGFloat {
            MusicFont.info(codepoint).map { $0.width * fontSize } ?? fallback
        }
        return Metrics(
            headWidth: width(Glyph.noteheadBlack, fallback: 1.18 * gap),
            sharpWidth: width(Glyph.accidentalSharp, fallback: gap),
            flatWidth: width(Glyph.accidentalFlat, fallback: gap),
            naturalWidth: width(Glyph.accidentalNatural, fallback: gap)
        )
    }()

    private var headWidth: CGFloat { metrics.headWidth }

    /// The accidental a black key needs, and how far in front of the head it
    /// sits. Natural pitches carry none.
    private func accidental(for pitch: Int) -> (UInt32, CGFloat)? {
        switch ScoreLayout.accidental(for: pitch, fifths: 0) {
        case .sharp: return (Glyph.accidentalSharp, metrics.sharpWidth)
        case .flat: return (Glyph.accidentalFlat, metrics.flatWidth)
        case .natural: return (Glyph.accidentalNatural, metrics.naturalWidth)
        case .none: return nil
        }
    }

    private var fontSize: CGFloat { gap * 4 }

    /// Built once: creating a CTFont per draw was allocating thousands of
    /// font objects a second on the strip's 30 Hz clock.
    private let musicFont = MusicFont.ctFont(size: 7.5 * 4)

    private func strokeHorizontal(_ y: CGFloat) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: y))
        path.line(to: NSPoint(x: bounds.width, y: y))
        path.lineWidth = 0.8
        path.stroke()
    }

    /// Draws one music glyph with its SMuFL baseline exactly at the anchor
    /// point, upright inside the flipped view.
    private func drawGlyph(_ codepoint: UInt32, baselineAt point: NSPoint, font: CTFont, color: NSColor) {
        guard let info = MusicFont.info(codepoint) else { return }
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        color.setFill()
        cg.saveGState()
        cg.translateBy(x: point.x, y: point.y)
        cg.scaleBy(x: 1, y: -1)
        var glyph = info.glyph
        var origin = CGPoint.zero
        CTFontDrawGlyphs(font, &glyph, &origin, 1, cg)
        cg.restoreGState()
    }
}


/// The endless measure wrapped in a living glass lens: the notation rides on
/// liquid glass like the panel and menu do, the lens is interactive the way
/// the system intends, hovering brightens the playhead, and a click opens
/// the engraved sheet of everything the session has played.
@MainActor
final class StaffLensView: NSView {
    private let backdrop: NSGlassEffectView
    private let strip = EndlessStaffView()
    private let onOpen: () -> Void
    private var hover: Bool = false

    init(onOpen: @escaping () -> Void) {
        self.onOpen = onOpen
        backdrop = NSGlassEffectView()
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // the lens is backdrop material only: the measure is a guarantee of
        // its own drawing path, so it stays a sibling above the glass rather
        // than becoming the lens's contentView
        backdrop.style = .regular
        backdrop.cornerRadius = LensRadius.staff
        setGlassInteractive(backdrop, true)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)
        addSubview(strip)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            strip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            strip.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            strip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var stripView: EndlessStaffView { strip }

    // the hover state reads in the playhead: the now line warms while the
    // pointer rests on the measure
    var isHovered: Bool {
        get { hover }
        set {
            guard hover != newValue else { return }
            hover = newValue
            strip.nowLineHighlighted = newValue
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.userInfo?["staff"] != nil {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: ["staff": true]
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        // the press speaks once: the playhead pins itself stamp for a beat
        strip.pressed = true
        onOpen()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 160_000_000)
            strip.pressed = false
        }
    }
}
