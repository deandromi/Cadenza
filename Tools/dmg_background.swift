import AppKit
import Foundation

/// Renders the DMG's background image: warm paper, the wordmark in the
/// display serif, and one quiet line of instruction. Writes a 1600x900 PNG
/// to the path given as the first argument.
/// Run: swift Tools/dmg_background.swift /tmp/dmg_background.png
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/dmg_background.png"
let w: CGFloat = 1600
let h: CGFloat = 900
let scale: CGFloat = 1

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }
ctx.scaleBy(x: scale, y: scale)

let paper = NSColor(srgbRed: 0.957, green: 0.941, blue: 0.914, alpha: 1)
let parchment = NSColor(srgbRed: 0.945, green: 0.929, blue: 0.898, alpha: 1)
let ink = NSColor(srgbRed: 0.212, green: 0.204, blue: 0.200, alpha: 1)
let secondary = NSColor(srgbRed: 0.45, green: 0.44, blue: 0.42, alpha: 1)
let stamp = NSColor(srgbRed: 0.62, green: 0.13, blue: 0.16, alpha: 1)

NSGradient(colors: [parchment, paper])!.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)

func text(_ s: String, at p: NSPoint, font: NSFont, color: NSColor) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let a = NSAttributedString(string: s, attributes: attrs)
    a.draw(at: p)
}

let serif = NSFont.systemFont(ofSize: 150).fontDescriptor.withDesign(.serif)
let wordmark = NSFont(descriptor: serif ?? NSFont.systemFont(ofSize: 150).fontDescriptor, size: 150)!
let title = "Cadenza"
let titleAttrs: [NSAttributedString.Key: Any] = [.font: wordmark, .foregroundColor: ink]
let titleSize = NSAttributedString(string: title, attributes: titleAttrs).size()
text(title, at: NSPoint(x: 120, y: h - 240 - titleSize.height), font: wordmark, color: ink)

// stamp dot after the wordmark
let dot = NSBezierPath(ovalIn: NSRect(x: 120 + titleSize.width + 22, y: h - 240 - 34, width: 34, height: 34))
stamp.setFill()
dot.fill()

let instruction = NSFont(descriptor: NSFont.systemFont(ofSize: 30).fontDescriptor, size: 30)!
text("Sleep Cadenza naar Applications om te installeren",
     at: NSPoint(x: 122, y: h - 330), font: instruction, color: secondary)

// hairline under the instruction
let rule = NSBezierPath()
rule.move(to: NSPoint(x: 120, y: h - 372))
rule.line(to: NSPoint(x: 120 + 760, y: h - 372))
NSColor(srgbRed: 0.78, green: 0.76, blue: 0.73, alpha: 1).setStroke()
rule.lineWidth = 1.5
rule.stroke()

text("Versie 1.0 · macOS 26 of hoger · microfoon-rechten nodig",
     at: NSPoint(x: 122, y: h - 420), font: .systemFont(ofSize: 24, weight: .regular), color: secondary)

NSGraphicsContext.restoreGraphicsState()
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: out))
print("background: wrote \(out)")
