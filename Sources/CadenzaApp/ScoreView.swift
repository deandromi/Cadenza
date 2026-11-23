import AppKit
import CadenzaCore
@preconcurrency import CoreText
import CoreGraphics

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
        /// A metronome mark's quarter note, the SMuFL glyph editions set.
        static let metNoteQuarterUp: UInt32 = 0xECA5
        static let pedalDownMark: UInt32 = 0xE650
        static let pedalUpMark: UInt32 = 0xE655
        static func timeSignatureDigit(_ n: Int) -> UInt32 { 0xE080 + UInt32(n) }
    }

    private let marginX: CGFloat = 26

    /// Where the sheet's ink really starts and ends, in staff spaces from the
    /// row's own origin: the brace overhangs the first barline, and the closing
    /// barline is a thick stroke. A printer that framed the page on the nominal
    /// width instead of the ink set the music against the paper's edge.
    static let inkLeftInset: Double = 2.888 - 1.15
    static let inkRightInset: Double = 0.9
    /// The left edge of a system's ink, in points: the brace hangs outside the
    /// first barline, and `marginX` is where that barline stands. A system's
    /// staff runs from here to `inkRightX` and nowhere else, so every printed
    /// line shares one left edge and one right edge.
    static func inkLeftX(gap: CGFloat) -> CGFloat { 26 - 1.15 * gap }
    static func inkRightX(rowWidth: Double, gap: CGFloat) -> CGFloat {
        26 + CGFloat(rowWidth) * gap + CGFloat(inkRightInset) * gap
    }
    static func inkWidth(rowWidth: Double, gap: CGFloat) -> CGFloat {
        inkRightX(rowWidth: rowWidth, gap: gap) - inkLeftX(gap: gap)
    }
    /// Air above the first system: high ledger lines reach six spaces up.
    var topInset: CGFloat = 56
    /// The metronome mark belongs over the first system of the piece, not to
    /// the page furniture: a music glyph set through an attributed string in
    /// page space scattered stray heads across the paper.
    var showsTempoMark = false
    /// One printed page of rows, and where its first row starts, in points
    /// from the top of the view. The screen leaves this nil and gets the whole
    /// scroll; a page never has to reason about page gaps or offsets itself,
    /// which is where a printed system used to land outside its own staff.
    struct Page: Sendable, Equatable {
        var rows: Range<Int>
        var top: CGFloat
        /// The distance between two systems on this page. A printed page is
        /// filled to the bottom margin, so the pitch is the page's own number
        /// and not the draft's.
        var pitch: CGFloat = 0
    }
    var page: Page?
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

    /// Rows stack at one pitch. On the screen a page gap keeps the printed
    /// pages apart; a printed page draws one page and needs no gap at all.
    private func systemTop(_ rowIndex: Int, rowHeight: CGFloat) -> CGFloat {
        if let page, page.pitch > 0 { return CGFloat(rowIndex) * page.pitch }
        guard page == nil else { return CGFloat(rowIndex) * rowHeight }
        var y = CGFloat(rowIndex) * rowHeight
        let perPage = result.rowsPerPage
        if perPage > 0 {
            y += CGFloat(rowIndex / perPage) * CGFloat(SheetEngraver.pageBreakSpace)
                * CGFloat(ScoreLayout.lineGap)
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

        let drawnRows: [SheetDraft.Row]
        let originY: CGFloat
        if let page {
            drawnRows = Array(result.rows[page.rows])
            originY = page.top
        } else {
            drawnRows = result.rows
            originY = topInset
        }
        for (offset, row) in drawnRows.enumerated() where offset < drawnRows.count {
            let top = originY + systemTop(offset, rowHeight: rowHeight)
            let trebleBottom = top + 4 * gap
            let bassTop = trebleBottom + staffGapPx
            let bassBottom = bassTop + 4 * gap
            let leftX = marginX
            let rightX = marginX + CGFloat(row.width) * gap

            func yOnTreble(_ position: Int) -> CGFloat { trebleBottom - CGFloat(position) * gap / 2 }
            func yOnBass(_ position: Int) -> CGFloat { bassBottom - CGFloat(position) * gap / 2 }

            // A system owns its own box: nothing it draws may reach into the
            // system above, below or beside it. Clipping here is what keeps a
            // stray stem or a wide accidental from landing on another page.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: leftX - 2.4 * gap,
                                      y: top - 7.5 * gap,
                                      width: rightX - leftX + 4.2 * gap,
                                      height: bassBottom - top + 15 * gap)).addClip()

            // staff lines
            ink.withAlphaComponent(0.9).setStroke()
            for line in 0...4 {
                strokeLine(from: NSPoint(x: leftX, y: top + CGFloat(line) * gap),
                           to: NSPoint(x: rightX, y: top + CGFloat(line) * gap), width: 0.8)
                strokeLine(from: NSPoint(x: leftX, y: bassTop + CGFloat(line) * gap),
                           to: NSPoint(x: rightX, y: bassTop + CGFloat(line) * gap), width: 0.8)
            }

            // A system opens with one barline running through both staves,
            // with the brace outside it: the left edge of a printed system is
            // a single unbroken stroke, not two short ones.
            ink.setStroke()
            strokeLine(from: NSPoint(x: leftX, y: top), to: NSPoint(x: leftX, y: bassBottom),
                       width: 1.1)
            // the brace joining the two staves
            if let braceInfo = MusicFont.info(Glyph.brace) {
                let span = bassBottom - top + 0.4 * gap
                let size = span / (braceInfo.y1 - braceInfo.y0)
                drawGlyph(Glyph.brace,
                          baselineAt: NSPoint(x: leftX - 1.15 * gap, y: top + braceInfo.y1 * size),
                          font: MusicFont.ctFont(size: size), color: ink)
            }

            // clefs: SMuFL baseline sits on the clef's reference line
            let clefX = leftX + 8
            let clefGlyph = row.clefTop == .treble ? Glyph.gClef : Glyph.fClef
            drawGlyph(clefGlyph, baselineAt: NSPoint(x: clefX, y: yOnTreble(2)), font: musicFont, color: ink)
            let bassClefGlyph = row.clefBottom == .treble ? Glyph.gClef : Glyph.fClef
            drawGlyph(bassClefGlyph, baselineAt: NSPoint(x: clefX, y: yOnBass(6)), font: musicFont, color: ink)

            // key signature: each accidental centred on its own line
            var keyX = clefX + 3.9 * gap
            for glyph in ScoreLayout.keyGlyphs(result.fifths) {
                let codepoint = glyph.accidental == .sharp ? Glyph.accidentalSharp
                    : glyph.accidental == .flat ? Glyph.accidentalFlat : Glyph.accidentalNatural
                // A signature is read as a shape, so its marks stand on their
                // lines: set by the glyph's baseline instead, a flat's bowl
                // dropped a space and the whole signature floated above the
                // staff it belongs to.
                inkSignature(codepoint, leftX: keyX, centerY: yOnTreble(glyph.treblePosition), gap: gap, ink: ink)
                inkSignature(codepoint, leftX: keyX, centerY: yOnBass(glyph.bassPosition), gap: gap, ink: ink)
                // Space the signature by the ink each mark actually covers:
                // an advance measured in ems is twice the width a flat prints
                // at, and the time signature landed on the last of them.
                let advance = MusicFont.info(codepoint)
                    .map { CGFloat($0.x1 - $0.x0) * fontSize } ?? 0.9 * gap
                keyX += advance + 0.22 * gap
            }

            // time signature, once at the piece's start, in a column of its
            // own: a digit set by its baseline starts wherever its glyph
            // happens to begin, which printed it against the last accidental
            // of the key.
            if row.showsFraming {
                let sigX = keyX + 0.45 * gap + 0.75 * gap
                func digit(_ number: Int, baselineY: CGFloat) {
                    let codepoint = Glyph.timeSignatureDigit(number)
                    guard let info = MusicFont.info(codepoint) else { return }
                    let dx = (CGFloat(info.x0) + CGFloat(info.x1)) / 2 * fontSize
                    drawGlyph(codepoint, baselineAt: NSPoint(x: sigX - dx, y: baselineY),
                              font: musicFont, color: ink)
                }
                digit(result.options.numerator, baselineY: trebleBottom - 3 * gap)
                digit(result.options.denominator, baselineY: trebleBottom - gap)
                digit(result.options.numerator, baselineY: bassBottom - 3 * gap)
                digit(result.options.denominator, baselineY: bassBottom - gap)
            }

            // the metronome mark, over the piece's first system
            if showsTempoMark, row.showsFraming {
                let markSize = 2.2 * gap
                if let info = MusicFont.info(Glyph.metNoteQuarterUp) {
                    drawGlyph(Glyph.metNoteQuarterUp,
                              baselineAt: NSPoint(x: leftX + 1.2 * gap,
                                                  y: top - 4.3 * gap - CGFloat(info.centerY) * markSize),
                              font: MusicFont.ctFont(size: markSize), color: ink)
                }
                drawText("= \(Int(result.options.bpm.rounded()))",
                         at: NSPoint(x: leftX + 4.1 * gap, y: top - 6.2 * gap),
                         font: .systemFont(ofSize: 10.5, weight: .regular),
                         color: ink)
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

            // a note still sounding at the barline carries a tie over it
            drawTies(row: row, track: 0, yOn: yOnTreble, gap: gap, ink: ink)
            drawTies(row: row, track: 1, yOn: yOnBass, gap: gap, ink: ink)
            drawSlurs(row: row, track: 0, yOn: yOnTreble, gap: gap, ink: ink)
            drawSlurs(row: row, track: 1, yOn: yOnBass, gap: gap, ink: ink)

            // the sustain pedal, written where the score puts it
            drawPedals(row.bottom, bassBottom: bassBottom, rightX: rightX, gap: gap, ink: ink)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // MARK: ties

    /// The ties the engraver wrote, drawn as two halves either side of the
    /// barline the way a score sets them: one arc closing the measure, one
    /// opening the next. Nothing here guesses — if the model did not ask for
    /// a tie, no curve appears.
    /// Phrase marks: one arc over (or under) the notes a player joined. The
    /// run's own notes decide the side of the staff and the height of the
    /// arc, so a phrase in the treble bows over the melody instead of
    /// crossing the staff.
    private func drawSlurs(row: SheetDraft.Row, track: Int,
                           yOn: (Int) -> CGFloat, gap: CGFloat, ink: NSColor) {
        let slurs = result.slurs.filter { $0.track == track }
        guard !slurs.isEmpty else { return }
        let placed = track == 0 ? row.top : row.bottom
        var chords: [Int: SheetDraft.Chord] = [:]
        var xs: [Int: CGFloat] = [:]
        for item in placed {
            guard case .chord(let chord) = item.symbol else { continue }
            chords[chord.startTicks] = chord
            xs[chord.startTicks] = marginX + CGFloat(item.x) * gap
        }
        for slur in slurs where slur.track == track {
            guard let fromX = xs[slur.fromTicks], let toX = xs[slur.toTicks],
                  toX > fromX,
                  let fromChord = chords[slur.fromTicks], let toChord = chords[slur.toTicks]
            else { continue }
            // A slur hangs opposite the stems, clear of the noteheads at both
            // ends: 1.05 spaces outside the head is what keeps it legible on
            // a staff this size, and it never cuts through an inner note.
            let fromPositions = fromChord.notes.map(\.staffPosition)
            let toPositions = toChord.notes.map(\.staffPosition)
            guard let fromHigh = fromPositions.max(), let toHigh = toPositions.max(),
                  let fromLow = fromPositions.min(), let toLow = toPositions.min() else { continue }
            // A phrase mark joins notes a player joined. A curve that has to
            // climb two octaves to reach its other end is not a phrase: it is
            // the transcription tying a low accompaniment chord to a melody
            // note, and drawn it reads as a stray line across the staff.
            guard abs(fromHigh - toHigh) <= 6 else { continue }
            // A phrase mark follows the melody, so it hangs from the higher of
            // the two ends and not from each end separately. A curve that
            // leaves one head high and arrives at the next one low prints as a
            // rule drawn across the staff, which is what a slur looks like
            // when the transcription joins a melody note to an accompaniment
            // chord. The arc keeps one height; the notes move under it.
            _ = (fromLow, toLow)
            let above = true
            let startEdge = max(fromHigh, toHigh)
            let lift = 1.05 * gap
            // A slur leaves the edge of a head, not its centre: an arc drawn
            // from the middle of a notehead reads as a stem through the note.
            let start = NSPoint(x: fromX + 0.58 * gap, y: yOn(startEdge) - lift)
            let end = NSPoint(x: toX - 0.58 * gap, y: yOn(startEdge) - lift)
            guard end.x - start.x > 0.8 * gap else { continue }
            // A long phrase bows a little more than a two-note flick, but a
            // phrase mark is not a rainbow: past a space and a half it starts
            // to read as a second staff line. The bow never falls to nothing,
            // because a slack curve between two distant heads prints as a
            // diagonal rule — the mark has to stay a curve to read as a slur.
            let length = end.x - start.x
            guard length <= 18 * gap else { continue }
            let bow = (above ? -1 : 1) * gap * min(1.5, 0.55 + length / (11 * gap))
            tie(from: start, to: end, bow: bow, gap: gap, ink: ink)
        }
    }

    private func drawTies(row: SheetDraft.Row, track: Int,
                          yOn: (Int) -> CGFloat, gap: CGFloat, ink: NSColor) {
        let ties = result.ties.filter { $0.track == track }
        guard !ties.isEmpty else { return }
        let placed = track == 0 ? row.top : row.bottom
        var chords: [Int: SheetDraft.Chord] = [:]
        var xs: [Int: CGFloat] = [:]
        var barXs: [Int: CGFloat] = [:]
        for item in placed {
            let x = marginX + CGFloat(item.x) * gap
            switch item.symbol {
            case .chord(let chord):
                chords[chord.startTicks] = chord
                xs[chord.startTicks] = x
            case .bar(let start), .finalBar(let start):
                barXs[start] = x
            default:
                break
            }
        }
        let headHalf = 0.58 * gap
        for link in ties {
            guard let fromX = xs[link.fromTicks], let toX = xs[link.toTicks],
                  let chord = chords[link.fromTicks],
                  let note = chord.notes.first(where: { $0.pitch == link.pitch }) else { continue }
            // A tie is one curve from head to head, never two halves: splitting
            // it at a barline is how an edition joins notes across a *system*
            // break, and inside a line it reads as a bracket.
            let y = yOn(note.staffPosition)
            // Opposite the stem, the way a tie is set: a chord whose stems
            // rise carries its ties above the notes, and one that falls below.
            let stemsUp = chord.stems.first?.up ?? (note.staffPosition < 4)
            let away: CGFloat = stemsUp ? -1 : 1
            let baseline = y + away * 0.56 * gap
            // A tie over a whole bar bows deeper than one across a beat: a
            // long tie drawn as a flat whisker reads as a staff line.
            let span = max(0, toX - fromX)
            let bow: CGFloat = away * gap * min(0.55, 0.22 + span / (26 * gap))
            let startX = fromX + headHalf + 0.06 * gap
            let endX = toX - headHalf - 0.06 * gap
            guard endX > startX else { continue }
            tie(from: NSPoint(x: startX, y: baseline),
                to: NSPoint(x: endX, y: baseline),
                bow: bow, gap: gap, ink: ink)
        }
    }

    private func tie(from start: NSPoint, to end: NSPoint, bow: CGFloat,
                     gap: CGFloat, ink: NSColor) {
        // A curve shorter than a space reads as a cup inside the head it
        // leaves, not as a tie: a tie that short is the layout's fault, and
        // nothing is better than something illegible.
        guard end.x - start.x > 1.25 * gap else { return }
        let path = NSBezierPath()
        path.move(to: start)
        let lift = abs(end.x - start.x) > 2.2 * gap ? bow : bow * 0.75
        path.curve(to: end,
                   controlPoint1: NSPoint(x: start.x + (end.x - start.x) * 0.3, y: start.y + lift),
                   controlPoint2: NSPoint(x: start.x + (end.x - start.x) * 0.7, y: end.y + lift))
        path.lineWidth = 0.13 * gap
        ink.setStroke()
        path.stroke()
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
        case .restVoiced(_, let kind, _):
            // the engraver placed this rest clear of the other voice's chord,
            // above or below it and to the right of its stem
            let shift = -CGFloat(placed.yOffset) * gap
            drawRest(kind, at: x + CGFloat(placed.xOffset) * gap,
                     yOn: { yOn($0) + shift }, gap: gap, ink: ink)
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
        guard !placed.isEmpty else { return }
        // The pedal line runs under everything the bass staff already prints,
        // so a low chord or a ledger line never crosses "Ped.".
        let deepest = lowestPrintedPosition(placed)
        let inkBottom = bassBottom - CGFloat(deepest) * gap / 2
        let lineY = min(max(bassBottom + 2.4 * gap, inkBottom + 1.4 * gap),
                         bassBottom + 6.0 * gap)
        // Bravura draws "Ped." and its release star at the size of a clef.
        // Set at the staff's own size they stand as tall as the staff itself
        // and shout across the page; a pedal mark is a footnote under the
        // staff, about a space and a half tall, the way an edition sets it.
        func markFont(_ codepoint: UInt32) -> (font: CTFont, size: CGFloat) {
            guard let info = MusicFont.info(codepoint) else { return (musicFont, fontSize) }
            let height = max(0.2, CGFloat(info.y1 - info.y0))
            let size = 1.5 * gap / height
            return (MusicFont.ctFont(size: size), size)
        }
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
                    let mark = markFont(Glyph.pedalDownMark)
                    let x = pedalX(item)
                    drawGlyph(Glyph.pedalDownMark, baselineAt: NSPoint(x: x, y: lineY),
                              font: mark.font, color: ink)
                    openX = x + info.width * mark.size * 0.85
                }
            case .pedalUp:
                if let info = MusicFont.info(Glyph.pedalUpMark) {
                    let mark = markFont(Glyph.pedalUpMark)
                    let x = pedalX(item)
                    if let start = openX, x > start {
                        ink.withAlphaComponent(0.75).setStroke()
                        strokeLine(from: NSPoint(x: start, y: lineY), to: NSPoint(x: x, y: lineY), width: 0.9)
                    }
                    // the star hangs centered on the line
                    drawGlyph(Glyph.pedalUpMark,
                              baselineAt: NSPoint(x: x, y: lineY + info.centerY * mark.size),
                              font: mark.font, color: ink)
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

    /// The low edge of a staff's printed ink, in staff positions: the lowest
    /// note of the lowest chord, or where a voice's rests sit.
    private func lowestPrintedPosition(_ placed: [SheetDraft.Placed]) -> Int {
        var lowest = 0
        for item in placed {
            switch item.symbol {
            case .chord(let chord):
                for note in chord.notes { lowest = min(lowest, note.staffPosition) }
            case .restVoiced(_, _, let voice):
                lowest = min(lowest, voice == 0 ? -2 : -4)
            default:
                break
            }
        }
        return lowest
    }

    /// Rests are placed by their ink, not by their baseline: a whole rest
    /// hangs from the fourth line, a half rest sits on the middle line, and
    /// the hooked rests are centred on it. Their baselines differ from glyph
    /// to glyph, their boxes do not.
    private func drawRest(_ kind: SheetDraft.RestKind, at x: CGFloat, yOn: (Int) -> CGFloat, gap: CGFloat, ink: NSColor) {
        let codepoint: UInt32
        switch kind {
        case .whole: codepoint = Glyph.restWhole
        case .half: codepoint = Glyph.restHalf
        case .eighth: codepoint = Glyph.restEighth
        case .sixteenth: codepoint = Glyph.restSixteenth
        default: codepoint = Glyph.restQuarter
        }
        let info = MusicFont.info(codepoint)
        let width = (info?.width ?? 1) * fontSize
        var baselineY: CGFloat
        switch kind {
        case .whole:
            // its top edge touches the fourth line and it hangs below it
            baselineY = yOn(6) + CGFloat(info?.y1 ?? 0) * fontSize
        case .half:
            // it sits on the middle line
            baselineY = yOn(4) + CGFloat(info?.y0 ?? 0) * fontSize
        default:
            baselineY = yOn(4) + CGFloat(info?.centerY ?? 0) * fontSize
        }
        if kind == .whole, info == nil { baselineY = yOn(6) }
        drawGlyph(codepoint, baselineAt: NSPoint(x: x - width / 2, y: baselineY), font: musicFont, color: ink)
    }

    private func drawChord(_ chord: SheetDraft.Chord, at x: CGFloat, yOn: (Int) -> CGFloat, gap: CGFloat, ink: NSColor) {
        // Two heads a second apart would sit on top of each other. Engraving
        // shifts the lower one left by a whole head so both stay round; a
        // nudge is what left a chord looking like a smudge of overlapping
        // ovals. The rule lives in ChordInk, which the engraver reads too: the
        // room a displaced head needs is ink it has to reserve.
        let byPosition = chord.notes.indices.sorted { chord.notes[$0].staffPosition < chord.notes[$1].staffPosition }
        let columns = ChordInk.headColumns(chord.notes.map(\.staffPosition))
        let shift = CGFloat(ChordInk.secondStep) * gap
        let headGlyphWidth = (MusicFont.info(Glyph.noteheadBlack).map { CGFloat($0.width) } ?? 1.18) * fontSize
        let chordLeft = x + CGFloat(columns.min() ?? 0) * shift - headGlyphWidth / 2
        let chordRight = x + CGFloat(columns.max() ?? 0) * shift + headGlyphWidth / 2

        // Accidentals stand in columns to the left of the chord, never on top
        // of a head: two of them a second apart would otherwise print as one
        // smudged mark over the note it does not belong to. Which column each
        // one takes, and how wide that stack is, is the engraver's own
        // question too — it reserves the room — so both read one table.
        let accidentalMarks = byPosition.compactMap { index -> (position: Int, kind: AccidentalInk.Kind)? in
            guard let kind = chord.notes[index].accidental.ink else { return nil }
            return (chord.notes[index].staffPosition, kind)
        }
        let accidentalColumns = AccidentalInk.columns(accidentalMarks)
        var accidentalColumn = [Int](repeating: 0, count: chord.notes.count)
        var mark = 0
        for index in byPosition where chord.notes[index].accidental.ink != nil {
            accidentalColumn[index] = accidentalColumns[mark]
            mark += 1
        }

        // heads, their ledger lines, accidentals and dots
        for (index, note) in chord.notes.enumerated() {
            let cx = x + CGFloat(columns[index]) * shift
            let cy = yOn(note.staffPosition)
            if !note.ledgers.isEmpty {
                ink.withAlphaComponent(0.9).setStroke()
                for position in note.ledgers {
                    let y = yOn(position)
                    strokeLine(from: NSPoint(x: chordLeft - 0.06 * gap, y: y),
                               to: NSPoint(x: chordRight + 0.06 * gap, y: y), width: 0.85)
                }
            }
            if note.accidental != .none {
                let cp = note.accidental == .sharp ? Glyph.accidentalSharp
                    : note.accidental == .flat ? Glyph.accidentalFlat : Glyph.accidentalNatural
                let acc = MusicFont.info(cp)
                let accWidth = (acc?.width ?? 0.9) * fontSize
                // A flat's bounding box runs from the bowl up the stem, so
                // centring the box drops its bowl a space below the line.
                // The bowl is the part that must sit on the note's line.
                let accY = note.accidental == .flat ? cy - 0.9 * gap : cy
                let columnX = chordLeft
                    - CGFloat(AccidentalInk.glyphGap) * gap
                    - CGFloat(accidentalColumn[index]) * CGFloat(AccidentalInk.columnStep) * gap
                    - accWidth / 2
                inkGlyph(cp, centerX: columnX, centerY: accY, gap: gap, ink: ink)
            }
            let headGlyph = note.head == .whole ? Glyph.noteheadWhole
                : note.head == .half ? Glyph.noteheadHalf : Glyph.noteheadBlack
            inkHead(headGlyph, centerX: cx, centerY: cy, gap: gap, ink: ink)
        }

        // Dots belong to the chord, not to one head inside it: they line up
        // past the rightmost head and stagger only when two dots would land on
        // each other.
        var drawnDotYs: [CGFloat] = []
        for (index, note) in chord.notes.enumerated() where note.dots > 0 {
            for column in 0..<note.dots {
                // A dot belongs to its own head: past the chord's rightmost
                // head, a dot for a note at the bottom of a wide chord floats
                // beside nothing at all.
                let onLine = note.staffPosition % 2 == 0
                var y = onLine ? yOn(note.staffPosition + 1) : yOn(note.staffPosition)
                while drawnDotYs.contains(where: { abs($0 - y) < gap * 0.45 }) {
                    y -= gap
                }
                drawnDotYs.append(y)
                ink.setFill()
                let centre = NSPoint(x: x + CGFloat(columns[index]) * shift + headGlyphWidth / 2
                                        + 0.34 * gap + CGFloat(column) * 0.62 * gap, y: y)
                let radius = 0.145 * gap
                NSBezierPath(ovalIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                            width: radius * 2, height: radius * 2)).fill()
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
                let flagShift = MusicFont.info(flag).map { -CGFloat($0.x0) * fontSize } ?? 0
                drawGlyph(flag, baselineAt: NSPoint(x: stemX + flagShift, y: nearY),
                          font: musicFont, color: ink)
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
            // The beam belongs to the staff its chords were written on. The
            // group carries that as its track, and it must be believed: symbol
            // indices are numbered per staff, so every bass index also exists
            // in the treble's own list, and a lookup that guesses from the
            // index alone beams the left hand against the right hand's staff —
            // a bar's stems shooting from the bass up through the treble.
            let onTop = group.track == 0
            let map = onTop ? topMap : bottomMap
            let yOn = onTop ? topY : bottomY
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
    /// One accidental of a key signature, left edge at `leftX` and standing on
    /// the line it belongs to. A flat's bowl is the part that must sit on the
    /// line — its box also covers the stem that rises above it — so the flat
    /// is lifted by the height of that stem and centred by the box.
    private func inkSignature(_ codepoint: UInt32, leftX: CGFloat, centerY: CGFloat,
                              gap: CGFloat, ink: NSColor) {
        guard let info = MusicFont.info(codepoint) else { return }
        // The glyph's own ink starts at its bearing, so the baseline that puts
        // that ink on `leftX` is `leftX` less the bearing. Centring the box on
        // `leftX` instead slid every mark half a glyph to the left, which is
        // what printed the signature into the clef.
        let lift: CGFloat = codepoint == Glyph.accidentalFlat ? 0.9 * gap : 0
        drawGlyph(codepoint,
                  baselineAt: NSPoint(x: leftX - CGFloat(info.x0) * fontSize,
                                      y: centerY - lift + CGFloat(info.centerY) * fontSize),
                  font: musicFont, color: ink)
    }

    /// Inks a glyph so that its bounding box is centred on a staff line or
    /// space. Baselines drift from glyph to glyph; the box never lies.
    private func inkGlyph(_ codepoint: UInt32, centerX: CGFloat, centerY: CGFloat,
                          gap: CGFloat, ink: NSColor) {
        guard let info = MusicFont.info(codepoint) else { return }
        let dx = (CGFloat(info.x0) + CGFloat(info.x1)) / 2 * fontSize
        let dy = CGFloat(info.centerY) * fontSize
        drawGlyph(codepoint, baselineAt: NSPoint(x: centerX - dx, y: centerY + dy),
                  font: musicFont, color: ink)
    }

    /// A notehead sits so that its ink is centred on the note's line: the
    /// glyph's own vertical centre, never its baseline.
    private func inkHead(_ codepoint: UInt32, centerX: CGFloat, centerY: CGFloat,
                         gap: CGFloat, ink: NSColor) {
        guard let info = MusicFont.info(codepoint) else {
            drawGlyph(codepoint, baselineAt: NSPoint(x: centerX, y: centerY),
                      font: musicFont, color: ink)
            return
        }
        let dx = (CGFloat(info.x0) + CGFloat(info.x1)) / 2 * fontSize
        drawGlyph(codepoint, baselineAt: NSPoint(x: centerX - dx,
                                                 y: centerY + CGFloat(info.centerY) * fontSize),
                  font: musicFont, color: ink)
    }

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
