import AppKit
import CadenzaCore
@preconcurrency import CoreText
import CoreGraphics

/// The notation font: Bravura (OFL, bundled in Resources/), the same SMuFL
/// font MuseScore engraves with. Registered with CoreText once at launch;
/// every glyph below is a real music glyph, not a drawn imitation.
enum MusicFont {
    static let familyName = "Bravura"

    /// Registers the bundled font for this process: the app bundle's
    /// resources first, then the repository's Resources for swift run.
    static func register() {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("Bravura.otf"))
        }
        if let executable = Bundle.main.executableURL {
            var dir = executable.deletingLastPathComponent()
            for _ in 0..<6 {
                candidates.append(dir.appendingPathComponent("Resources/Bravura.otf"))
                dir = dir.deletingLastPathComponent()
            }
        }
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for _ in 0..<6 {
            candidates.append(dir.appendingPathComponent("Resources/Bravura.otf"))
            dir = dir.deletingLastPathComponent()
        }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            return
        }
    }

    /// The music font at the given point size. SMuFL is built so that one
    /// em is four staff spaces, so a staff with line gap g wants 4 * g.
    static func font(size: CGFloat) -> NSFont {
        NSFont(name: familyName, size: size) ?? .systemFont(ofSize: size)
    }

    /// The same font as a CoreText font, for glyph-precise drawing.
    static func ctFont(size: CGFloat) -> CTFont {
        CTFontCreateWithName(familyName as CFString, size, nil)
            ?? CTFontCreateWithName("System" as CFString, size, nil)
    }

    /// Metrics of one SMuFL glyph: its glyph id and bounding box in em
    /// units (y up from the baseline), measured once at a reference size.
    /// Glyph ids are size-independent, so one cache serves every size.
    struct GlyphInfo {
        let glyph: CGGlyph
        let x0: CGFloat
        let y0: CGFloat
        let x1: CGFloat
        let y1: CGFloat
        var width: CGFloat { x1 - x0 }
        var centerY: CGFloat { (y0 + y1) / 2 }
    }

    private static nonisolated(unsafe) let referenceFont = ctFont(size: 1000)
    private static nonisolated(unsafe) var cache: [UInt32: GlyphInfo] = [:]

    static func info(_ codepoint: UInt32) -> GlyphInfo? {
        if let hit = cache[codepoint] { return hit }
        let text = String(UnicodeScalar(codepoint)!)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text,
            attributes: [.font: NSFont(name: familyName, size: 1000) ?? .systemFont(ofSize: 1000)]
        ))
        guard let run = (CTLineGetGlyphRuns(line) as? [CTRun])?.first else { return nil }
        var glyph: CGGlyph = 0
        CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph)
        guard glyph != 0 else { return nil }
        var box = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(referenceFont, .horizontal, [glyph], &box, 1)
        let info = GlyphInfo(glyph: glyph,
                             x0: box.minX / 1000, y0: box.minY / 1000,
                             x1: box.maxX / 1000, y1: box.maxY / 1000)
        cache[codepoint] = info
        return info
    }
}
