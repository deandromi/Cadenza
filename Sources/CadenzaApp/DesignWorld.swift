import AppKit

/// Design tokens and small building blocks for the paper-and-glass design
/// language, shared by the design gallery drafts. With the drafts approved,
/// the app adopts these as its own and this file becomes the design system.
///
/// The paper world: warm paper surfaces, warm ink, hairline rules, and one
/// stamp accent that carries state. The glass chrome: lenses built from
/// NSGlassEffectView inside an NSGlassEffectContainerView, defined by the
/// builders here so every draft floats chrome the same way.
enum PaperTheme {
    static let paper = NSColor(name: "cadenzaPaper") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.115, alpha: 1.0)  // lamp-lit charcoal
            : NSColor(calibratedWhite: 0.984, alpha: 1.0)  // warm ivory
    }

    static let parchment = NSColor(name: "cadenzaParchment") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.16, alpha: 1.0)
            : NSColor(calibratedRed: 0.922, green: 0.902, blue: 0.867, alpha: 1.0)
    }

    static let ink = NSColor(name: "cadenzaInk") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.914, green: 0.906, blue: 0.882, alpha: 1.0)
            : NSColor(calibratedRed: 0.212, green: 0.204, blue: 0.20, alpha: 1.0)
    }

    static let secondaryInk = NSColor(name: "cadenzaSecondaryInk") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.55, alpha: 1.0)
            : NSColor(calibratedRed: 0.42, green: 0.416, blue: 0.392, alpha: 1.0)
    }

    static let hairline = NSColor(name: "cadenzaHairline") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.28, alpha: 1.0)
            : NSColor(calibratedRed: 0.863, green: 0.851, blue: 0.804, alpha: 1.0)
    }

    /// The one accent: deep carmine, carrying state only (recording, a
    /// sounding chord, an error), never decoration.
    static let stamp = NSColor(name: "cadenzaStamp") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.80, green: 0.44, blue: 0.39, alpha: 1.0)
            : NSColor(calibratedRed: 0.541, green: 0.176, blue: 0.114, alpha: 1.0)
    }

    /// Display serif at the paper family's scale, native: the system serif
    /// design, never a custom font.
    static func displaySerif(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let design = NSFont.systemFont(ofSize: size, weight: weight)
            .fontDescriptor.withDesign(.serif) ?? NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        return NSFont(descriptor: design, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }
}

/// The keybed and the blooms share one piano range: A0 through C8, the
/// full instrument the model hears.
enum PianoRange {
    static let firstPitch = 21
    static let lastPitch = 108
}

/// A line field with the paper world's defaults.
@MainActor
func makeInkLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = font
    field.textColor = color
    return field
}

/// The window surface: warm paper with the faintest parchment wash toward
/// the top, the world glass lenses float on.
final class PaperView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        guard let gradient = NSGradient(colors: [PaperTheme.parchment, PaperTheme.paper]) else {
            PaperTheme.paper.setFill()
            bounds.fill()
            return
        }
        gradient.draw(in: bounds, angle: -90)
    }
}

/// One hairline rule in paper space.
final class HairlineView: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 1.0)
    }

    override func draw(_ dirtyRect: NSRect) {
        PaperTheme.hairline.setFill()
        bounds.fill()
    }
}

/// The thin level line for session meta, ink at rest, stamp while a chord
/// is sounding. The level chases its target at display cadence, so the bar
/// flows instead of stepping from update to update.
final class LevelLineView: NSView {
    /// where the level should settle, set by the session
    private var target: Double = 0
    /// the level currently drawn, easing toward the target
    private var fraction: Double = 0
    private var timer: Timer?

    var sounding = false {
        didSet {
            needsDisplay = true
        }
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 3.0)
    }

    /// Set where the level should go; the bar glides there.
    func setFractionTarget(_ value: Double) {
        target = value
        startTimerIfNeeded()
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        timer = Clock.every(1.0 / 60.0) { [weak self] in self?.ease() }
    }

    /// easing per frame at 60 fps: the bar settles in roughly 150 ms
    private static let easing: Double = 0.12

    private func ease() {
        fraction += (target - fraction) * Self.easing
        if abs(target - fraction) < 0.002 {
            fraction = target
            timer?.invalidate()
            timer = nil
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        (sounding ? PaperTheme.stamp : PaperTheme.ink).withAlphaComponent(0.25).setFill()
        bounds.fill()
        (sounding ? PaperTheme.stamp : PaperTheme.ink).setFill()
        NSBezierPath.fill(NSRect(
            x: 0,
            y: 0,
            width: bounds.width * CGFloat(fraction),
            height: bounds.height
        ))
    }
}

/// A glass lens as pure backdrop material, no content hosting: the caller
/// pins it behind ordinary AppKit views sized to the same frame, so content
/// renders through a guaranteed regular subview chain.
@MainActor
func makeGlassBackdrop(cornerRadius: CGFloat, interactive: Bool) -> NSGlassEffectView {
    let lens = NSGlassEffectView()
    lens.style = .regular
    lens.cornerRadius = cornerRadius
    if #available(macOS 27.0, *) {
        lens.effectIsInteractive = interactive
    }
    return lens
}

/// Where one glass lens is padded around a bare control.
@MainActor
func padForLens(
    _ view: NSView,
    horizontal: CGFloat,
    vertical: CGFloat
) -> NSStackView {
    let stack = NSStackView(views: [view])
    stack.orientation = .horizontal
    stack.edgeInsets = NSEdgeInsets(
        top: vertical, left: horizontal, bottom: vertical, right: horizontal
    )
    return stack
}

func sessionTimeString(_ seconds: Double) -> String {
    let total = Int(max(seconds, 0).rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}

/// Spelled note name for a MIDI pitch, octave numbered: C#4.
func noteName(_ pitch: Int) -> String {
    let letters = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    return letters[pitch % 12] + String(pitch / 12 - 1)
}
