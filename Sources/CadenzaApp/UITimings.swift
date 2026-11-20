import AppKit
import CadenzaCore
import QuartzCore

/// Offscreen timings of the surfaces that repaint while music plays: the
/// keybed (once per note event) and the endless measure (thirty times a
/// second). Printed as milliseconds per draw, so a regression shows up as a
/// number instead of as a warm laptop.
///
/// The uncached bed row paints the same key geometry the old code painted on
/// every redraw, so the gain from keeping the bed in an image stays visible.
@MainActor
enum UITimings {
    static func run() {
        MainActor.assumeIsolated {
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
            MusicFont.register()
            benchKeybed()
            benchUncachedBed()
            benchStaff()
        }
    }

    // MARK: harness

    private static func time(_ label: String, rounds: Int, _ body: @MainActor (NSGraphicsContext) -> Void) {
        let size = NSSize(width: 1080, height: 118)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        rep.size = size
        context.cgContext.scaleBy(x: 2, y: 2)

        // one warm pass, then the measured ones
        draw(context, body)
        let began = CACurrentMediaTime()
        for _ in 0..<rounds { draw(context, body) }
        let per = (CACurrentMediaTime() - began) * 1000 / Double(rounds)
        print(String(format: "%-26@ %6.3f ms/draw", label as NSString, per))
    }

    private static func draw(_ context: NSGraphicsContext, _ body: @MainActor (NSGraphicsContext) -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        body(context)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: the keybed

    private static func soundingKeys() -> Set<Int> {
        [48, 55, 61, 66, 70, 72, 76, 84, 93, 30]
    }

    private static func benchKeybed() {
        let view = KeybedView()
        view.frame = NSRect(x: 0, y: 0, width: 1080, height: 118)
        view.soundingPitches = soundingKeys()
        let image = NSImage(size: view.frame.size)
        image.lockFocus()
        view.draw(view.bounds)
        image.unlockFocus()
        time("keybed (cached bed)", rounds: 200) { context in
            NSGraphicsContext.current = context
            view.draw(view.bounds)
        }
    }

    /// The same geometry painted the way the app painted it before: every
    /// redraw built the paths and gradients for the whole instrument.
    private static func benchUncachedBed() {
        let faceRects = keyRects(width: 1080 / 52, height: 118)
        time("keybed (repainted bed)", rounds: 20) { _ in
            NSColor(calibratedRed: 0.129, green: 0.122, blue: 0.114, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 1080, height: 118).fill()
            for face in faceRects where !face.isSharp {
                let key = keyFront(face.rect, radius: 2.5)
                NSColor(calibratedRed: 0.988, green: 0.98, blue: 0.961, alpha: 1).setFill()
                key.fill()
                let lip = NSRect(x: face.rect.minX, y: face.rect.minY, width: face.rect.width, height: 9)
                NSGradient(colors: [
                    NSColor(calibratedRed: 0.918, green: 0.898, blue: 0.867, alpha: 1),
                    NSColor(calibratedRed: 0.918, green: 0.898, blue: 0.867, alpha: 0),
                ])?.draw(in: lip, angle: 90)
            }
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1.5)
            for face in faceRects where face.isSharp {
                let key = keyFront(face.rect, radius: 2)
                NSGraphicsContext.current?.saveGraphicsState()
                shadow.set()
                NSColor(calibratedRed: 0.243, green: 0.231, blue: 0.220, alpha: 1).setFill()
                key.fill()
                NSGraphicsContext.current?.restoreGraphicsState()
                NSGradient(colors: [
                    NSColor.white.withAlphaComponent(0.30),
                    NSColor.white.withAlphaComponent(0.04),
                ])?.draw(
                    in: NSRect(x: face.rect.minX + 1.2, y: face.rect.minY + 2, width: 1.8, height: face.rect.height - 4),
                    angle: -90
                )
                key.lineWidth = 1
                key.stroke()
            }
        }
    }

    private struct Face {
        let rect: NSRect
        let isSharp: Bool
    }

    private static func keyRects(width: CGFloat, height: CGFloat) -> [Face] {
        let offsets: [Int: CGFloat] = [1: -0.09, 3: 0.09, 6: -0.11, 8: 0.0, 10: 0.11]
        let naturals: Set<Int> = [0, 2, 4, 5, 7, 9, 11]
        var faces: [Face] = []
        var passed = 0
        for pitch in 21...108 {
            if naturals.contains(pitch % 12) {
                faces.append(Face(
                    rect: NSRect(x: CGFloat(passed) * width + 0.8, y: 0, width: width - 1.6, height: height),
                    isSharp: false
                ))
                passed += 1
            } else {
                let center = CGFloat(passed) * width + (offsets[pitch % 12] ?? 0) * width
                faces.append(Face(
                    rect: NSRect(x: center - width * 0.275, y: height - height * 0.62, width: width * 0.55, height: height * 0.62),
                    isSharp: true
                ))
            }
        }
        return faces
    }

    private static func keyFront(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + radius))
        path.appendArc(from: NSPoint(x: rect.minX, y: rect.minY), to: NSPoint(x: rect.minX + radius, y: rect.minY), radius: radius)
        path.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
        path.appendArc(from: NSPoint(x: rect.maxX, y: rect.minY), to: NSPoint(x: rect.maxX, y: rect.minY + radius), radius: radius)
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.close()
        return path
    }

    // MARK: the endless measure

    private static func benchStaff() {
        let view = EndlessStaffView()
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 180)
        for index in 0..<40 {
            view.noteStruck(pitch: 36 + (index * 7) % 48, age: Double(index) * 0.12)
        }
        time("endless staff (40 notes)", rounds: 120) { context in
            NSGraphicsContext.current = context
            view.draw(view.bounds)
        }
    }
}
