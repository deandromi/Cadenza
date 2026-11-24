import AppKit
import CadenzaCore

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
        timer = Clock.every(Self.tickInterval) { [weak self] in self?.tick() }
    }

    private func tick() {
        elapsed += Self.tickInterval
        // backwards, so a faded note can leave the field mid-pass without
        // disturbing an index still to be visited
        var index = petals.count - 1
        while index >= 0 {
            let petal = petals[index]
            let age = elapsed - petal.spawnAt
            let appear = Self.smoothstep(min(1, max(0, age / Self.appearOver)))
            let fade = petal.releaseAt.map { 1 - min(1, (elapsed - $0) / Self.fadeOver) } ?? 1
            let driftAfterRelease = petal.releaseAt.map {
                Self.riseAfterRelease * (elapsed - $0)
            } ?? 0
            let rise = Self.riseWhileHeld * max(0, age) + driftAfterRelease

            if fade <= 0 {
                petals.remove(at: index).glyph.removeFromSuperview()
            } else {
                petal.glyph.alphaValue = CGFloat(0.98 * appear * fade)
                petal.glyph.setFrameOrigin(NSPoint(
                    x: petal.x - petal.glyph.bounds.width / 2,
                    y: petal.yBase + CGFloat(rise)
                ))
            }
            index -= 1
        }
        // an empty field has nothing left to animate: park the clock instead
        // of waking the run loop thirty times a second for the rest of the
        // app's life
        if petals.isEmpty {
            timer?.invalidate()
            timer = nil
            elapsed = 0
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
        let fraction = Double(pitch - PianoKeyboard.firstPitch)
            / Double(PianoKeyboard.lastPitch - PianoKeyboard.firstPitch)
        let jitter = Double((pitch * 53 + serial * 97) % 33 - 16)
        return CGFloat(Double(width) * (0.09 + 0.78 * fraction) + jitter)
    }

    /// Notation logic: high pitches bloom high, low pitches near the keys.
    private static func glyphY(_ pitch: Int, in height: CGFloat) -> CGFloat {
        let fraction = Double(pitch - PianoKeyboard.firstPitch)
            / Double(PianoKeyboard.lastPitch - PianoKeyboard.firstPitch)
        return CGFloat(Double(height) * (0.10 + 0.42 * fraction))
    }

    private static func rotation(_ pitch: Int, serial: Int) -> CGFloat {
        CGFloat((pitch * 29 + serial * 11) % 13 - 6)
    }
}
