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
/// is sounding, breathing with the simulated room level.
final class LevelLineView: NSView {
    var fraction: Double = 0
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

    override func draw(_ dirtyRect: NSRect) {
        (sounding ? PaperTheme.stamp : PaperTheme.ink).withAlphaComponent(0.25).setFill()
        bounds.fill()
        (sounding ? PaperTheme.stamp : PaperTheme.ink).setFill()
        NSBezierPath.fill(NSRect(
            x: 0,
            y: 0,
            width: bounds.width * fraction,
            height: bounds.height
        ))
    }
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

/// One glass lens: NSGlassEffectView with the language's defaults, hosted in
/// an NSGlassEffectContainerView by the caller.
@MainActor
func makeLens(
    style: NSGlassEffectView.Style,
    interactive: Bool,
    cornerRadius: CGFloat,
    contentView: NSView
) -> NSGlassEffectView {
    let lens = NSGlassEffectView()
    lens.style = style
    lens.cornerRadius = cornerRadius
    lens.contentView = contentView
    if #available(macOS 27.0, *) {
        lens.effectIsInteractive = interactive
    }
    return lens
}

/// Drives the draft with a plausible live session: chords land every few
/// seconds and sound, the level breathes, and every view reacts to the
/// same moments. Listen on the panel toggles it, record tints the panel.
@MainActor
final class DesignSessionClock {
    struct Moment {
        let seconds: Double
        let symbol: String
        let sounding: Bool
        let level: Double
        let noteCount: Int
        /// MIDI pitches of the voicing behind the current chord
        let pitches: [Int]
    }

    static let chorus: [String] = [
        "C", "Am7", "Fmaj7", "G", "Em7", "Dm7", "Cmaj7", "G7", "F", "C",
    ]

    /// Piano voicings for the chorus, the keys that sound per chord.
    static let voicings: [String: [Int]] = [
        "C": [48, 60, 64, 67, 72],
        "Am7": [45, 57, 60, 64, 67],
        "Fmaj7": [41, 53, 57, 60, 64],
        "G": [43, 55, 59, 62, 67],
        "Em7": [40, 52, 55, 59, 62],
        "Dm7": [38, 50, 53, 57, 60],
        "Cmaj7": [48, 60, 64, 67, 71],
        "G7": [43, 55, 59, 62, 65],
        "F": [41, 53, 57, 60, 65],
    ]

    /// notes already struck when the gallery opens, so drafts open
    /// mid-session
    private(set) var noteCount = 10
    private var timer: Timer?
    private var seconds: Double = 47
    private var index = 2
    private var nextStrike: Double = 0
    private var soundingUntil: Double = 0

    /// set by the gallery once the drafts exist; fired every tick
    var onUpdate: ((Moment) -> Void)?

    var isRunning: Bool { timer != nil }
    var sounding: Bool { seconds < soundingUntil }
    var symbol: String { Self.chorus[index] }

    init() {
        nextStrike = seconds + 1.2
        soundingUntil = seconds + 1.5
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func toggleRunning() {
        if timer == nil {
            start()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func tick() {
        seconds += 0.1
        if seconds >= nextStrike {
            index = (index + 1) % Self.chorus.count
            noteCount += 1
            soundingUntil = seconds + 1.15
            nextStrike = seconds + 2.9 + Double((index % 3)) * 0.5
        }
        let level = 0.35 + 0.2 * sin(seconds * 1.7) + 0.08 * sin(seconds * 0.43)
        onUpdate?(Moment(
            seconds: seconds,
            symbol: symbol,
            sounding: sounding,
            level: max(0.1, min(1, level)),
            noteCount: noteCount,
            pitches: Self.voicings[symbol] ?? []
        ))
    }
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
