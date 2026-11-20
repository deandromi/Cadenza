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
    private static let naturals = 52
    /// the seam of dark bed showing between ivory blocks
    private static let seam: CGFloat = 0.8
    /// natural pitch classes C D E F G A B, as a bit pattern by pitch class
    private static let naturalMask: UInt16 = 0x0AD5

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

    /// pitches sounding right now; stamp-tinted keys follow
    var soundingPitches: Set<Int> = [] {
        didSet { needsDisplay = true }
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

        bedFaces = keyFaces(width: bounds.width / CGFloat(Self.naturals))
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
    /// and its lit state both use.
    private func keyFaces(width: CGFloat) -> [KeyFace] {
        let accidentalWidth = width * 0.55
        let accidentalHeight = bounds.height * 0.62
        var faces: [KeyFace] = []
        faces.reserveCapacity(88)
        var naturalsPassed = 0
        for pitch in PianoRange.firstPitch...PianoRange.lastPitch {
            if Self.isNatural(pitch) {
                faces.append(KeyFace(
                    pitch: pitch,
                    rect: NSRect(
                        x: CGFloat(naturalsPassed) * width + Self.seam,
                        y: 0,
                        width: width - Self.seam * 2,
                        height: bounds.height
                    ),
                    radius: 2.5,
                    isSharp: false
                ))
                naturalsPassed += 1
            } else {
                // the sharp leans the way a real action does, never dead-center
                let drift = Self.accidentalOffsets[pitch % 12] ?? 0
                let center = CGFloat(naturalsPassed) * width + drift * width
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
        guard !soundingPitches.isEmpty, !bedFaces.isEmpty else { return }
        for face in bedFaces where soundingPitches.contains(face.pitch) {
            let key = keyFront(face.rect, radius: face.radius)
            // carmine sits nearly solid on ebony and as a wash on ivory, so a
            // sounding key reads the same as it did when it was painted with
            // the bed instead of over it
            PaperTheme.stamp
                .withAlphaComponent(face.isSharp ? 0.88 : 0.14)
                .setFill()
            key.fill()
            if face.isSharp {
                // keep the lacquer alive under the tint: one pale ridge
                NSColor.white.withAlphaComponent(0.16).setFill()
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

    private static func isNatural(_ pitch: Int) -> Bool {
        naturalMask & (1 << UInt16(pitch % 12)) != 0
    }
}
