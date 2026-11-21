import AppKit
import CadenzaCore

/// What an export hands over, chosen in the export popover.
enum ExportChoice {
    case midi
    case audio
    case both
}

/// The export choice popover: one glass lens asking what a session hands
/// over — its MIDI file, its audio recording, or both.
@MainActor
final class ExportChoicesPopover: NSPopover {
    private let onChoice: (ExportChoice) -> Void
    private let hasAudio: Bool

    init(hasAudio: Bool, onChoice: @escaping (ExportChoice) -> Void) {
        self.hasAudio = hasAudio
        self.onChoice = onChoice
        super.init()
        behavior = .transient
        let controller = NSViewController()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 190, height: hasAudio ? 118 : 82))
        let backdrop = makeGlassBackdrop(cornerRadius: 14, interactive: false)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(backdrop)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        for (title, choice) in [("MIDI file", ExportChoice.midi)]
            + (hasAudio ? [("Audio recording", ExportChoice.audio)] : [])
            + (hasAudio ? [("MIDI and audio", ExportChoice.both)] : []) {
            let button = NSButton(title: title, target: self, action: #selector(chose(_:)))
            button.isBordered = false
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.contentTintColor = PaperTheme.ink
            button.identifier = NSUserInterfaceItemIdentifier(switchChoice(choice))
            stack.addArrangedSubview(button)
        }
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: root.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        controller.view = root
        contentViewController = controller
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func switchChoice(_ choice: ExportChoice) -> String {
        switch choice {
        case .midi: return "midi"
        case .audio: return "audio"
        case .both: return "both"
        }
    }

    @objc private func chose(_ sender: NSButton) {
        let id = sender.identifier?.rawValue ?? "midi"
        performClose(nil)
        switch id {
        case "audio": onChoice(.audio)
        case "both": onChoice(.both)
        default: onChoice(.midi)
        }
    }
}

/// Shot diagnostics shared by every screen carrying the practice chrome:
/// the rectangles where label and button ink should reach the screen, in
/// the given view's coordinates, so the live capture can prove it did.
@MainActor
func paperInkRects(
    panel: ControlPanelLens,
    wordmark: NSView,
    in view: NSView
) -> [(String, NSRect)] {
    var rects = panel.contentRects().map { name, rect in
        (name, panel.convert(rect, to: view))
    }
    rects.append(("wordmark", view.convert(wordmark.frame, to: view)))
    return rects
}


/// The take's description as a glass card: one sentence a person can read at
/// a glance, then the captioned lines behind it. Read-only, so it carries no
/// controls at all — the row's menu is where actions live.
@MainActor
final class TakeDescriptionPopover: NSPopover {
    init(_ description: TakeDescription, title: String) {
        super.init()
        behavior = .transient
        let width: CGFloat = 320
        let controller = NSViewController()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 260))
        let backdrop = makeGlassBackdrop(cornerRadius: 16, interactive: false)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(backdrop)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        let heading = makeInkLabel(title,
                                   font: .systemFont(ofSize: 11, weight: .medium),
                                   color: PaperTheme.secondaryInk)
        stack.addArrangedSubview(heading)
        let summary = makeInkLabel(description.summary,
                                   font: PaperTheme.displaySerif(17, weight: .regular),
                                   color: PaperTheme.ink)
        summary.maximumNumberOfLines = 3
        summary.lineBreakMode = .byWordWrapping
        summary.preferredMaxLayoutWidth = width - 36
        stack.addArrangedSubview(summary)
        stack.addArrangedSubview(HairlineView())

        for line in description.lines {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 10
            let caption = makeInkLabel(line.caption,
                                       font: .systemFont(ofSize: 11, weight: .medium),
                                       color: PaperTheme.secondaryInk)
            caption.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            let value = makeInkLabel(line.value,
                                     font: .systemFont(ofSize: 12, weight: .regular),
                                     color: PaperTheme.ink)
            value.maximumNumberOfLines = 2
            value.lineBreakMode = .byWordWrapping
            row.addArrangedSubview(caption)
            row.addArrangedSubview(value)
            stack.addArrangedSubview(row)
        }

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: root.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.widthAnchor.constraint(equalToConstant: width),
        ])
        controller.view = root
        contentViewController = controller
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
