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
    private var lastDraft: CFAbsoluteTime = 0
    /// true until the player picks a tempo or meter themselves: the sheet
    /// follows what the performance argues for, not a default 4/4
    private var followsInference = true
    /// true while the sheet sits in the app's overlay card instead of a
    /// window of its own
    private var presented = false

    /// Staff spaces the page holds before wrapping: the window width at
    /// default zoom, minus the sheet's margins.
    private let pageSpaces: Double = 86

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
        presented = true
        let root = makeContent(size: size)
        redraft()
        return root
    }

    /// The card closed: its views went with it, and the next presentation
    /// starts from a clean build.
    func overlayDismissed() {
        presented = false
        contentHost = nil
        scoreView = nil
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
        if let view = scoreView {
            view.update(result: result)
            return
        }
        tempoPopup?.selectItem(withTitle: "\(Int(options.bpm)) bpm")
        meterPopup?.selectItem(withTitle: "\(options.numerator)/\(options.denominator)")
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

    /// One glass lens carrying the framing choices.
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

        let tempo = makePopup(items: stride(from: 40.0, through: 208.0, by: 4.0).map { "\(Int($0)) bpm" })
        tempo.selectItem(withTitle: "\(Int(options.bpm)) bpm")
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
        close.isBordered = false
        close.font = .systemFont(ofSize: 13, weight: .medium)
        close.contentTintColor = PaperTheme.secondaryInk

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
/// Bravura music font — real clefs, noteheads, flags, rests, accidentals,
/// augmentation dots and time signature digits — with stems, beams,
/// ledger lines and barlines as vector ink. All geometry comes from the
/// SheetDraft result; this view only knows how to draw it.
@MainActor
final class ScoreView: NSView {
    // SMuFL codepoints in Bravura (private-use range, per the SMuFL spec)
    private enum Glyph {
        static let gClef: UInt32 = 0xE050
        static let fClef: UInt32 = 0xE062
        static let brace: UInt32 = 0xE000
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
        static let restQuarter: UInt32 = 0xE4E5
        static let restEighth: UInt32 = 0xE4E6
        static let restSixteenth: UInt32 = 0xE4E7
        static let accidentalSharp: UInt32 = 0xE262
        static let accidentalNatural: UInt32 = 0xE261
        static let accidentalFlat: UInt32 = 0xE260
        static let pedalDownMark: UInt32 = 0xE650
        static let pedalUpMark: UInt32 = 0xE655
        static func timeSignatureDigit(_ n: Int) -> UInt32 { 0xE080 + UInt32(n) }
    }

    private let marginX: CGFloat = 26
    /// Air above the first system: high ledger lines reach six spaces up.
    var topInset: CGFloat = 56
    /// Rows to draw; nil draws the whole sheet. Page by page printing sets
    /// this so a page never cuts a system in half.
    var visibleRows: ClosedRange<Int>?
    private var result: SheetDraft.Result
    private let musicFont: CTFont
    private let fontSize: CGFloat

    init(result: SheetDraft.Result) {
        self.result = result
        self.fontSize = 4 * CGFloat(ScoreLayout.lineGap)
        self.musicFont = MusicFont.ctFont(size: self.fontSize)
        let size = ScoreView.pointSize(of: result)
        super.init(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    /// Swap in a new draft (the live stream re-engraves) and resize.
    func update(result: SheetDraft.Result) {
        self.result = result
        let size = ScoreView.pointSize(of: result)
        setFrameSize(size)
        needsDisplay = true
        if let clip = enclosingScrollView {
            clip.reflectScrolledClipView(clip.contentView)
        }
    }

    /// Where a system starts: rows stack at one pitch, with a page gap
    /// every rowsPerPage systems so pages read as pages.
    private func systemTop(_ rowIndex: Int, rowHeight: CGFloat, gap: CGFloat) -> CGFloat {
        var y = CGFloat(rowIndex) * rowHeight
        let perPage = result.rowsPerPage
        if perPage > 0 {
            y += CGFloat(rowIndex / perPage) * CGFloat(SheetEngraver.pageBreakSpace) * gap
        }
        return y
    }

    static func pointSize(of result: SheetDraft.Result) -> NSSize {
        let gap = ScoreLayout.lineGap
        return NSSize(width: CGFloat(result.width) * gap + 52,
                      height: CGFloat(result.totalHeight) * gap + 56)
    }

    override func draw(_ dirtyRect: NSRect) {
        let gap = CGFloat(ScoreLayout.lineGap)
        let ink = PaperTheme.ink
        let staffGapPx = CGFloat(ScoreLayout.staffGap) * gap
        let rowHeight = CGFloat(result.rowHeight) * gap

        let firstRow = visibleRows?.lowerBound ?? 0
        for (rowIndex, row) in result.rows.enumerated() {
            if let visibleRows, !visibleRows.contains(rowIndex) { continue }
            let top = topInset + systemTop(rowIndex, rowHeight: rowHeight, gap: gap)
                - systemTop(firstRow, rowHeight: rowHeight, gap: gap)
            let trebleBottom = top + 4 * gap
            let bassTop = trebleBottom + staffGapPx
            let bassBottom = bassTop + 4 * gap
            let leftX = marginX
            let rightX = marginX + CGFloat(row.width) * gap

            func yOnTreble(_ position: Int) -> CGFloat { trebleBottom - CGFloat(position) * gap / 2 }
            func yOnBass(_ position: Int) -> CGFloat { bassBottom - CGFloat(position) * gap / 2 }

            // staff lines
            ink.withAlphaComponent(0.9).setStroke()
            for line in 0...4 {
                strokeLine(from: NSPoint(x: leftX, y: top + CGFloat(line) * gap),
                           to: NSPoint(x: rightX, y: top + CGFloat(line) * gap), width: 0.8)
                strokeLine(from: NSPoint(x: leftX, y: bassTop + CGFloat(line) * gap),
                           to: NSPoint(x: rightX, y: bassTop + CGFloat(line) * gap), width: 0.8)
            }

            // the brace joining the two staves
            if let braceInfo = MusicFont.info(Glyph.brace) {
                let span = bassBottom - top + 0.4 * gap
                let size = span / (braceInfo.y1 - braceInfo.y0)
                drawGlyph(Glyph.brace,
                          baselineAt: NSPoint(x: leftX - 0.2 * gap, y: top + braceInfo.y1 * size),
                          font: MusicFont.ctFont(size: size), color: ink)
            }

            // clefs: SMuFL baseline sits on the clef's reference line
            let clefX = leftX + 8
            let clefGlyph = row.clefTop == .treble ? Glyph.gClef : Glyph.fClef
            drawGlyph(clefGlyph, baselineAt: NSPoint(x: clefX, y: yOnTreble(2)), font: musicFont, color: ink)
            let bassClefGlyph = row.clefBottom == .treble ? Glyph.gClef : Glyph.fClef
            drawGlyph(bassClefGlyph, baselineAt: NSPoint(x: clefX, y: yOnBass(6)), font: musicFont, color: ink)

            // key signature
            var keyX = clefX + 2.9 * gap
            for glyph in ScoreLayout.keyGlyphs(result.fifths) {
                let codepoint = glyph.accidental == .sharp ? Glyph.accidentalSharp
                    : glyph.accidental == .flat ? Glyph.accidentalFlat : Glyph.accidentalNatural
                drawGlyph(codepoint, baselineAt: NSPoint(x: keyX, y: yOnTreble(glyph.treblePosition)), font: musicFont, color: ink)
                drawGlyph(codepoint, baselineAt: NSPoint(x: keyX, y: yOnBass(glyph.bassPosition)), font: musicFont, color: ink)
                keyX += 0.95 * gap
            }

            // time signature, once at the piece's start
            if row.showsFraming {
                let sigX = keyX + 0.6 * gap
                drawGlyph(Glyph.timeSignatureDigit(result.options.numerator),
                          baselineAt: NSPoint(x: sigX, y: trebleBottom - 3 * gap), font: musicFont, color: ink)
                drawGlyph(Glyph.timeSignatureDigit(result.options.denominator),
                          baselineAt: NSPoint(x: sigX, y: trebleBottom - gap), font: musicFont, color: ink)
                drawGlyph(Glyph.timeSignatureDigit(result.options.numerator),
                          baselineAt: NSPoint(x: sigX, y: bassBottom - 3 * gap), font: musicFont, color: ink)
                drawGlyph(Glyph.timeSignatureDigit(result.options.denominator),
                          baselineAt: NSPoint(x: sigX, y: bassBottom - gap), font: musicFont, color: ink)
            }

            // measure number at the row's opening barline
            drawText("\(row.firstMeasure)",
                    at: NSPoint(x: leftX + 2, y: top - 1.6 * gap),
                    font: .systemFont(ofSize: 10, weight: .medium),
                    color: PaperTheme.secondaryInk)

            // symbols
            for placed in row.top {
                drawSymbol(placed, lyricsY: nil, yOn: yOnTreble, top: top, bottom: trebleBottom,
                           systemTop: top, systemBottom: bassBottom, gap: gap, ink: ink)
            }
            for placed in row.bottom {
                drawSymbol(placed, lyricsY: nil, yOn: yOnBass, top: bassTop, bottom: bassBottom,
                           systemTop: top, systemBottom: bassBottom, gap: gap, ink: ink)
            }

            // beams across the row's members
            drawBeams(row: row, topY: yOnTreble, bottomY: yOnBass, gap: gap, ink: ink)

        }
    }

    // MARK: symbols

    private func drawSymbol(_ placed: SheetDraft.Placed, lyricsY: Double?,
                            yOn: (Int) -> CGFloat,
                            top: CGFloat, bottom: CGFloat,
                            systemTop: CGFloat, systemBottom: CGFloat,
                            gap: CGFloat, ink: NSColor) {
        let x = marginX + CGFloat(placed.x) * gap
        switch placed.symbol {
        case .blank:
            return
        case .bar:
            ink.withAlphaComponent(0.9).setStroke()
            strokeLine(from: NSPoint(x: x, y: systemTop), to: NSPoint(x: x, y: systemBottom), width: 1.0)
        case .finalBar:
            ink.setStroke()
            strokeLine(from: NSPoint(x: x - 3, y: systemTop), to: NSPoint(x: x - 3, y: systemBottom), width: 1.0)
            strokeLine(from: NSPoint(x: x, y: systemTop), to: NSPoint(x: x, y: systemBottom), width: 3.5)
        case .clefChange(let clef, _):
            return
        case .rest(_, let kind):
            drawRest(kind, at: x, yOn: yOn, gap: gap, ink: ink)
        case .chord(let chord):
            drawChord(chord, at: x, yOn: yOn, gap: gap, ink: ink)
        case .timeSignature:
            break
        case .pedalDown, .pedalUp:
            break
        }
    }

    /// Sustain pedal marks: "Ped." where the pedal goes down, the release
    /// star where it lifts, a line between them, all below the bass staff.
    /// A pedal still down at a row's end runs its line to the final bar.
    private func drawPedals(_ placed: [SheetDraft.Placed], bassBottom: CGFloat, rightX: CGFloat, gap: CGFloat, ink: NSColor) {
        let lineY = bassBottom + 1.55 * gap
        // placed.x is in staff spaces from the row start; convert like the
        // symbol loop does
        func pedalX(_ item: SheetDraft.Placed) -> CGFloat {
            marginX + CGFloat(item.x) * gap
        }
        var openX: CGFloat?
        for item in placed {
            switch item.symbol {
            case .pedalDown:
                if let info = MusicFont.info(Glyph.pedalDownMark) {
                    let x = pedalX(item)
                    drawGlyph(Glyph.pedalDownMark, baselineAt: NSPoint(x: x, y: lineY), font: musicFont, color: ink)
                    openX = x + info.width * fontSize * 0.85
                }
            case .pedalUp:
                if let info = MusicFont.info(Glyph.pedalUpMark) {
                    let x = pedalX(item)
                    if let start = openX, x > start {
                        ink.withAlphaComponent(0.75).setStroke()
                        strokeLine(from: NSPoint(x: start, y: lineY), to: NSPoint(x: x, y: lineY), width: 0.9)
                    }
                    // the star hangs centered on the line
                    drawGlyph(Glyph.pedalUpMark,
                              baselineAt: NSPoint(x: x, y: lineY + info.centerY * fontSize),
                              font: musicFont, color: ink)
                }
                openX = nil
            default:
                break
            }
        }
        if let start = openX {
            ink.withAlphaComponent(0.75).setStroke()
            strokeLine(from: NSPoint(x: start, y: lineY), to: NSPoint(x: rightX, y: lineY), width: 0.9)
        }
    }

    private func drawRest(_ kind: SheetDraft.RestKind, at x: CGFloat, yOn: (Int) -> CGFloat, gap: CGFloat, ink: NSColor) {
        let (codepoint, position): (UInt32, Int)
        switch kind {
        case .whole: (codepoint, position) = (Glyph.restWhole, 6)
        case .half: (codepoint, position) = (Glyph.restHalf, 4)
        case .quarter: (codepoint, position) = (Glyph.restQuarter, 4)
        case .eighth: (codepoint, position) = (Glyph.restEighth, 4)
        case .sixteenth: (codepoint, position) = (Glyph.restSixteenth, 4)
        default: (codepoint, position) = (Glyph.restQuarter, 4)
        }
        let width = MusicFont.info(codepoint).map { $0.width * fontSize } ?? gap
        drawGlyph(codepoint, baselineAt: NSPoint(x: x - width / 2, y: yOn(position)), font: musicFont, color: ink)
    }

    private func drawChord(_ chord: SheetDraft.Chord, at x: CGFloat, yOn: (Int) -> CGFloat, gap: CGFloat, ink: NSColor) {
        // Two heads a second apart would sit on top of each other. Engraving
        // shifts the lower one left and leaves the other under the stem, so
        // the chord stays legible.
        var columns = [Int](repeating: 0, count: chord.notes.count)
        let byPosition = chord.notes.indices.sorted { chord.notes[$0].staffPosition < chord.notes[$1].staffPosition }
        var previousPosition: Int?
        var previousColumn = 0
        for index in byPosition {
            let position = chord.notes[index].staffPosition
            if let previous = previousPosition, position - previous == 1 {
                columns[index] = previousColumn == 0 ? -1 : 0
            }
            previousColumn = columns[index]
            previousPosition = position
        }

        // heads, their ledger lines, accidentals and dots
        for (index, note) in chord.notes.enumerated() {
            let cx = x + CGFloat(columns[index]) * 0.62 * gap
            let cy = yOn(note.staffPosition)
            if !note.ledgers.isEmpty {
                ink.withAlphaComponent(0.9).setStroke()
                for position in note.ledgers {
                    let y = yOn(position)
                    strokeLine(from: NSPoint(x: x - 1.45 * gap, y: y),
                               to: NSPoint(x: x + 1.45 * gap, y: y), width: 0.8)
                }
            }
            if note.accidental != .none {
                let cp = note.accidental == .sharp ? Glyph.accidentalSharp
                    : note.accidental == .flat ? Glyph.accidentalFlat : Glyph.accidentalNatural
                let accWidth = MusicFont.info(cp).map { $0.width * fontSize } ?? 0.9 * gap
                drawGlyph(cp, baselineAt: NSPoint(x: cx - 0.85 * gap - accWidth - 0.2 * gap, y: cy),
                          font: musicFont, color: ink)
            }
            let headGlyph = note.head == .whole ? Glyph.noteheadWhole
                : note.head == .half ? Glyph.noteheadHalf : Glyph.noteheadBlack
            let headInfo = MusicFont.info(headGlyph)
            let headWidth = headInfo.map { $0.width * fontSize } ?? 1.18 * gap
            drawGlyph(headGlyph, baselineAt: NSPoint(x: cx - headWidth / 2, y: cy), font: musicFont, color: ink)
            if note.dots > 0 {
                // a dot beside a line note sits in the space above it
                let onLine = note.staffPosition % 2 == 0
                let dotY = onLine ? cy - gap / 2 : cy
                for dot in 0..<note.dots {
                    drawGlyph(Glyph.augmentationDot,
                              baselineAt: NSPoint(x: cx + headWidth / 2 + 0.45 * gap + CGFloat(dot) * 0.7 * gap,
                                                  y: dotY),
                              font: musicFont, color: ink)
                }
            }
        }

        // Stems run from the head farthest from the tip to 3.5 spaces past
        // the head nearest it: the length is measured from the tip's end,
        // the way an engraver measures it, so a tall chord never grows a
        // stem into the next system.
        for stem in chord.stems {
            let slice = chord.notes[stem.noteRange]
            guard !slice.isEmpty,
                  let farPosition = stem.up ? slice.map(\.staffPosition).min()
                      : slice.map(\.staffPosition).max(),
                  let nearPosition = stem.up ? slice.map(\.staffPosition).max()
                      : slice.map(\.staffPosition).min() else { continue }
            let farY = yOn(farPosition)
            let nearY = yOn(nearPosition)
            let stemX = stem.up ? x + 0.6 * gap : x - 0.6 * gap
            let tipY = stem.up ? nearY - 3.5 * gap : nearY + 3.5 * gap
            ink.setStroke()
            strokeLine(from: NSPoint(x: stemX, y: farY), to: NSPoint(x: stemX, y: tipY),
                       width: 0.12 * gap)
            // A Bravura flag draws its own stem, so it hangs from the head
            // nearest the tip and its hook lands exactly at the tip.
            if stem.flags > 0, stem.beamGroupId == nil {
                let flag = stem.flags >= 2
                    ? (stem.up ? Glyph.flag16thUp : Glyph.flag16thDown)
                    : (stem.up ? Glyph.flag8thUp : Glyph.flag8thDown)
                drawGlyph(flag, baselineAt: NSPoint(x: stemX, y: nearY), font: musicFont, color: ink)
            }
        }
    }

    // MARK: beams

    private func drawBeams(row: SheetDraft.Row, topY: (Int) -> CGFloat, bottomY: (Int) -> CGFloat, gap: CGFloat, ink: NSColor) {
        func placedMap(_ placings: [SheetDraft.Placed]) -> [Int: SheetDraft.Placed] {
            var map: [Int: SheetDraft.Placed] = [:]
            for placed in placings where placed.trackIndex >= 0 {
                map[placed.trackIndex] = placed
            }
            return map
        }
        let topMap = placedMap(row.top)
        let bottomMap = placedMap(row.bottom)

        for group in result.beamGroups {
            let map = group.track == 0 ? topMap : bottomMap
            let yOn = group.track == 0 ? topY : bottomY
            var members: [(x: CGFloat, attach: CGFloat)] = []
            for index in group.chordIndices {
                guard let placed = map[index], case .chord(let chord) = placed.symbol,
                      let stem = chord.stems.first(where: { $0.beamGroupId == group.id }) else { continue }
                let slice = chord.notes[stem.noteRange]
                guard !slice.isEmpty,
                      let position = group.up ? slice.map(\.staffPosition).max()
                          : slice.map(\.staffPosition).min() else { continue }
                members.append((marginX + CGFloat(placed.x) * gap, yOn(position)))
            }
            guard members.count >= 2 else { continue }
            members.sort { $0.x < $1.x }

            let up = group.up
            let sign: CGFloat = up ? -1 : 1
            let stemLength = 3.5 * gap
            var y1 = members[0].attach + sign * stemLength
            var y2 = members[members.count - 1].attach + sign * stemLength
            let slant = max(-0.5 * gap, min(0.5 * gap, y2 - y1))
            y2 = y1 + slant

            // every stem keeps at least three spaces of length
            let span = max(1, members[members.count - 1].x - members[0].x)
            for member in members {
                let t = (member.x - members[0].x) / span
                let beamY = y1 + (y2 - y1) * t
                let clearance = up ? member.attach - beamY : beamY - member.attach
                if clearance < 3 * gap {
                    let shift = 3 * gap - clearance
                    y1 += sign * shift
                    y2 += sign * shift
                }
            }

            // stems run from the head to the beam, then the beam itself
            let stemX: CGFloat = up ? 0.6 * gap : -0.6 * gap
            ink.setStroke()
            for member in members {
                let t = (member.x - members[0].x) / span
                let beamY = y1 + (y2 - y1) * t
                strokeLine(from: NSPoint(x: member.x + stemX, y: member.attach),
                           to: NSPoint(x: member.x + stemX, y: beamY), width: 0.12 * gap)
            }
            inkBeam(x1: members[0].x + stemX, x2: members[members.count - 1].x + stemX,
                    y1: y1, y2: y2, up: up, gap: gap, ink: ink)
            if group.flags >= 2 {
                let offset = sign * 0.55 * gap
                inkBeam(x1: members[0].x + stemX, x2: members[members.count - 1].x + stemX,
                        y1: y1 + offset, y2: y2 + offset, up: up, gap: gap, ink: ink)
            }
        }
    }

    /// A beam: a filled parallelogram between the outer stem tips, its
    /// thickness extending away from the noteheads.
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

    // MARK: glyph and text primitives

    /// Draws one music glyph with its SMuFL baseline exactly at the anchor
    /// point, upright inside the flipped view. CoreText draws the glyph
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
