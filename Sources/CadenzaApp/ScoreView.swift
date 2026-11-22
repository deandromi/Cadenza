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

            // key signature
            var keyX = clefX + 3.7 * gap
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

            // a note still sounding at the barline carries a tie over it
            drawTies(row: row, track: 0, yOn: yOnTreble, gap: gap, ink: ink)
            drawTies(row: row, track: 1, yOn: yOnBass, gap: gap, ink: ink)

        }
    }

    // MARK: ties

    /// The ties the engraver wrote, drawn as two halves either side of the
    /// barline the way a score sets them: one arc closing the measure, one
    /// opening the next. Nothing here guesses — if the model did not ask for
    /// a tie, no curve appears.
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
        let headHalf = 0.62 * gap
        for link in ties {
            guard let fromX = xs[link.fromTicks], let toX = xs[link.toTicks],
                  let chord = chords[link.fromTicks],
                  let note = chord.notes.first(where: { $0.pitch == link.pitch }) else { continue }
            // A tie clears the head it leaves and the head it reaches: drawn
            // at head level it reads as a slur between two different notes,
            // which is exactly what it is not.
            let y = yOn(note.staffPosition)
            // Inside a chord the outer notes bow outward, so two ties a third
            // apart never land on the same line of the staff.
            let positions = chord.notes.map(\.staffPosition)
            let middle = Double((positions.min() ?? 0) + (positions.max() ?? 0)) / 2
            let away: CGFloat = positions.count == 1
                ? (y > yOn(4) ? 1 : -1)
                : (Double(note.staffPosition) > middle ? -1 : 1)
            let baseline = y + away * 0.62 * gap
            let bow: CGFloat = away * 0.36 * gap
            let startX = fromX + headHalf + 0.1 * gap
            let endX = toX - headHalf - 0.1 * gap
            guard endX > startX else { continue }
            // Two halves, one either side of the barline, the way a score sets
            // a tie across a system break: the curve belongs to the measure it
            // leaves and to the one it enters, so it never sails over the
            // chords in between.
            let line = result.options.measureTicks
            let barTick = (link.toTicks / max(1, line)) * line
            if let barX = barXs[barTick], barX > startX, barX < endX {
                let leftEnd = min(barX - 0.15 * gap, endX)
                tie(from: NSPoint(x: startX, y: baseline), to: NSPoint(x: leftEnd, y: baseline),
                    bow: bow, gap: gap, ink: ink)
                let rightStart = max(barX + 0.15 * gap, startX)
                if endX - rightStart > 0.6 * gap {
                    tie(from: NSPoint(x: rightStart, y: baseline), to: NSPoint(x: endX, y: baseline),
                        bow: bow, gap: gap, ink: ink)
                }
            } else {
                tie(from: NSPoint(x: startX, y: baseline), to: NSPoint(x: endX, y: baseline),
                    bow: bow, gap: gap, ink: ink)
            }
        }
    }

    private func tie(from start: NSPoint, to end: NSPoint, bow: CGFloat,
                     gap: CGFloat, ink: NSColor) {
        guard end.x - start.x > 0.6 * gap else { return }
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
                    strokeLine(from: NSPoint(x: cx - 1.02 * gap, y: y),
                               to: NSPoint(x: cx + 1.02 * gap, y: y), width: 0.85)
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
                inkGlyph(cp, centerX: cx - 0.85 * gap - accWidth / 2, centerY: accY, gap: gap, ink: ink)
            }
            let headGlyph = note.head == .whole ? Glyph.noteheadWhole
                : note.head == .half ? Glyph.noteheadHalf : Glyph.noteheadBlack
            let headInfo = MusicFont.info(headGlyph)
            let headWidth = (headInfo?.width ?? 1.18) * fontSize
            inkHead(headGlyph, centerX: cx, centerY: cy, gap: gap, ink: ink)
            if note.dots > 0 {
                // A dot is a small disc, not a glyph scaled to the head: it
                // sits half a space off the head and a space above a line.
                let onLine = note.staffPosition % 2 == 0
                let dotY = onLine ? cy - gap / 2 : cy
                ink.setFill()
                for dot in 0..<note.dots {
                    let centre = NSPoint(x: cx + headWidth / 2 + 0.34 * gap + CGFloat(dot) * 0.62 * gap,
                                         y: dotY)
                    let radius = 0.145 * gap
                    NSBezierPath(ovalIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                                width: radius * 2, height: radius * 2)).fill()
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
            // The beam belongs to the staff its chords were placed on, not to
            // a track id that a two-stem chord can move: a bass group drawn
            // against the treble staff's rows hangs its stems below the wrong
            // staff entirely.
            let onTop = group.chordIndices.first.map { topMap[$0] != nil } ?? (group.track == 0)
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
