import AppKit
import CadenzaCore
@preconcurrency import CoreText
import CoreGraphics
import UniformTypeIdentifiers

/// The sheet music section: a paper window engraved live from the note
/// stream. While a session runs, every struck note re-engraves the draft
/// through the SheetDraft process (chordify, round durations, split hands,
/// guess the key, measure, beam), so the sheet drafts itself as the player
/// plays; the tempo and meter choices re-frame it on demand. Chrome is one
/// glass lens along the top; the score is the content.
@MainActor
final class SheetMusicController: NSObject {
    private var notes: [NoteEvent]
    /// sustain-pedal spans in seconds, from an imported MIDI's CC64; live
    /// sessions carry none (the audio model folds pedal into durations)
    private var pedalSpans: [(start: Double, end: Double)]
    private var options: SheetDraft.Options
    private var window: NSWindow?
    private var contentHost: NSView?
    private var scoreView: ScoreView?
    private var tempoPopup: NSPopUpButton?
    private var meterPopup: NSPopUpButton?
    private var emptyLabel: NSTextField?
    /// Called by the choices bar's Close button when the sheet sits in the
    /// overlay card: there is no window of its own to close there.
    var onClose: (() -> Void)?
    private var lastDraft: CFAbsoluteTime = 0
    /// true until the player picks a tempo or meter themselves: the sheet
    /// follows what the performance argues for, not a default 4/4
    private var followsInference = true
    /// true while the sheet sits in the app's overlay card instead of a
    /// window of its own
    private var presented = false

    /// Staff spaces the page holds before wrapping: the window width at
    /// default zoom, minus the sheet's margins.
    private let pageSpaces = SheetEngraver.pageWidth

    init(notes: [NoteEvent], options: SheetDraft.Options = SheetDraft.Options(),
         pedals: [(start: Double, end: Double)] = []) {
        self.notes = notes
        self.pedalSpans = pedals
        self.options = options
        super.init()
    }

    func show(relativeTo parent: NSWindow?) {
        // a new window comes with new content views; the ones the previous
        // window owned are gone with it, and a redraft that still pointed at
        // them painted into a closed window and left this one blank
        contentHost = nil
        scoreView = nil
        tempoPopup = nil
        meterPopup = nil
        emptyLabel = nil
        let size = NSSize(width: 980, height: 720)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sheet music"
        window.minSize = NSSize(width: 760, height: 540)
        // the controller owns this window; without this AppKit releases it on
        // close as well and the next touch of the pointer is a use-after-free
        window.isReleasedWhenClosed = false
        window.contentView = makeContent(size: size)
        if let parent {
            let frame = window.frame
            window.setFrameOrigin(NSPoint(
                x: parent.frame.midX - frame.width / 2,
                y: parent.frame.midY - frame.height / 2
            ))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        self.window = window
        redraft()
    }

    /// The live feed: the app calls this as notes land while a session
    /// runs. The sheet re-engraves immediately, throttled to keep the
    /// extended tails from redrawing more than a few times a second.
    func sync(notes: [NoteEvent]) {
        sync(notes: notes, pedals: nil)
    }

    /// The live feed with optional pedal spans (an imported session's
    /// sustain pedal); the sheet re-engraves with them.
    func sync(notes: [NoteEvent], pedals: [(start: Double, end: Double)]?) {
        guard isOpen else { return }
        self.notes = notes
        if let pedals { self.pedalSpans = pedals }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastDraft > 0.25 else { return }
        redraft()
    }

    func sessionEnded() {
        guard isOpen else { return }
        redraft()
    }

    /// A new session starts a new draft.
    func reset() {
        notes = []
        sync(notes: [])
    }

    var isOpen: Bool {
        presented || window?.isVisible == true
    }

    // MARK: in-window presentation

    /// The sheet's content, built for the app's overlay card instead of a
    /// window: same paper, same choices bar, same live redraft.
    func overlayContent(size: NSSize = NSSize(width: 980, height: 720)) -> NSView {
        // the card hosts fresh views: anything the previous card owned is
        // gone, so drop the pointers before rebuilding
        contentHost = nil
        scoreView = nil
        tempoPopup = nil
        meterPopup = nil
        emptyLabel = nil
        presented = true
        let root = makeContent(size: size, paper: false)
        redraft()
        return root
    }

    /// The card closed: its views went with it, and the next presentation
    /// starts from a clean build.
    func overlayDismissed() {
        presented = false
        contentHost = nil
        scoreView = nil
        emptyLabel = nil
    }

    private func redraft() {
        lastDraft = CFAbsoluteTimeGetCurrent()
        if followsInference, notes.count >= 4 {
            options = SheetDraft.inferredOptions(notes: notes)
        }
        let pedalTicks = pedalSpans.map { span in
            SheetDraft.PedalSpan(
                startTick: SheetDraft.ticks(seconds: span.start, options: options),
                endTick: SheetDraft.ticks(seconds: span.end, options: options))
        }
        let result = SheetDraft.draft(notes: notes, options: options, pageWidth: pageSpaces, pedals: pedalTicks)
        guard let host = contentHost else { return }
        syncChoicesBar()
        if let view = scoreView {
            view.update(result: result)
            return
        }
        // nothing played yet: paper with an invitation beats blank paper,
        // which reads as a sheet that failed to load
        if notes.count < 2 {
            showEmptyState(in: host)
            return
        }
        emptyLabel?.removeFromSuperview()
        emptyLabel = nil
        host.subviews.forEach { $0.removeFromSuperview() }
        let view = ScoreView(result: result)
        let scroll = NSScrollView(frame: host.bounds)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = view
        host.addSubview(scroll)
        // constraints, not a frame: on the first redraft the host has not
        // been laid out yet, so its bounds are zero and a frame carries that
        // zero forever - the sheet engraved into nothing
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: host.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        scoreView = view
    }

    /// One centred serif line on the paper while the sheet has nothing to
    /// engrave yet.
    private func showEmptyState(in host: NSView) {
        guard emptyLabel == nil else { return }
        let label = NSTextField(labelWithString: "Play something and the sheet writes itself")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = PaperTheme.displaySerif(22, weight: .regular)
        label.textColor = PaperTheme.secondaryInk
        label.alignment = .center
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        emptyLabel = label
    }

    /// Keeps both popups on the draft's current framing. The tempo list is a
    /// grid of fours, so an inferred tempo that falls between two entries is
    /// added rather than silently left unselected (which rendered blank).
    private func syncChoicesBar() {
        if let popup = tempoPopup {
            let title = "\(Int(options.bpm.rounded())) bpm"
            let grid = stride(from: 40.0, through: 208.0, by: 4.0).map { "\(Int($0)) bpm" }
            if !grid.contains(title) {
                let items = (grid + [title]).sorted {
                    (Int($0.split(separator: " ").first ?? "0") ?? 0) <
                    (Int($1.split(separator: " ").first ?? "0") ?? 0)
                }
                popup.removeAllItems()
                popup.addItems(withTitles: items)
            }
            popup.selectItem(withTitle: title)
        }
        meterPopup?.selectItem(withTitle: "\(options.numerator)/\(options.denominator)")
    }

    // MARK: content

    private func makeContent(size: NSSize, paper opaque: Bool = true) -> NSView {
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.autoresizingMask = [.width, .height]

        if opaque {
            let paper = PaperView()
            paper.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(paper)
            NSLayoutConstraint.activate([
                paper.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                paper.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                paper.topAnchor.constraint(equalTo: root.topAnchor),
                paper.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }

        let bar = makeChoicesBar()
        root.addSubview(bar)

        let host = NSView(frame: .zero)
        host.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(host)
        contentHost = host

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            bar.heightAnchor.constraint(equalToConstant: 64),

            host.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            host.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 12),
            host.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    /// The framing choices, carried on the card's own glass and closed with a
    /// hairline: a second lens here would be glass on glass.
    private func makeChoicesBar() -> NSView {
        let container = NSView(frame: .zero)
        container.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 18
        row.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 22)
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)

        let rule = HairlineView()
        container.addSubview(rule)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            row.topAnchor.constraint(equalTo: container.topAnchor),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let tempo = makePopup(items: stride(from: 40.0, through: 208.0, by: 4.0).map { "\(Int($0)) bpm" })
        tempo.selectItem(withTitle: "\(Int(options.bpm.rounded())) bpm")
        tempo.target = self
        tempo.action = #selector(tempoChanged)
        tempoPopup = tempo

        let meters = ["2/4", "3/4", "4/4", "6/8", "12/8"]
        let meter = makePopup(items: meters)
        let current = "\(options.numerator)/\(options.denominator)"
        meter.selectItem(withTitle: meters.contains(current) ? current : "4/4")
        meter.target = self
        meter.action = #selector(meterChanged)
        meterPopup = meter

        let close = NSButton(title: "Close", target: self, action: #selector(closeTapped))
        close.bezelStyle = .glass
        close.borderShape = .capsule
        close.controlSize = .regular

        for item in [tempo, meter] {
            let caption = item == tempo ? "Tempo" : "Meter"
            row.addArrangedSubview(captioned(item, caption: caption))
        }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(close)
        return container
    }

    private func captioned(_ control: NSView, caption: String) -> NSStackView {
        let label = makeInkLabel(caption, font: .systemFont(ofSize: 11, weight: .medium), color: PaperTheme.secondaryInk)
        let stack = NSStackView(views: [label, control])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        return stack
    }

    private func makePopup(items: [String]) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.addItems(withTitles: items)
        popup.font = .systemFont(ofSize: 13, weight: .medium)
        popup.contentTintColor = PaperTheme.ink
        return popup
    }

    // MARK: actions

    @objc private func tempoChanged() {
        guard let title = tempoPopup?.titleOfSelectedItem,
              let bpm = Double(title.replacingOccurrences(of: " bpm", with: "")) else { return }
        options.bpm = bpm
        followsInference = false
        redraft()
    }

    @objc private func meterChanged() {
        guard let title = meterPopup?.titleOfSelectedItem?.split(separator: "/"),
              title.count == 2,
              let numerator = Int(title[0]),
              let denominator = Int(title[1]) else { return }
        options.numerator = numerator
        options.denominator = denominator
        followsInference = false
        redraft()
    }

    @objc private func closeTapped() {
        if let onClose {
            onClose()
        } else {
            window?.close()
        }
    }
}
