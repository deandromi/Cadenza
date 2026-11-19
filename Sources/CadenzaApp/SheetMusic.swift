import AppKit
import CadenzaCore
@preconcurrency import CoreText
import CoreGraphics
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

/// The engraved score on the paper: grand staff systems drawn with the
/// Bravura music font — real clefs, noteheads, flags, accidentals, rests,
/// augmentation dots and time signature digits — with stems and beams as
/// engraved lines, ledger lines, barlines, a brace, chord symbols and
/// measure numbers. All geometry comes from ScoreLayout; this view only
/// knows how to draw it.
@MainActor
final class ScoreView: NSView {
    // SMuFL codepoints in Bravura (private-use range, per the SMuFL spec)
    private enum Glyph {
        static let gClef: UInt32 = 0xE050
        static let fClef: UInt32 = 0xE062
        static let brace: UInt32 = 0xE002
        static let noteheadWhole: UInt32 = 0xE0A2
        static let noteheadHalf: UInt32 = 0xE0A3
        static let noteheadBlack: UInt32 = 0xE0A4
        static let flag8thUp: UInt32 = 0xE241
        static let flag8thDown: UInt32 = 0xE240
        static let flag16thUp: UInt32 = 0xE245
        static let flag16thDown: UInt32 = 0xE244
        static let augmentationDot: UInt32 = 0xE1E7
        static let restWhole: UInt32 = 0xE4E3
        static let restHalf: UInt32 = 0xE4E4
        static let accidentalSharp: UInt32 = 0xE262
        static let accidentalNatural: UInt32 = 0xE261
        static let accidentalFlat: UInt32 = 0xE260
        static func timeSignatureDigit(_ n: Int) -> UInt32 { 0xE080 + UInt32(n) }
    }

    private let layout: ScoreLayout.Result
    private let musicFont: CTFont
    private let fontSize: CGFloat

    init(layout: ScoreLayout.Result) {
        self.layout = layout
        self.fontSize = 4 * CGFloat(layout.lineGap)
        self.musicFont = MusicFont.ctFont(size: self.fontSize)
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

            // staff lines: a classical hairline
            ink.withAlphaComponent(0.9).setStroke()
            for line in 0...4 {
                strokeLine(from: NSPoint(x: 8, y: top + CGFloat(line) * gap),
                           to: NSPoint(x: bounds.width - 8, y: top + CGFloat(line) * gap), width: 0.8)
                strokeLine(from: NSPoint(x: 8, y: bassTop + CGFloat(line) * gap),
                           to: NSPoint(x: bounds.width - 8, y: bassTop + CGFloat(line) * gap), width: 0.8)
            }

            // the brace joining the two staves: scaled so its ink spans from
            // the treble top line to the bass bottom line, baseline below the
            // top by the glyph's own top offset
            if let braceInfo = MusicFont.info(Glyph.brace) {
                let span = bassBottom - top + 0.4 * gap
                let size = span / (braceInfo.y1 - braceInfo.y0)
                drawGlyph(Glyph.brace,
                          baselineAt: NSPoint(x: 4, y: top + braceInfo.y1 * size),
                          font: MusicFont.ctFont(size: size), color: ink)
            }

            var lastRight = 8.0
            for measure in system.measures {
                let mx = CGFloat(measure.x) + 8
                let mw = CGFloat(measure.width)
                lastRight = mx + mw

                // barline spanning both staves
                ink.withAlphaComponent(0.9).setStroke()
                strokeLine(from: NSPoint(x: mx, y: top), to: NSPoint(x: mx, y: bassBottom), width: 1.0)

                if measure.showsFraming {
                    // clefs: SMuFL baseline sits on the clef's reference line
                    // (G line = second from bottom, F line = second from top)
                    drawGlyph(Glyph.gClef, baselineAt: NSPoint(x: mx + 10, y: yOnTreble(2)), font: musicFont, color: ink)
                    drawGlyph(Glyph.fClef, baselineAt: NSPoint(x: mx + 10, y: yOnBass(6)), font: musicFont, color: ink)
                    var keyX = mx + 10 + 1.9 * gap
                    for glyph in layout.keyGlyphs {
                        let accidental = glyph.accidental == .sharp ? Glyph.accidentalSharp
                            : glyph.accidental == .flat ? Glyph.accidentalFlat : Glyph.accidentalNatural
                        let accWidth = MusicFont.info(accidental).map { $0.width * fontSize } ?? 0.9 * gap
                        drawGlyph(accidental, baselineAt: NSPoint(x: keyX, y: yOnTreble(glyph.treblePosition)), font: musicFont, color: ink)
                        drawGlyph(accidental, baselineAt: NSPoint(x: keyX, y: yOnBass(glyph.bassPosition)), font: musicFont, color: ink)
                        keyX += accWidth + 0.25 * gap
                    }
                    // time signature: digits are 2 spaces tall and centered on
                    // their baseline — numerator above the middle line,
                    // denominator below it
                    let sigX = keyX + 0.6 * gap
                    drawGlyph(Glyph.timeSignatureDigit(layout.beatsPerMeasure), baselineAt: NSPoint(x: sigX, y: trebleBottom - 3 * gap), font: musicFont, color: ink)
                    drawGlyph(Glyph.timeSignatureDigit(layout.beatUnit), baselineAt: NSPoint(x: sigX, y: trebleBottom - gap), font: musicFont, color: ink)
                    drawGlyph(Glyph.timeSignatureDigit(layout.beatsPerMeasure), baselineAt: NSPoint(x: sigX, y: bassBottom - 3 * gap), font: musicFont, color: ink)
                    drawGlyph(Glyph.timeSignatureDigit(layout.beatUnit), baselineAt: NSPoint(x: sigX, y: bassBottom - gap), font: musicFont, color: ink)
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

                // notes on both staves, beamed where they run
                drawStaffNotes(measure.treble, measureX: mx, bottomLineY: trebleBottom, gap: gap, ink: ink)
                drawStaffNotes(measure.bass, measureX: mx, bottomLineY: bassBottom, gap: gap, ink: ink)

                // rests
                if let rest = measure.trebleRest {
                    drawRest(rest, measureX: mx, bottomLineY: trebleBottom, gap: gap, ink: ink)
                }
                if let rest = measure.bassRest {
                    drawRest(rest, measureX: mx, bottomLineY: bassBottom, gap: gap, ink: ink)
                }
            }

            // closing barline of the system
            ink.withAlphaComponent(0.9).setStroke()
            strokeLine(from: NSPoint(x: lastRight, y: top), to: NSPoint(x: lastRight, y: bassBottom), width: 1.0)
        }

        // final barline: thin then thick
        if let lastSystem = layout.systems.last, let last = lastSystem.measures.last {
            let x = CGFloat(last.x + last.width) + 8
            let top = CGFloat(lastSystem.y)
            let bottom = top + 4 * gap + staffGapPx + 4 * gap
            ink.setStroke()
            strokeLine(from: NSPoint(x: x - 3, y: top), to: NSPoint(x: x - 3, y: bottom), width: 1.0)
            strokeLine(from: NSPoint(x: x, y: top), to: NSPoint(x: x, y: bottom), width: 3.5)
        }
    }

    // MARK: notes, stems, beams

    private struct BeamInfo {
        /// y of the beam's center line at the note's stem x
        var beamY: CGFloat
        /// whether a second beam passes at this note
        var secondBeam: Bool
    }

    private func drawStaffNotes(_ notes: [ScoreLayout.Note], measureX: CGFloat, bottomLineY: CGFloat, gap: CGFloat, ink: NSColor) {
        let beams = computeBeams(notes, measureX: measureX, bottomLineY: bottomLineY, gap: gap)
        for (index, note) in notes.enumerated() {
            drawNote(note, beam: beams[index], measureX: measureX, bottomLineY: bottomLineY, gap: gap, ink: ink)
        }
    }

    /// Groups flagged notes into beam runs: consecutive onsets close enough
    /// in x share one beam. A lone flagged note keeps its flag.
    private func computeBeams(_ notes: [ScoreLayout.Note], measureX: CGFloat, bottomLineY: CGFloat, gap: CGFloat) -> [Int: BeamInfo] {
        let flagged = notes.enumerated().filter { $0.element.flags > 0 }.map { $0.offset }
        guard !flagged.isEmpty else { return [:] }
        var beams: [Int: BeamInfo] = [:]
        var run: [Int] = []
        func flush() {
            guard run.count >= 2 else {
                run = []
                return
            }
            let stemUp = notes[run[0]].stemUp
            let xs = run.map { measureX + CGFloat(notes[$0].x) }
            let heads = run.map { noteY(notes[$0], bottomLineY: bottomLineY, gap: gap) }
            // beam line through the outer stem tips (3.5 spaces from the head),
            // slant clamped to half a space; in view coords up is negative y
            let stemLen = 3.5 * gap
            var y1 = heads[0] + (stemUp ? -stemLen : stemLen)
            var y2 = heads[run.count - 1] + (stemUp ? -stemLen : stemLen)
            let slant = max(-0.5 * gap, min(0.5 * gap, y2 - y1))
            y2 = y1 + slant
            // keep the beam at least three spaces clear of every head
            for (position, headY) in heads.enumerated() {
                let fraction = CGFloat(position) / CGFloat(run.count - 1)
                let beamY = y1 + (y2 - y1) * fraction
                let clearance = stemUp ? headY - beamY : beamY - headY
                if clearance < 3 * gap {
                    let shift = 3 * gap - clearance
                    if stemUp { y1 -= shift; y2 -= shift } else { y1 += shift; y2 += shift }
                }
            }
            for (position, index) in run.enumerated() {
                let fraction = CGFloat(position) / CGFloat(run.count - 1)
                beams[index] = BeamInfo(beamY: y1 + (y2 - y1) * fraction,
                                        secondBeam: notes[index].flags >= 2)
            }
            // the beam spans from the first stem to the last
            let stemEdge = (stemUp ? 0.55 : -0.55) * gap
            inkBeam(x1: xs[0] + stemEdge, x2: xs[run.count - 1] + stemEdge,
                    y1: y1, y2: y2, up: stemUp, gap: gap, ink: PaperTheme.ink)
            // second beam across the sixteenth notes, on the far side of the first
            let sixteenths = run.filter { notes[$0].flags >= 2 }
            if !sixteenths.isEmpty {
                let first = run.firstIndex(of: sixteenths[0]) ?? 0
                let last = run.firstIndex(of: sixteenths[sixteenths.count - 1]) ?? run.count - 1
                let offset = (stemUp ? -1 : 1) * 0.34 * gap
                let f1 = CGFloat(first) / CGFloat(run.count - 1)
                let f2 = CGFloat(last) / CGFloat(run.count - 1)
                inkBeam(x1: xs[first] + stemEdge, x2: xs[last] + stemEdge,
                        y1: y1 + offset + (y2 - y1) * f1,
                        y2: y2 + offset + (y2 - y1) * f2,
                        up: stemUp, gap: gap, ink: PaperTheme.ink)
            }
            run = []
        }
        var previousX: CGFloat = -1e9
        for index in flagged.sorted(by: { notes[$0].x < notes[$1].x }) {
            let x = measureX + CGFloat(notes[index].x)
            if x - previousX > 1.5 * ScoreLayout.groupSpacing, !run.isEmpty {
                flush()
            }
            run.append(index)
            previousX = x
        }
        flush()
        return beams
    }

    /// A beam: a filled parallelogram between the outer stem tips, its
    /// thickness extending away from the noteheads (up in view coords means
    /// negative y, so the sign flips).
    private func inkBeam(x1: CGFloat, x2: CGFloat, y1: CGFloat, y2: CGFloat, up: Bool, gap: CGFloat, ink: NSColor) {
        let thickness = 0.48 * gap
        let sign: CGFloat = up ? -1 : 1
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x1, y: y1))
        path.line(to: NSPoint(x: x2, y: y2))
        path.line(to: NSPoint(x: x2, y: y2 + sign * thickness))
        path.line(to: NSPoint(x: x1, y: y1 + sign * thickness))
        path.close()
        ink.setFill()
        path.fill()
    }

    private func noteY(_ note: ScoreLayout.Note, bottomLineY: CGFloat, gap: CGFloat) -> CGFloat {
        bottomLineY - CGFloat(note.staffPosition) * gap / 2
    }

    private func drawNote(_ note: ScoreLayout.Note, beam: BeamInfo?, measureX: CGFloat, bottomLineY: CGFloat, gap: CGFloat, ink: NSColor) {
        // hx is the head's center x; SMuFL noteheads hang from their baseline
        // at the head's vertical center and start at their left edge
        let hx = measureX + CGFloat(note.x)
        let cy = noteY(note, bottomLineY: bottomLineY, gap: gap)

        let headGlyph: UInt32
        switch note.head {
        case .filled: headGlyph = Glyph.noteheadBlack
        case .hollow: headGlyph = Glyph.noteheadHalf
        case .whole: headGlyph = Glyph.noteheadWhole
        }
        let headInfo = MusicFont.info(headGlyph)
        let headWidth = headInfo.map { $0.width * fontSize } ?? 1.18 * gap

        // ledger lines, engraved thin
        if !note.ledgerPositions.isEmpty {
            ink.withAlphaComponent(0.9).setStroke()
            for position in note.ledgerPositions {
                let y = bottomLineY - CGFloat(position) * gap / 2
                strokeLine(from: NSPoint(x: hx - headWidth * 0.75, y: y),
                           to: NSPoint(x: hx + headWidth * 0.75, y: y), width: 0.8)
            }
        }

        // accidental left of the head, vertically centered on the note
        if let accidental = note.accidental {
            let cp = accidental == .sharp ? Glyph.accidentalSharp
                : accidental == .flat ? Glyph.accidentalFlat : Glyph.accidentalNatural
            let accWidth = MusicFont.info(cp).map { $0.width * fontSize } ?? 0.9 * gap
            drawGlyph(cp, baselineAt: NSPoint(x: hx - headWidth / 2 - accWidth - 0.3 * gap, y: cy), font: musicFont, color: ink)
        }

        // the notehead itself
        drawGlyph(headGlyph, baselineAt: NSPoint(x: hx - headWidth / 2, y: cy), font: musicFont, color: ink)

        // stem: up on the right side of the head, down on the left; it runs
        // to the beam when beamed, else a standard 3.5-space stem with a flag
        if note.head != .whole {
            let stemWidth = 0.12 * gap
            let stemX = note.stemUp ? hx + headWidth / 2 - stemWidth : hx - headWidth / 2
            let fromY = note.stemUp ? cy + 0.1 * gap : cy - 0.1 * gap
            let toY: CGFloat
            if let beam {
                toY = note.stemUp ? beam.beamY + 0.1 * gap : beam.beamY - 0.1 * gap
            } else {
                toY = note.stemUp ? cy - 3.5 * gap : cy + 3.5 * gap
            }
            ink.setStroke()
            strokeLine(from: NSPoint(x: stemX, y: fromY), to: NSPoint(x: stemX, y: toY), width: stemWidth)
            if beam == nil, note.flags > 0 {
                let flag: UInt32
                if note.flags >= 2 {
                    flag = note.stemUp ? Glyph.flag16thUp : Glyph.flag16thDown
                } else {
                    flag = note.stemUp ? Glyph.flag8thUp : Glyph.flag8thDown
                }
                // the flag's origin sits on the stem at its tip
                drawGlyph(flag, baselineAt: NSPoint(x: stemX, y: toY), font: musicFont, color: ink)
            }
        }

        // augmentation dots in the space above when the head is on a line
        if note.dots > 0 {
            let dotY = note.staffPosition % 2 == 0 ? cy - gap / 2 : cy
            for dot in 0..<note.dots {
                drawGlyph(Glyph.augmentationDot,
                          baselineAt: NSPoint(x: hx + headWidth / 2 + 0.3 * gap + CGFloat(dot) * 0.6 * gap, y: dotY),
                          font: musicFont, color: ink)
            }
        }
    }

    // MARK: rests and text

    private func drawRest(_ rest: ScoreLayout.Rest, measureX: CGFloat, bottomLineY: CGFloat, gap: CGFloat, ink: NSColor) {
        // a whole rest hangs below its baseline (the fourth line), a half
        // rest sits on it (the middle line)
        let cp = rest.whole ? Glyph.restWhole : Glyph.restHalf
        let x = measureX + CGFloat(rest.x)
        let y = bottomLineY - CGFloat(rest.staffPosition) * gap / 2
        let width = MusicFont.info(cp).map { $0.width * fontSize } ?? gap
        drawGlyph(cp, baselineAt: NSPoint(x: x - width / 2, y: y), font: musicFont, color: ink)
    }

    /// Draws one music glyph with its SMuFL baseline exactly at the anchor
    /// point (a clef's baseline is its reference line, a notehead's its
    /// center), upright inside the flipped view. CoreText draws the glyph
    /// with its origin on the baseline, which NSString drawing does not
    /// guarantee for fonts with unusual metrics like Bravura.
    private func drawGlyph(_ codepoint: UInt32, baselineAt point: NSPoint, font: CTFont, color: NSColor) {
        guard let info = MusicFont.info(codepoint) else { return }
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        color.setFill()
        cg.saveGState()
        cg.translateBy(x: point.x, y: point.y)
        cg.scaleBy(x: 1, y: -1)
        var glyph = info.glyph
        var origin = CGPoint.zero
        CTFontDrawGlyphs(font, &glyph, &origin, 1, cg)
        cg.restoreGState()
    }

    /// Draws a line of UI text upright, anchored at its top edge.
    private func drawText(_ text: String, at point: NSPoint, font: NSFont, color: NSColor) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: color]
        ))
        var ascent = CGFloat.zero
        var descent = CGFloat.zero
        var leading = CGFloat.zero
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        color.setFill()
        cg.saveGState()
        cg.translateBy(x: point.x, y: point.y + ascent)
        cg.scaleBy(x: 1, y: -1)
        CTLineDraw(line, cg)
        cg.restoreGState()
    }

    private func strokeLine(from: NSPoint, to: NSPoint, width: CGFloat) {
        let path = NSBezierPath()
        path.move(to: from)
        path.line(to: to)
        path.lineWidth = width
        path.stroke()
    }
}
