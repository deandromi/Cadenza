import AppKit
import Foundation

/// Renders the README logo: the wordmark "Cadenza" in warm ink with the
/// stamp dot, on a transparent ground. Writes a PNG to the path given as the
/// first argument. Run: swift Tools/make_logo.swift Resources/logo.png
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/logo.png"
let width: CGFloat = 1200
let height: CGFloat = 300
let scale: CGFloat = 2

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }
ctx.scaleBy(x: scale, y: scale)
ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))

// the wordmark, exactly the logo on the practice screen's top left
let label = "Cadenza"
let fontSize: CGFloat = 190
let serifDescriptor = NSFont.systemFont(ofSize: fontSize, weight: .semibold).fontDescriptor.withDesign(.serif)
    ?? NSFont.systemFont(ofSize: fontSize, weight: .semibold).fontDescriptor
let font = NSFont(descriptor: serifDescriptor, size: fontSize)!
let ink = NSColor(srgbRed: 0.212, green: 0.204, blue: 0.200, alpha: 1)
let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: ink])
let size = text.size()
let dotSide: CGFloat = 27
let gap: CGFloat = 13
let totalWidth = size.width + gap + dotSide
let origin = NSPoint(x: (width - totalWidth) / 2, y: (height - size.height) / 2 + 12)
text.draw(at: origin)

// the stamp dot at the wordmark's terminal
let stamp = NSColor(srgbRed: 0.62, green: 0.13, blue: 0.16, alpha: 1)
stamp.setFill()
NSBezierPath(ovalIn: NSRect(x: origin.x + size.width + gap, y: origin.y + 4, width: dotSide, height: dotSide)).fill()

NSGraphicsContext.restoreGraphicsState()

let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: out))
print("logo: wrote \(out) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
