import AppKit
import CadenzaCore

/// What the control panel asks of its owner. Closures keep the panel
/// ignorant of engines and clocks: the gallery feeds it a simulated
/// transport, the app the real one. Listening is recording — the one
/// action starts and stops the session that export hands over.
struct PanelTransport {
    var isListening: () -> Bool
    var toggleListening: () -> Void
    var exportEnabled: () -> Bool
    var export: () -> Void
    /// Play or stop a preserved session, owned by the app shell.
    var playSession: (SessionRecord) -> Void = { _ in }
    /// Whether one session is playing right now.
    var playingSession: () -> SessionRecord? = { nil }
    /// Pause a playing session, or resume a paused one; with nothing
    /// playing, starts the newest session.
    var togglePlayPause: () -> Void = { }
    /// Stop playback outright, paused or not.
    var stopPlayback: () -> Void = { }
    /// Whether playback is paused right now.
    var playbackPaused: () -> Bool = { false }
    /// Per-session actions, revealed when the panel expands: rename the
    /// session, copy its MIDI file to the clipboard, open its sheet, play
    /// along with it, export MIDI, audio or both.
    var renameSession: (SessionRecord, String) -> Void = { _, _ in }
    /// Removes a session and everything it owns on disk.
    var deleteSession: (SessionRecord) -> Void = { _ in }
    /// The archive's batch actions: delete a shift-clicked set, or rename it
    /// from one stem with -1, -2 appended in list order.
    var deleteSessions: ([SessionRecord]) -> Void = { _ in }
    var renameSessions: ([SessionRecord], String) -> Void = { _, _ in }
    var copySessionMIDI: (SessionRecord) -> Void = { _ in }
    var openSessionSheet: (SessionRecord) -> Void = { _ in }
    var playAlong: (SessionRecord) -> Void = { _ in }
    var exportSessionMIDI: (SessionRecord) -> Void = { _ in }
    var exportSessionAudio: (SessionRecord) -> Void = { _ in }
    var exportSessionBoth: (SessionRecord) -> Void = { _ in }
    /// Whether the session folder holds an audio recording.
    var sessionHasAudio: (SessionRecord) -> Bool = { _ in false }
    /// Import a MIDI file as a session.
    var importMIDI: () -> Void = { }
    /// Reads a take back from its MIDI and describes it: key, tempo,
    /// harmony, phrasing, cadences, texture, register.
    var describeSession: (SessionRecord) -> TakeDescription? = { _ in nil }
    /// One line in the panel's status area, for actions that only need to
    /// tell the player what happened.
    var showStatus: (String, Bool) -> Void = { _, _ in }
    /// The time machine: where playback sits (0-1) and a scrub request.
    var playbackProgress: () -> Double = { 0 }
    var scrubPlayback: (Double) -> Void = { _ in }
    /// Retroactive capture: keep the last minute of playing as its own
    /// session, and whether there is anything in the window to keep.
    var keepLastMinute: () -> Void = { }
    var canKeepLastMinute: () -> Bool = { false }
    var keepMinuteEnabled: () -> Bool = { true }
    /// The practice click: on/off, and the tempo it runs at.
    var toggleMetronome: () -> Void = { }
    var metronomeActive: () -> Bool = { false }
    var metronomeTempo: () -> Double = { 96 }
    var setMetronomeTempo: (Double) -> Void = { _ in }
    /// A-B looping over the playing session: marks at the current moment,
    /// the loop toggle, and the practice rate.
    var setLoopPoint: (Bool) -> Void = { _ in }   // true = A, false = B
    var toggleLoop: () -> Void = { }
    var loopActive: () -> Bool = { false }
    var setPlaybackRate: (Double) -> Void = { _ in }
}

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
