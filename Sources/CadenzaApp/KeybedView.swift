import AppKit
import CadenzaCore

/// The keybed at the foot of the practice screen, drawn as a real piano
/// action rather than a diagram: ivory keys with a lip that dips out of the
/// light, ebony keys leaning where the action puts them, the case shadow
/// falling across the bed.
///
/// The bed itself never changes, so it is painted once per size and
/// appearance into an image and blitted on every redraw. What is left of a
/// redraw is the handful of keys that actually sound — a note strike used to
/// rebuild ninety-odd bezier paths and gradients, which is a lot of ink for
/// a single key turning carmine.
final class KeybedView: NSView {
    /// the seam of dark bed showing between ivory blocks
    private static let seam: CGFloat = 0.8

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

    /// One key's geometry: shared by the painted bed and by the sounding
    /// overlay, so a lit key always sits exactly on its key.
    private struct KeyFace {
        let pitch: Int
        let rect: NSRect
        let radius: CGFloat
        let isSharp: Bool
    }

    /// How lit each key is right now, 0…1, and where it is heading. A key
    /// does not switch on: it lights with the force of the strike and lets go
    /// over a release that lasts longer than the attack, the way felt behaves
    /// under a hammer. Only keys in motion are repainted, and the ticker
    /// stops the moment the bed is still.
    private var glow: [Int: CGFloat] = [:]
    private var glowTarget: [Int: CGFloat] = [:]
    private var glowTimer: Timer?
    private static let tick = 1.0 / 60.0
    private static let attack: CGFloat = 0.42
    private static let release: CGFloat = 0.16

    /// pitches sounding right now, for callers that only know sets
    var soundingPitches: Set<Int> = [] {
        didSet {
            let fresh = soundingPitches.subtracting(glowTarget.filter { $0.value > 0 }.keys)
            for pitch in fresh { press(pitch: pitch, velocity: 96) }
            for pitch in glowTarget.keys where !soundingPitches.contains(pitch) {
                glowTarget[pitch] = 0
            }
        }
    }

    /// A key is struck: it lights at the strike's force, never above its own
    /// ceiling, and starts settling the instant it is hit.
    func press(pitch: Int, velocity: Int) {
        let force = CGFloat(max(20, min(127, velocity))) / 127
        glowTarget[pitch] = 0.35 + 0.65 * force
        if glow[pitch] == nil { glow[pitch] = 0 }
        startGlowTimer()
    }

    /// A key is let go: the light drains, slower than it came.
    func release(pitch: Int) {
        guard glowTarget[pitch] != nil else { return }
        glowTarget[pitch] = 0
        startGlowTimer()
    }

    func releaseAll() {
        for pitch in glowTarget.keys { glowTarget[pitch] = 0 }
        startGlowTimer()
    }

    private func startGlowTimer() {
        guard glowTimer == nil else { return }
        let timer = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceGlow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        glowTimer = timer
    }

    private func advanceGlow() {
        var settled = true
        for (pitch, target) in glowTarget {
            let current = glow[pitch] ?? 0
            let rate = target > current ? Self.attack : Self.release
            let next = current + (target - current) * rate
            if abs(next - target) < 0.008 {
                glow[pitch] = target > 0 ? target : nil
                if target == 0 { glowTarget[pitch] = nil }
            } else {
                glow[pitch] = next
                settled = false
            }
        }
        needsDisplay = true
        if settled || glowTarget.isEmpty {
            glowTimer?.invalidate()
            glowTimer = nil
        }
    }

    /// the painted bed, keyed by the geometry and appearance it was drawn for
    private struct BedKey: Equatable {
        let width: CGFloat
        let height: CGFloat
        let appearance: NSAppearance.Name
    }
    private var bedImage: NSImage?
    private var bedKey: BedKey?
    private var bedFaces: [KeyFace] = []

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        let key = BedKey(
            width: bounds.width.rounded(),
            height: bounds.height.rounded(),
            appearance: effectiveAppearance.name
        )
        if bedImage == nil || bedKey != key {
            bedKey = key
            bedImage = renderBed()
        }
        bedImage?.draw(in: bounds)
        drawSoundingKeys()
    }

    // MARK: the painted bed

    private func renderBed() -> NSImage? {
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let size = bounds.size
        let scale = window?.backingScaleFactor ?? 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size

        bedFaces = keyFaces()
        let faces = bedFaces
        let height = bounds.height

        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            // a bitmap rep's context is measured in pixels: scale once so
            // every rect below can stay in the view's own points
            context.cgContext.scaleBy(x: scale, y: scale)
            Self.keybed.setFill()
            NSRect(origin: .zero, size: size).fill()
            drawNaturals(faces, height: height)
            drawAccidentals(faces, height: height)
            drawFallboardShadow(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
        }

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    /// Every key of the range, in playing order, with the geometry its paint
    /// and its lit state both use. Where a key sits is the piano's own
    /// arithmetic (`PianoKeyboard`), not a counter kept here: F is ivory and
    /// F sharp is ebony because the instrument says so.
    private func keyFaces() -> [KeyFace] {
        let width = bounds.width / CGFloat(PianoKeyboard.ivoryCount)
        let accidentalWidth = width * 0.55
        let accidentalHeight = bounds.height * 0.62
        var faces: [KeyFace] = []
        faces.reserveCapacity(88)
        for pitch in PianoKeyboard.firstPitch...PianoKeyboard.lastPitch {
            if let column = PianoKeyboard.ivoryIndex(of: pitch) {
                faces.append(KeyFace(
                    pitch: pitch,
                    rect: NSRect(
                        x: CGFloat(column) * width + Self.seam,
                        y: 0,
                        width: width - Self.seam * 2,
                        height: bounds.height
                    ),
                    radius: 2.5,
                    isSharp: false
                ))
            } else {
                // the ebony key sits across the seam of the ivory key below
                // it, leaning the way a real action does, never dead-center
                let column = PianoKeyboard.ivoryIndex(of: PianoKeyboard.ivoryBelow(pitch)) ?? 0
                let drift = Self.accidentalOffsets[pitch % 12] ?? 0
                let center = CGFloat(column + 1) * width + drift * width
                faces.append(KeyFace(
                    pitch: pitch,
                    rect: NSRect(
                        x: center - accidentalWidth / 2,
                        y: bounds.height - accidentalHeight,
                        width: accidentalWidth,
                        height: accidentalHeight
                    ),
                    radius: 2,
                    isSharp: true
                ))
            }
        }
        return faces
    }

    private func drawNaturals(_ faces: [KeyFace], height: CGFloat) {
        for face in faces where !face.isSharp {
            let key = keyFront(face.rect, radius: face.radius)
            Self.ivory.setFill()
            key.fill()
            // the front face dips out of the light: shade washing up from
            // the foot, breaking at a crisp seam line
            let lip = NSRect(x: face.rect.minX, y: face.rect.minY, width: face.rect.width, height: 9)
            if let gradient = NSGradient(colors: [
                Self.ivoryShade,
                Self.ivoryShade.withAlphaComponent(0.0),
            ]) {
                gradient.draw(in: lip, angle: 90)
            }
            Self.ivoryShade.withAlphaComponent(0.55).setFill()
            NSRect(x: face.rect.minX, y: lip.maxY, width: face.rect.width, height: 1).fill()
        }
    }

    private func drawAccidentals(_ faces: [KeyFace], height: CGFloat) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1.5)
        for face in faces where face.isSharp {
            let key = keyFront(face.rect, radius: face.radius)
            // the sharp leans over the naturals: a heavy cast shadow first
            NSGraphicsContext.current?.saveGraphicsState()
            shadow.set()
            Self.ebony.setFill()
            key.fill()
            NSGraphicsContext.current?.restoreGraphicsState()
            // lacquer: one vertical gloss ridge where the light rolls off
            if let gloss = NSGradient(colors: [
                NSColor.white.withAlphaComponent(0.30),
                NSColor.white.withAlphaComponent(0.04),
            ]) {
                gloss.draw(
                    in: NSRect(
                        x: face.rect.minX + 1.2,
                        y: face.rect.minY + 2,
                        width: 1.8,
                        height: face.rect.height - 4
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
    private func drawFallboardShadow(in rect: NSRect) {
        if let shadow = NSGradient(colors: [
            NSColor.black.withAlphaComponent(0.18),
            NSColor.black.withAlphaComponent(0.0),
        ]) {
            shadow.draw(
                in: NSRect(x: 0, y: rect.height - 6, width: rect.width, height: 6),
                angle: -90
            )
        }
    }

    // MARK: the lit keys

    private func drawSoundingKeys() {
        guard !glow.isEmpty, !bedFaces.isEmpty else { return }
        // the ivory keys first, the ebony ones over them: a lit white key must
        // not paint across the black key that sits on its seam
        let sounding = bedFaces
            .filter { (glow[$0.pitch] ?? 0) > 0.001 }
            .sorted { ($0.isSharp ? 1 : 0, $0.pitch) < ($1.isSharp ? 1 : 0, $1.pitch) }
        for face in sounding {
            guard let intensity = glow[face.pitch], intensity > 0.001 else { continue }
            let key = keyFront(face.rect, radius: face.radius)
            // carmine sits nearly solid on ebony and as a wash on ivory, and
            // the wash carries the strike's force: a whisper stays a whisper
            let peak: CGFloat = face.isSharp ? 0.90 : 0.22
            PaperTheme.stamp
                .withAlphaComponent(peak * intensity)
                .setFill()
            key.fill()
            // the key dips a hair under the finger: one shaded band at the top
            NSColor.black.withAlphaComponent(0.10 * intensity).setFill()
            NSRect(x: face.rect.minX,
                   y: face.rect.maxY - 5,
                   width: face.rect.width,
                   height: 5).fill()
            if face.isSharp {
                // keep the lacquer alive under the tint: one pale ridge
                NSColor.white.withAlphaComponent(0.16 * intensity).setFill()
                NSRect(
                    x: face.rect.minX + 1.2,
                    y: face.rect.minY + 2,
                    width: 1.8,
                    height: face.rect.height - 4
                ).fill()
            }
        }
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

}
