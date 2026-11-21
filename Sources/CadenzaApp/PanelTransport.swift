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
