import AppKit
import CadenzaCore
import UniformTypeIdentifiers

/// The sheet music section: a paper window where the recorded session is
/// framed (tempo, meter, key — the choices step, with the engraver's ranked
/// alternatives on offer) and then engraved onto a grand staff in ink.
/// Chrome is one glass lens along the top; the score is the content.
@MainActor
final class SheetMusicController: NSObject {
    private let notes: [NoteEvent]
    private let chords: [(seconds: Double, symbol: String)]
    private var window: NSWindow?
    private var score: Score?

    // choices controls
    private var tempoPopup: NSPopUpButton?
    private var meterPopup: NSPopUpButton?
    private var keyPopup: NSPopUpButton?
    private var exportButton: NSButton?
    private var contentHost: NSView?
    private var scoreView: ScoreView?

    private var tempoOptions: [Double] = []
    private var meterOptions: [TimeSignature] = []
    private var keyOptions: [KeySignature] = []

    init(notes: [NoteEvent], chords: [(seconds: Double, symbol: String)]) {
        self.notes = notes
        self.chords = chords
        super.init()
    }

    func show(relativeTo parent: NSWindow?) {
        let size = NSSize(width: 1060, height: 720)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sheet music"
        window.minSize = NSSize(width: 860, height: 560)
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
    }

    // MARK: content

    private func makeContent(size: NSSize) -> NSView {
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.autoresizingMask = [.width, .height]

        let paper = PaperView()
        paper.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(paper)

        let bar = makeChoicesBar()
        root.addSubview(bar)

        let host = NSView(frame: .zero)
        host.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(host)
        contentHost = host
        showHint(in: host)

        NSLayoutConstraint.activate([
            paper.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            paper.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            paper.topAnchor.constraint(equalTo: root.topAnchor),
            paper.bottomAnchor.constraint(equalTo: root.bottomAnchor),

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

    /// One glass lens carrying the framing choices and the actions.
    private func makeChoicesBar() -> NSView {
        let container = NSGlassEffectContainerView(frame: .zero)
        container.translatesAutoresizingMaskIntoConstraints = false

        let lens = makeGlassBackdrop(cornerRadius: 20, interactive: true)
        lens.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(lens)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 18
        row.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 22)
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)

        NSLayoutConstraint.activate([
            lens.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            lens.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            lens.topAnchor.constraint(equalTo: container.topAnchor),
            lens.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            row.topAnchor.constraint(equalTo: container.topAnchor),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // the engraver's own picks lead, the ranked alternatives follow
        let grouped = notes.assignOnsetGroups()
        let inferredTempo = Engraver.inferTempo(grouped)
        tempoOptions = Engraver.tempoCandidates(grouped)
        if !tempoOptions.contains(where: { abs($0 - inferredTempo) < 0.5 }) {
            tempoOptions.append(inferredTempo)
            tempoOptions.sort()
        }
        meterOptions = Engraver.scoreMeterCandidates(grouped, tempo: inferredTempo).map(\.signature)
        keyOptions = Array(Engraver.scoreKeyCandidates(grouped).prefix(6))

        let tempo = makePopup(title: "Tempo", items: tempoOptions.map { "\(Int($0.rounded())) bpm" })
        tempo.selectItem(withTitle: "\(Int(inferredTempo.rounded())) bpm")
        tempo.target = self
        tempo.action = #selector(tempoChanged)
        tempoPopup = tempo

        let meter = makePopup(title: "Meter", items: meterOptions.map { "\($0.beatsPerMeasure)/\($0.beatUnit)" })
        meter.selectItem(at: 0)
        meterPopup = meter

        let key = makePopup(title: "Key", items: keyOptions.map(\.name))
        key.selectItem(at: 0)
        keyPopup = key

        let engrave = NSButton(title: "Engrave", target: self, action: #selector(engraveTapped))
        engrave.isBordered = false
        engrave.font = .systemFont(ofSize: 13, weight: .semibold)
        engrave.contentTintColor = PaperTheme.stamp

        let export = NSButton(title: "Export MusicXML", target: self, action: #selector(exportTapped))
        export.isBordered = false
        export.font = .systemFont(ofSize: 13, weight: .medium)
        export.contentTintColor = PaperTheme.ink
        export.isEnabled = false
        exportButton = export

        let close = NSButton(title: "Close", target: self, action: #selector(closeTapped))
        close.isBordered = false
        close.font = .systemFont(ofSize: 13, weight: .medium)
        close.contentTintColor = PaperTheme.secondaryInk

        for item in [tempo, meter, key] {
            row.addArrangedSubview(captioned(item, caption: item == tempo ? "Tempo" : item == meter ? "Meter" : "Key"))
        }
        row.addArrangedSubview(engrave)
        row.addArrangedSubview(export)
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

    private func makePopup(title: String, items: [String]) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.addItems(withTitles: items)
        popup.font = .systemFont(ofSize: 13, weight: .medium)
        popup.contentTintColor = PaperTheme.ink
        return popup
    }

    private func showHint(in host: NSView) {
        host.subviews.forEach { $0.removeFromSuperview() }
        let label = makeInkLabel(
            "Choose the framing, then engrave: your session becomes a sheet here",
            font: PaperTheme.displaySerif(20),
            color: PaperTheme.secondaryInk
        )
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 40),
            label.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -40),
        ])
    }

    // MARK: actions

    @objc private func tempoChanged() {
        guard let tempoPopup, let title = tempoPopup.titleOfSelectedItem,
              let bpm = Double(title.replacingOccurrences(of: " bpm", with: "")) else { return }
        // the meter alternatives depend on the tempo: re-rank them
        let grouped = notes.assignOnsetGroups()
        meterOptions = Engraver.scoreMeterCandidates(grouped, tempo: bpm).map(\.signature)
        meterPopup?.removeAllItems()
        meterPopup?.addItems(withTitles: meterOptions.map { "\($0.beatsPerMeasure)/\($0.beatUnit)" })
        meterPopup?.selectItem(at: 0)
    }

    @objc private func engraveTapped() {
        let bpm = Double(tempoPopup?.titleOfSelectedItem?.replacingOccurrences(of: " bpm", with: "") ?? "120") ?? 120
        let meterIndex = meterPopup?.indexOfSelectedItem ?? 0
        let meter = meterIndex < meterOptions.count ? meterOptions[meterIndex] : TimeSignature(beatsPerMeasure: 4, beatUnit: 4)
        let keyIndex = keyPopup?.indexOfSelectedItem ?? 0
        let key = keyIndex < keyOptions.count ? keyOptions[keyIndex] : KeySignature(tonic: 0, isMinor: false)
        let framing = ScoreFraming(beatsPerMinute: bpm, timeSignature: meter, key: key)

        guard let engraved = Engraver.engrave(notes: notes, chords: chords, framing: framing) else {
            showHint(in: contentHost!)
            return
        }
        score = engraved
        exportButton?.isEnabled = true

        guard let host = contentHost else { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        let layout = ScoreLayout.layout(engraved, width: max(900, host.bounds.width > 0 ? host.bounds.width : 1012) - 48)
        let view = ScoreView(layout: layout)
        // the document view keeps autoresizing: the scroll view sizes it
        let scroll = NSScrollView(frame: host.bounds)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = view
        host.addSubview(scroll)
        scoreView = view
        // size the document view to the layout, and let the window follow
        view.frame = NSRect(x: 0, y: 0, width: layout.width, height: layout.height)
        if let window, layout.height > host.bounds.height {
            var frame = window.frame
            frame.size.height = min(900, host.bounds.height + 120 + (layout.height - host.bounds.height))
            window.setFrame(frame, display: true)
        }
    }

    @objc private func exportTapped() {
        guard let score, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.xml]
        panel.nameFieldStringValue = "Cadenza sheet.musicxml"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try MusicXML.write(score).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                print("sheet export failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func closeTapped() {
        window?.close()
    }
}

/// The engraved score drawn in ink on the paper: grand staff systems, hand-
/// drawn clefs, key glyphs, time signature, noteheads with stems, flags and
/// dots, ledger lines, rests, chord symbols and measure numbers. All
/// geometry comes from ScoreLayout; this view only knows how to draw it.
@MainActor
final class ScoreView: NSView {
    private let layout: ScoreLayout.Result

    init(layout: ScoreLayout.Result) {
        self.layout = layout
        super.init(frame: NSRect(x: 0, y: 0, width: layout.width, height: layout.height))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let gap = CGFloat(layout.lineGap)
        let ink = PaperTheme.ink
        let staffGapPx = CGFloat(ScoreLayout.staffGap) * gap

        for system in layout.systems {
            let top = CGFloat(system.y)
            let trebleBottom = top + 4 * gap
            let bassTop = top + 4 * gap + staffGapPx
            let bassBottom = bassTop + 4 * gap

            func yOnTreble(_ position: Int) -> CGFloat { trebleBottom - CGFloat(position) * gap / 2 }
            func yOnBass(_ position: Int) -> CGFloat { bassBottom - CGFloat(position) * gap / 2 }

            // staff lines
            ink.withAlphaComponent(0.8).setStroke()
            for line in 0...4 {
                let y = top + CGFloat(line) * gap
                NSBezierPath.strokeLine(from: NSPoint(x: 8, y: y), to: NSPoint(x: bounds.width - 8, y: y))
                let yb = bassTop + CGFloat(line) * gap
                NSBezierPath.strokeLine(from: NSPoint(x: 8, y: yb), to: NSPoint(x: bounds.width - 8, y: yb))
            }

            // brace at the left of the system
            drawBrace(x: 14, from: top, to: bassBottom, gap: gap, ink: ink)

            var lastRight = 8.0
            for measure in system.measures {
                let mx = CGFloat(measure.x) + 8
                let mw = CGFloat(measure.width)
                lastRight = mx + mw

                // barline spanning both staves
                ink.withAlphaComponent(0.8).setStroke()
                NSBezierPath.strokeLine(from: NSPoint(x: mx, y: top), to: NSPoint(x: mx, y: bassBottom))

                if measure.showsFraming {
                    drawTrebleClef(x: mx + 6, gLineY: yOnTreble(2), gap: gap, ink: ink)
                    drawBassClef(x: mx + 6, fLineY: yOnBass(6), gap: gap, ink: ink)
                    var keyX = mx + 6 + 2.4 * gap
                    for glyph in layout.keyGlyphs {
                        let y = yOnTreble(glyph.treblePosition)
                        drawAccidentalGlyph(glyph.accidental, x: keyX, y: y, gap: gap, ink: ink)
                        let yb = yOnBass(glyph.bassPosition)
                        drawAccidentalGlyph(glyph.accidental, x: keyX, y: yb, gap: gap, ink: ink)
                        keyX += 1.15 * gap
                    }
                    let sigX = keyX + 0.5 * gap
                    drawTimeSignature(
                        beats: layout.beatsPerMeasure, unit: layout.beatUnit,
                        x: sigX, trebleBottom: trebleBottom, bassBottom: bassBottom,
                        gap: gap, ink: ink
                    )
                }

                // measure number at the top of each system's first measure
                if measure.x == system.measures.first?.x {
                    drawText(
                        "\(measure.index + 1)",
                        at: NSPoint(x: mx + 2, y: top - 1.9 * gap),
                        font: .systemFont(ofSize: 10, weight: .medium),
                        color: PaperTheme.secondaryInk
                    )
                }

                // chord symbol above the treble staff
                if let chord = measure.chord {
                    drawText(
                        chord.symbol,
                        at: NSPoint(x: mx + CGFloat(chord.x), y: top - 2.6 * gap),
                        font: PaperTheme.displaySerif(14, weight: .medium),
                        color: ink
                    )
                }

                // notes on both staves
                for note in measure.treble {
                    drawNote(note, measureX: mx, bottomLineY: trebleBottom, gap: gap, ink: ink)
                }
                for note in measure.bass {
                    drawNote(note, measureX: mx, bottomLineY: bassBottom, gap: gap, ink: ink)
                }

                // rests
                if let rest = measure.trebleRest {
                    drawRest(rest, measureX: mx, bottomLineY: trebleBottom, gap: gap, ink: ink)
                }
                if let rest = measure.bassRest {
                    drawRest(rest, measureX: mx, bottomLineY: bassBottom, gap: gap, ink: ink)
                }
            }

            // closing barline of the system
            ink.withAlphaComponent(0.8).setStroke()
            NSBezierPath.strokeLine(from: NSPoint(x: lastRight, y: top), to: NSPoint(x: lastRight, y: bassBottom))
        }

        // final double barline
        let lastSystem = layout.systems.last
        if let lastSystem, let last = lastSystem.measures.last {
            let x = CGFloat(last.x + last.width) + 8
            let top = CGFloat(lastSystem.y)
            let bottom = top + 4 * gap + staffGapPx + 4 * gap
            PaperTheme.ink.setStroke()
            NSBezierPath.strokeLine(from: NSPoint(x: x - 3, y: top), to: NSPoint(x: x - 3, y: bottom))
            strokeLine(from: NSPoint(x: x, y: top), to: NSPoint(x: x, y: bottom), width: 3)
        }
    }

    // MARK: glyphs

    private func yFor(_ position: Int, bottomLineY: CGFloat, gap: CGFloat) -> CGFloat {
        bottomLineY - CGFloat(position) * gap / 2
    }

    private func drawNote(_ note: ScoreLayout.Note, measureX: CGFloat, bottomLineY: CGFloat, gap: CGFloat, ink: NSColor) {
        let cx = measureX + CGFloat(note.x) - 0.72 * gap
        let cy = yFor(note.staffPosition, bottomLineY: bottomLineY, gap: gap)
        let rx = 0.72 * gap
        let ry = 0.5 * gap

        // ledger lines first, under the head
        ink.withAlphaComponent(0.8).setStroke()
        for position in note.ledgerPositions {
            let y = yFor(position, bottomLineY: bottomLineY, gap: gap)
            NSBezierPath.strokeLine(from: NSPoint(x: cx - rx * 1.35, y: y), to: NSPoint(x: cx + rx * 1.35, y: y))
        }

        // accidental left of the head
        if let accidental = note.accidental {
            drawAccidentalGlyph(accidental, x: cx - rx - 1.1 * gap, y: cy, gap: gap, ink: ink)
        }

        // head
        let headPath = tiltedEllipse(center: NSPoint(x: cx, y: cy), radiusX: rx, radiusY: ry, tilt: -20)
        switch note.head {
        case .filled:
            ink.setFill()
            headPath.fill()
        case .hollow:
            // a half note's head is an open ring: staff lines show through
            ink.setStroke()
            headPath.lineWidth = 1.7
            headPath.stroke()
        case .whole:
            ink.setStroke()
            headPath.lineWidth = 2.2
            headPath.stroke()
        }

        // stem and flags
        if note.head != .whole {
            let stemLength = 3.4 * gap
            let stemX = note.stemUp ? cx + rx * 0.95 : cx - rx * 0.95
            let fromY = note.stemUp ? cy - ry * 0.7 : cy + ry * 0.7
            let toY = note.stemUp ? cy - stemLength : cy + stemLength
            ink.setStroke()
            strokeLine(from: NSPoint(x: stemX, y: fromY), to: NSPoint(x: stemX, y: toY), width: 1.1)
            for flag in 0..<note.flags {
                drawFlag(stemX: stemX, tipY: toY, up: note.stemUp, index: flag, gap: gap, ink: ink)
            }
        }

        // dots, in the space above when the head sits on a line
        if note.dots > 0 {
            let dotY = note.staffPosition % 2 == 0 ? cy - gap / 2 : cy
            for dot in 0..<note.dots {
                let dotX = cx + rx + 0.55 * gap + CGFloat(dot) * 0.55 * gap
                ink.setFill()
                NSBezierPath(ovalIn: NSRect(x: dotX - 0.09 * gap, y: dotY - 0.09 * gap, width: 0.18 * gap, height: 0.18 * gap)).fill()
            }
        }
    }

    private func drawFlag(stemX: CGFloat, tipY: CGFloat, up: Bool, index: Int, gap: CGFloat, ink: NSColor) {
        let sign: CGFloat = up ? -1 : 1
        let baseY = tipY + sign * CGFloat(index) * 0.55 * gap
        let path = NSBezierPath()
        path.move(to: NSPoint(x: stemX, y: baseY))
        path.curve(
            to: NSPoint(x: stemX + 1.05 * gap, y: baseY + sign * (0.9 + 0.35 * CGFloat(index)) * gap),
            controlPoint1: NSPoint(x: stemX + 0.55 * gap, y: baseY + sign * 0.15 * gap),
            controlPoint2: NSPoint(x: stemX + 1.0 * gap, y: baseY + sign * 0.55 * gap)
        )
        path.curve(
            to: NSPoint(x: stemX + 0.45 * gap, y: baseY + sign * (1.5 + 0.35 * CGFloat(index)) * gap),
            controlPoint1: NSPoint(x: stemX + 0.95 * gap, y: baseY + sign * (1.1 + 0.35 * CGFloat(index)) * gap),
            controlPoint2: NSPoint(x: stemX + 0.6 * gap, y: baseY + sign * (1.35 + 0.35 * CGFloat(index)) * gap)
        )
        path.line(to: NSPoint(x: stemX, y: baseY + sign * 0.5 * gap))
        path.close()
        ink.setFill()
        path.fill()
    }

    private func drawRest(_ rest: ScoreLayout.Rest, measureX: CGFloat, bottomLineY: CGFloat, gap: CGFloat, ink: NSColor) {
        let x = measureX + CGFloat(rest.x)
        let y = yFor(rest.staffPosition, bottomLineY: bottomLineY, gap: gap)
        ink.setFill()
        if rest.whole {
            // hangs below the line it sits on
            NSBezierPath.fill(NSRect(x: x - 0.45 * gap, y: y - 0.55 * gap, width: 0.9 * gap, height: 0.55 * gap))
        } else {
            // sits on top of the line
            NSBezierPath.fill(NSRect(x: x - 0.45 * gap, y: y, width: 0.9 * gap, height: 0.55 * gap))
        }
    }

    private func drawAccidentalGlyph(_ accidental: ScoreLayout.Accidental, x: CGFloat, y: CGFloat, gap: CGFloat, ink: NSColor) {
        ink.setStroke()
        let line = { [weak self] (from: NSPoint, to: NSPoint) in
            self?.strokeLine(from: from, to: to, width: 0.15 * gap)
        }
        switch accidental {
        case .sharp:
            line(NSPoint(x: x - 0.22 * gap, y: y - 0.95 * gap), NSPoint(x: x - 0.22 * gap, y: y + 0.95 * gap))
            line(NSPoint(x: x + 0.22 * gap, y: y - 0.95 * gap), NSPoint(x: x + 0.22 * gap, y: y + 0.95 * gap))
            line(NSPoint(x: x - 0.42 * gap, y: y - 0.42 * gap), NSPoint(x: x + 0.42 * gap, y: y - 0.05 * gap))
            line(NSPoint(x: x - 0.42 * gap, y: y + 0.05 * gap), NSPoint(x: x + 0.42 * gap, y: y + 0.42 * gap))
        case .flat:
            line(NSPoint(x: x - 0.28 * gap, y: y - 1.15 * gap), NSPoint(x: x - 0.28 * gap, y: y + 0.55 * gap))
            let bowl = NSBezierPath()
            bowl.move(to: NSPoint(x: x - 0.28 * gap, y: y + 0.55 * gap))
            bowl.curve(to: NSPoint(x: x + 0.55 * gap, y: y - 0.05 * gap), controlPoint1: NSPoint(x: x + 0.45 * gap, y: y + 0.55 * gap), controlPoint2: NSPoint(x: x + 0.6 * gap, y: y + 0.2 * gap))
            bowl.curve(to: NSPoint(x: x - 0.28 * gap, y: y - 0.25 * gap), controlPoint1: NSPoint(x: x + 0.3 * gap, y: y - 0.45 * gap), controlPoint2: NSPoint(x: x - 0.1 * gap, y: y - 0.45 * gap))
            bowl.lineWidth = 0.16 * gap
            bowl.stroke()
        case .natural:
            line(NSPoint(x: x - 0.22 * gap, y: y - 0.95 * gap), NSPoint(x: x - 0.22 * gap, y: y + 0.95 * gap))
            line(NSPoint(x: x + 0.22 * gap, y: y - 0.95 * gap), NSPoint(x: x + 0.22 * gap, y: y + 0.95 * gap))
            line(NSPoint(x: x - 0.42 * gap, y: y + 0.42 * gap), NSPoint(x: x + 0.42 * gap, y: y + 0.05 * gap))
            line(NSPoint(x: x - 0.42 * gap, y: y - 0.05 * gap), NSPoint(x: x + 0.42 * gap, y: y - 0.42 * gap))
        }
    }

    private func drawTimeSignature(beats: Int, unit: Int, x: CGFloat, trebleBottom: CGFloat, bassBottom: CGFloat, gap: CGFloat, ink: NSColor) {
        let font = PaperTheme.displaySerif(2.6 * gap, weight: .semibold)
        for bottom in [trebleBottom, bassBottom] {
            for (text, position) in [("\(beats)", 6), ("\(unit)", 2)] {
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
                let size = (text as NSString).size(withAttributes: attrs)
                let centerY = bottom - CGFloat(position) * gap / 2
                drawText(text, at: NSPoint(x: x, y: centerY - size.height / 2), font: font, color: ink)
            }
        }
    }

    /// Draws a line of text upright inside a flipped view: the context is
    /// flipped locally around the anchor point so glyphs never render
    /// upside down, on screen or in an offscreen bitmap.
    private func drawText(_ text: String, at point: NSPoint, font: NSFont, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attrs)
        NSGraphicsContext.saveGraphicsState()
        if let cg = NSGraphicsContext.current?.cgContext {
            cg.saveGState()
            cg.translateBy(x: point.x, y: point.y)
            cg.scaleBy(x: 1, y: -1)
            (text as NSString).draw(at: NSPoint(x: 0, y: -size.height), withAttributes: attrs)
            cg.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A stylized ink treble clef: a loop around the G line, a spine rising
    /// past the staff and hooking over, a tail dropping below.
    private func drawTrebleClef(x: CGFloat, gLineY: CGFloat, gap: CGFloat, ink: NSColor) {
        ink.setStroke()
        let loop = NSBezierPath(ovalIn: NSRect(
            x: x - 0.52 * gap, y: gLineY - 0.95 * gap,
            width: 1.04 * gap, height: 1.9 * gap
        ))
        loop.lineWidth = 1.3
        loop.stroke()
        let spine = NSBezierPath()
        spine.move(to: NSPoint(x: x + 0.52 * gap, y: gLineY))
        spine.line(to: NSPoint(x: x + 0.52 * gap, y: gLineY - 3.1 * gap))
        spine.curve(
            to: NSPoint(x: x - 0.45 * gap, y: gLineY - 3.0 * gap),
            controlPoint1: NSPoint(x: x + 0.52 * gap, y: gLineY - 3.9 * gap),
            controlPoint2: NSPoint(x: x - 0.1 * gap, y: gLineY - 3.95 * gap)
        )
        spine.lineWidth = 1.3
        spine.stroke()
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: x - 0.52 * gap, y: gLineY))
        tail.curve(
            to: NSPoint(x: x - 0.05 * gap, y: gLineY + 3.0 * gap),
            controlPoint1: NSPoint(x: x - 0.75 * gap, y: gLineY + 1.4 * gap),
            controlPoint2: NSPoint(x: x - 0.6 * gap, y: gLineY + 2.6 * gap)
        )
        tail.lineWidth = 1.3
        tail.stroke()
    }

    /// A stylized ink bass clef: an arc opening left around the F line with
    /// two dots.
    private func drawBassClef(x: CGFloat, fLineY: CGFloat, gap: CGFloat, ink: NSColor) {
        ink.setStroke()
        let arc = NSBezierPath()
        arc.move(to: NSPoint(x: x + 1.15 * gap, y: fLineY - 1.35 * gap))
        arc.curve(to: NSPoint(x: x + 1.15 * gap, y: fLineY + 1.35 * gap), controlPoint1: NSPoint(x: x - 0.75 * gap, y: fLineY - 1.5 * gap), controlPoint2: NSPoint(x: x - 0.75 * gap, y: fLineY + 1.5 * gap))
        arc.lineWidth = 1.5
        arc.stroke()
        ink.setFill()
        for offset in [-0.55, 0.55] {
            NSBezierPath(ovalIn: NSRect(x: x + 1.35 * gap - 0.11 * gap, y: fLineY + CGFloat(offset) * gap - 0.11 * gap, width: 0.22 * gap, height: 0.22 * gap)).fill()
        }
    }

    private func drawBrace(x: CGFloat, from top: CGFloat, to bottom: CGFloat, gap: CGFloat, ink: NSColor) {
        ink.setStroke()
        let path = NSBezierPath()
        let mid = (top + bottom) / 2
        path.move(to: NSPoint(x: x, y: top))
        path.curve(to: NSPoint(x: x + 0.5 * gap, y: mid), controlPoint1: NSPoint(x: x, y: top + (bottom - top) * 0.25), controlPoint2: NSPoint(x: x + 0.45 * gap, y: mid - (bottom - top) * 0.12))
        path.curve(to: NSPoint(x: x, y: bottom), controlPoint1: NSPoint(x: x + 0.45 * gap, y: mid + (bottom - top) * 0.12), controlPoint2: NSPoint(x: x, y: bottom - (bottom - top) * 0.25))
        path.lineWidth = 1.2
        path.stroke()
    }

    private func strokeLine(from: NSPoint, to: NSPoint, width: CGFloat) {
        let path = NSBezierPath()
        path.move(to: from)
        path.line(to: to)
        path.lineWidth = width
        path.stroke()
    }

    private func tiltedEllipse(center: NSPoint, radiusX: CGFloat, radiusY: CGFloat, tilt: CGFloat) -> NSBezierPath {
        let path = NSBezierPath(ovalIn: NSRect(
            x: center.x - radiusX,
            y: center.y - radiusY,
            width: radiusX * 2,
            height: radiusY * 2
        ))
        var transform = AffineTransform(translationByX: center.x, byY: center.y)
        transform.rotate(byDegrees: tilt)
        transform.translate(x: -center.x, y: -center.y)
        path.transform(using: transform)
        return path
    }
}
