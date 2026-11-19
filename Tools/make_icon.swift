import AppKit
import Foundation

/// Renders the app icon: warm paper, one large serif C in warm ink, and the
/// stamp dot answering it. Writes a 1024x1024 PNG to the path given as the
/// first argument. Run: swift Tools/make_icon.swift /tmp/icon1024.png
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/icon1024.png"
let side: CGFloat = 1024
let scale: CGFloat = 2

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(side * scale), pixelsHigh: Int(side * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }
ctx.scaleBy(x: scale, y: scale)

// paper ground
let paper = NSColor(srgbRed: 0.957, green: 0.941, blue: 0.914, alpha: 1)
let parchment = NSColor(srgbRed: 0.945, green: 0.929, blue: 0.898, alpha: 1)
let gradient = NSGradient(colors: [parchment, paper])!
gradient.draw(in: NSRect(x: 0, y: 0, width: side, height: side), angle: -90)

// hairline frame
let ink = NSColor(srgbRed: 0.212, green: 0.204, blue: 0.200, alpha: 1)
let hairline = NSColor(srgbRed: 0.78, green: 0.76, blue: 0.73, alpha: 1)
let frame = NSBezierPath(rect: NSRect(x: 0.5, y: 0.5, width: side - 1, height: side - 1))
hairline.setStroke()
frame.lineWidth = 1
frame.stroke()

// the wordmark itself: serif "Cadenza" centered, stamp dot answering it,
// exactly the logo on the practice screen's top left
let label = "Cadenza"
let fontSize: CGFloat = 210
let serifDescriptor = NSFont.systemFont(ofSize: fontSize, weight: .semibold).fontDescriptor.withDesign(.serif)
    ?? NSFont.systemFont(ofSize: fontSize, weight: .semibold).fontDescriptor
let font = NSFont(descriptor: serifDescriptor, size: fontSize)!
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: ink,
]
let text = NSAttributedString(string: label, attributes: attrs)
let size = text.size()
let dotSide: CGFloat = 30
let gap: CGFloat = 14
let totalWidth = size.width + gap + dotSide
let origin = NSPoint(x: (side - totalWidth) / 2, y: (side - size.height) / 2 + 14)
text.draw(at: origin)

// the stamp dot at the wordmark's terminal
let stamp = NSColor(srgbRed: 0.62, green: 0.13, blue: 0.16, alpha: 1)
let dotRect = NSRect(x: origin.x + size.width + gap, y: origin.y + 4, width: dotSide, height: dotSide)
let dot = NSBezierPath(ovalIn: dotRect)
stamp.setFill()
dot.fill()

NSGraphicsContext.restoreGraphicsState()

let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: out))
print("icon: wrote \(out) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
