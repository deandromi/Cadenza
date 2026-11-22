import Foundation

/// The engraver: turns the played note stream into sheet geometry that reads
/// like notation instead of a scatter of heads.
///
/// It follows the way notation software imports a performance:
///
/// 1. Every onset is quantized onto a take's own grid — an eighth, or a
///    sixteenth when the take really plays sixteenths — in the source's own
///    ticks when the source is a file (`SheetDraft.TimeMap`), because a MIDI
///    file's ticks are its notation and its tempo map is not.
/// 2. Notes struck together become one chord. A rolled chord, whose notes
///    arrive a few tens of milliseconds apart, folds back into one chord as
///    well, because a roll is one gesture and not four sixteenths.
/// 3. Barlines follow the take: a fixed measure grid from the file's origin, or
///    (for a live performance) the nearest played attack to each expected
///    downbeat, since the tempo drifts.
/// 4. Notes go to the staff their register belongs to, split at middle C, and
///    each staff splits into up to two voices by overlap (see `StaffWriter`).
/// 5. Each voice's values come from the room a note owns in that voice, are
///    split where they would hide a beat, and are tied where they cross a
///    barline. Every silence is filled with rests that add up exactly.
/// 6. Eighths and sixteenths beam inside their beat, never through a rest and
///    never across a bar.
/// 7. Key signature, accidentals (once per measure per staff), note heads,
///    dots, flags and stems come from the written values.
/// 8. Measures pack into systems on a page width, and each measure spaces its
///    columns by time, so both hands share one rhythmic scale.
public enum SheetEngraver {

    /// A played note on the engraver's tick grid.
    struct Note {
        var start: Int
        /// Ticks the key was down, on the same grid.
        var length: Int
        var pitch: Int
    }

    /// The notes struck at one tick of one staff.
    struct Column {
        var start: Int
        var pitches: [Int]
        /// The longest hold in the chord.
        var held: Int
    }

    /// One staff's symbol list, with the symbol indices of each measure.
    struct Staff {
        var symbols: [SheetDraft.Symbol] = []
        /// Symbol indices of each measure's columns, barline excluded.
        var measures: [[Int]] = []
    }

    public static func engrave(notes: [NoteEvent], options: SheetDraft.Options,
                               pageWidth: Double,
                               pedals: [SheetDraft.PedalSpan] = [],
                               originTicks: Int? = nil,
                               timeMap: SheetDraft.TimeMap? = nil) -> SheetDraft.Result {
        let meter = SheetDraft.Meter(options)
        let measureTicks = meter.measureTicks

        /// Where a moment of the performance lands on the engraver's ticks: the
        /// file's own clock when there is one, the drafted tempo otherwise.
        func tick(_ seconds: Double) -> Int {
            if let timeMap { return timeMap.engraverTick(seconds: seconds) }
            return SheetDraft.ticks(seconds: seconds, options: options)
        }

        // 1. Onto the grid.
        //
        // The grid is read off the take: a file's ticks are notation, so the
        // coarsest grid that still catches its attacks is the right one. A
        // performance's seconds drift, so it keeps the sixteenth grid and only
        // nudges an attack that is already most of the way to the pulse.
        let rawOnsets = notes.map { tick($0.onset) }
        let quantizer = SheetDraft.Quantizer(onsets: rawOnsets, options: options,
                                             metrical: timeMap != nil)
        var raw = notes.map { note -> Note in
            let start = quantizer.quantize(tick(note.onset))
            let end = quantizer.quantize(tick(note.onset + note.duration))
            return Note(start: start, length: max(quantizer.grid, end - start), pitch: note.pitch)
        }
        guard let earliest = raw.map(\.start).min() else {
            return empty(options: options, pageWidth: pageWidth)
        }
        raw.sort { ($0.start, $0.pitch) < ($1.start, $1.pitch) }

        // 2. Chordify: a rolled chord is one chord.
        //
        // Chaining any two onsets closer than the combine window folds a roll
        // back into the chord it is, while a genuine sixteenth line — a whole
        // grid step apart — stays separate.
        let window = max(1, SheetDraft.ticks(ms: options.combineMillis, options: options))
        var clusters: [[Note]] = []
        var anchors: [Int] = []
        for note in raw {
            if let last = anchors.last, note.start - last <= window {
                clusters[clusters.count - 1].append(note)
            } else {
                clusters.append([note])
                anchors.append(note.start)
            }
        }

        // 3. Barlines follow the performance.
        //
        // A fixed three beats from the first note walks off the page: a human
        // tempo drifts a few percent, and by the tenth bar every note lands on
        // the offbeat. So each barline starts from the previous one plus a bar
        // and then steps to the nearest played attack, which keeps the harmony
        // on the beat where it was played.
        //
        // A MIDI file is not a performance: its ticks are the notation, and the
        // file's own measure grid is the truth. So an imported file hands its
        // bar origin in, and the barlines stay exactly a measure apart — an
        // upbeat then prints as the rests in front of it, the way the printed
        // page does, instead of walking every barline forward to the first
        // attack it can find.
        let root = originTicks.map { quantizer.quantize(sourceTick($0, timeMap: timeMap)) }
            ?? quantizer.quantize(earliest)
        // The music's own end decides the last bar: a bar is added only while
        // there is something in it, so the sheet never closes on an empty bar.
        let musicEnd = max(measureTicks, (raw.map { $0.start + $0.length }.max() ?? 0) - root)
        var barStarts = [0]
        if originTicks != nil {
            while Double(barStarts.count) * Double(measureTicks) < Double(musicEnd) {
                barStarts.append(barStarts.count * measureTicks)
            }
        } else {
            let reach = max(quantizer.grid * 2, measureTicks / 6)
            while barStarts.last.map({ $0 + measureTicks < musicEnd }) ?? false {
                let expected = barStarts[barStarts.count - 1] + measureTicks
                let nearby = anchors
                    .map { $0 - root }
                    .filter { abs($0 - expected) <= reach }
                let chosen = nearby.min { abs($0 - expected) < abs($1 - expected) } ?? expected
                // a barline never moves more than half a bar: a note half a bar
                // away is the next beat, not this bar's downbeat
                let floor = barStarts[barStarts.count - 1] + measureTicks / 2
                barStarts.append(max(floor, chosen))
            }
        }

        // 4. Columns: the notes struck at one moment, per bar and per staff.
        var topBars: [[Column]] = Array(repeating: [], count: barStarts.count)
        var bottomBars: [[Column]] = Array(repeating: [], count: barStarts.count)
        for cluster in clusters {
            let start = cluster.map(\.start).min() ?? 0
            let absolute = start - root
            guard absolute >= 0 else { continue }
            var bar = 0
            for (index, barStart) in barStarts.enumerated() where barStart <= absolute {
                bar = index
            }
            let local = absolute - barStarts[bar]
            guard local < measureTicks else { continue }
            let moment = barStarts[bar] + local
            var treble: [Note] = []
            var bass: [Note] = []
            for note in cluster {
                if note.pitch >= 60 { treble.append(note) } else { bass.append(note) }
            }
            if !treble.isEmpty {
                appendColumn(&topBars[bar], at: moment, notes: treble, quantizer: quantizer)
            }
            if !bass.isEmpty {
                appendColumn(&bottomBars[bar], at: moment, notes: bass, quantizer: quantizer)
            }
        }

        // 5. key: the signature that needs the fewest accidentals.
        let fifths = SheetDraft.guessedFifths(pitches: raw.map(\.pitch))

        // 6. Each staff writes its voices; then the systems.
        var groups: [SheetDraft.BeamGroup] = []
        var nextID = 0
        var ties: [SheetDraft.Tie] = []
        var slurs: [SheetDraft.Slur] = []
        let top = StaffWriter(meter: meter, clef: .treble, fifths: fifths,
                              track: 0, grid: quantizer.grid)
            .write(topBars, measureStarts: barStarts, ties: &ties, groups: &groups,
                   slurs: &slurs, nextID: &nextID)
        let bottom = StaffWriter(meter: meter, clef: .bass, fifths: fifths,
                                 track: 1, grid: quantizer.grid)
            .write(bottomBars, measureStarts: barStarts, ties: &ties, groups: &groups,
                   slurs: &slurs, nextID: &nextID)
        let rows = layout(top: top, bottom: bottom, options: options, pageWidth: pageWidth)

        // Pedal spans are known but not inked yet: a mark in the wrong place
        // is worse than no mark, and this edition shows none.
        _ = pedals

        // A system never spills past the paper: if one bar is dense enough to
        // need more room than the page has, the sheet widens a little rather
        // than losing the notes off the edge.
        let widest = rows.map(\.width).max() ?? pageWidth

        return SheetDraft.Result(options: options, fifths: fifths,
                                 topTrack: top.symbols, bottomTrack: bottom.symbols,
                                 rows: rows, beamGroups: groups, ties: ties, slurs: slurs,
                                 width: max(pageWidth, widest), rowHeight: rowHeight,
                                 totalHeight: totalHeight(forRows: rows.count),
                                 rowsPerPage: systemsPerPage)
    }

    // MARK: input

    /// A tick on the source's own grid, on the engraver's grid.
    private static func sourceTick(_ tick: Int, timeMap: SheetDraft.TimeMap?) -> Int {
        guard let timeMap else { return tick }
        return Int((Double(tick) * Double(SheetDraft.ticksPerQuarter)
            / Double(timeMap.ticksPerQuarter)).rounded())
    }

    /// Adds a column, or grows the one already at this moment: two hands can
    /// strike the same pitch together, and one tick holds one chord.
    private static func appendColumn(_ bars: inout [Column], at start: Int,
                                     notes: [Note], quantizer: SheetDraft.Quantizer) {
        guard !notes.isEmpty else { return }
        let held = notes.map { quantizer.quantize($0.length) }.max() ?? quantizer.grid
        var pitches = Set<Int>()
        for note in notes { pitches.insert(note.pitch) }
        if let index = bars.lastIndex(where: { $0.start == start }) {
            bars[index].pitches = Array(Set(bars[index].pitches).union(pitches)).sorted()
            bars[index].held = max(bars[index].held, held)
        } else {
            bars.append(Column(start: start, pitches: pitches.sorted(), held: held))
        }
    }

    // MARK: page metrics

    /// Seven measures to a system and four systems to a page: the
    /// proportions of an engraved edition rather than a scrolling strip. Ten
    /// made the page a wall of bars and squeezed the columns until a rest sat
    /// on a stem; a waltz breathes at seven.
    public static let measuresPerSystem = 12
    public static let systemsPerPage = 4
    /// How wide a system is, in staff spaces: the paper the sheet is laid
    /// out for, and the width the renderer and the PDF agree on.
    public static let pageWidth = 106.0

    /// Two staves with air between them, then the gap that separates one
    /// system from the next.
    private static let systemHeight = 4.0 + ScoreLayout.staffGap + 4.0
    private static let systemGap = 12.0
    private static let pageGap = 10.0
    private static let topSpace = 6.0

    private static var rowHeight: Double { systemHeight + systemGap }

    private static func totalHeight(forRows rows: Int) -> Double {
        guard rows > 0 else { return topSpace + rowHeight }
        let pages = (rows + systemsPerPage - 1) / systemsPerPage
        return topSpace + Double(rows) * rowHeight + Double(max(0, pages - 1)) * pageGap
    }

    /// Extra space between pages, in staff spaces, for the renderer.
    public static var pageBreakSpace: Double { pageGap }

    // MARK: systems

    /// Systems take ten measures, then stretch to fill the page: a dense
    /// bar takes the width its rhythm needs, air is shared out between the
    /// rest, and every system ends flush right the way an engraved page does.
    /// One rhythmic column of a bar: when it sounds, the distance the
    /// engraver wants to the next column, and how far its ink reaches on each
    /// side of that column, in staff spaces.
    struct RhythmColumn {
        let moment: Int
        let gap: Double
        let left: Double
        let right: Double
    }

    private static func layout(top: Staff, bottom: Staff, options: SheetDraft.Options,
                               pageWidth: Double) -> [SheetDraft.Row] {
        let measureTicks = options.measureTicks
        let count = max(top.measures.count, bottom.measures.count)
        let framing = 9.5
        let usable = max(20.0, pageWidth - framing - 3.0)

        /// The moments of one bar, counted from the barline rather than from
        /// the start of the piece.
        func starts(_ staff: Staff, _ measure: Int) -> [Int] {
            guard measure < staff.measures.count else { return [] }
            let barStart = measure * measureTicks
            return staff.measures[measure].compactMap { index in
                switch staff.symbols[index] {
                case .chord(let chord): return max(0, chord.startTicks - barStart)
                case .rest(let start, _): return max(0, start - barStart)
                case .restVoiced(let start, _, _): return max(0, start - barStart)
                default: return nil
                }
            }
        }

        /// How much room a symbol needs on each side of its column, in staff
        /// spaces: a head is about a head wide, an accidental adds its own
        /// air to the left, dots reach right.
        func extents(_ symbol: SheetDraft.Symbol) -> (left: Double, right: Double) {
            switch symbol {
            case .chord(let chord):
                let accidental = chord.notes.contains { $0.accidental != .none } ? 0.95 : 0
                let dots = (chord.notes.map(\.dots).max() ?? 0) > 0 ? 0.72 : 0
                return (0.6 + accidental, 0.6 + dots)
            case .rest(_, let kind), .restVoiced(_, let kind, _):
                // an eighth rest has a hook that reaches, a whole rest is a
                // small block sitting under the fourth line
                let width = kind == .whole || kind == .half ? 0.8 : 0.6
                return (width, width)
            default:
                return (0, 0)
            }
        }

        /// The rhythm's own share of the beat, as MuseScore spaces it: a
        /// quarter note gets a quarter's air, an eighth half of that, and no
        /// two columns ever sit closer than a head plus a hair.
        func rhythmGap(_ ticks: Int) -> Double {
            let quarter = Double(SheetDraft.ticksPerQuarter)
            if ticks >= Int(4 * quarter) { return 3.4 }
            if ticks >= Int(2 * quarter) { return 2.8 }
            if ticks >= Int(quarter) { return 2.15 }
            if ticks >= Int(quarter / 2) { return 1.6 }
            if ticks >= Int(quarter / 4) { return 1.35 }
            return 1.2
        }

        /// The moment and symbol of a bar's columns, both hands together.
        func momentsOf(_ staff: Staff, _ measure: Int) -> [(Int, SheetDraft.Symbol)] {
            guard measure < staff.measures.count else { return [] }
            let barStart = measure * measureTicks
            return staff.measures[measure].compactMap { index in
                let symbol = staff.symbols[index]
                switch symbol {
                case .chord(let chord): return (max(0, chord.startTicks - barStart), symbol)
                case .rest(let start, _): return (max(0, start - barStart), symbol)
                case .restVoiced(let start, _, _): return (max(0, start - barStart), symbol)
                default: return nil
                }
            }
        }

        /// A bar's columns in time order, with the gap each one needs to the
        /// next. A column's air is the rhythm's share, but never less than the
        /// ink standing in it: an eighth rest followed by a chord needs room
        /// for both, whatever the beat says. This is the pass that keeps a
        /// dense waltz from printing a rest through a notehead.
        func columnsOf(_ measure: Int) -> [RhythmColumn] {
            var atMoment: [Int: (left: Double, right: Double)] = [:]
            for staff in [top, bottom] {
                for (moment, symbol) in momentsOf(staff, measure) {
                    let extent = extents(symbol)
                    let current = atMoment[moment] ?? (0, 0)
                    atMoment[moment] = (max(current.left, extent.left),
                                        max(current.right, extent.right))
                }
            }
            let moments = atMoment.keys.sorted()
            return moments.enumerated().map { offset, moment in
                let ink = atMoment[moment] ?? (0, 0)
                guard offset + 1 < moments.count else {
                    return RhythmColumn(moment: moment, gap: ink.right, left: ink.left, right: ink.right)
                }
                let next = moments[offset + 1]
                let nextInk = atMoment[next] ?? (0, 0)
                let rhythm = rhythmGap(max(1, next - moment))
                let clearance = ink.right + nextInk.left + 0.25
                return RhythmColumn(moment: moment, gap: max(rhythm, clearance),
                                    left: ink.left, right: ink.right)
            }
        }

        /// A bar's width before justification: the ink of its first and last
        /// columns plus the air between them. A bar holding one whole rest is
        /// given a fixed narrow width, the way a printed score gives an empty
        /// bar half the room of a busy one.
        func naturalWidth(_ measure: Int) -> Double {
            let columns = columnsOf(measure)
            guard let first = columns.first, let last = columns.last else { return 3.2 }
            let lead = first.left + 0.35
            let trail = last.right + 0.35
            if columns.count == 1 { return max(3.2, lead + trail) }
            let air = columns.dropLast().map(\.gap).reduce(0, +)
            return max(3.2, lead + air + trail)
        }

        var rows: [SheetDraft.Row] = []
        var measure = 0
        var firstMeasure = 1
        while measure < count {
            var chosen: [Int] = []
            var naturals: [Double] = []
            // Bars are taken while they fit: a system gives up a bar rather
            // than squeezing heads or running over the page edge.
            while chosen.count < measuresPerSystem, measure + chosen.count < count {
                let candidate = measure + chosen.count
                // the first bar of a page opens with a clef, a key and a
                // meter in front of its music: that framing is real width
                let width = naturalWidth(candidate) + (candidate == 0 ? 6.8 : 0)
                if chosen.count >= 2, naturals.reduce(0, +) + width > usable { break }
                chosen.append(candidate)
                naturals.append(width)
            }
            // The system closes flush right: the paper left over is shared
            // out between the bars. A single bar too dense for the page is
            // squeezed rather than allowed to overflow.
            let naturalTotal = naturals.reduce(0, +)
            let stretch = naturalTotal > 0
                ? min(max(usable / naturalTotal, 0.98), 1.3) : 1.0
            let widths = naturals.map { $0 * stretch }

            var topPlaced: [SheetDraft.Placed] = []
            var bottomPlaced: [SheetDraft.Placed] = []
            var x = framing
            for (offset, index) in chosen.enumerated() {
                let start = index * measureTicks
                topPlaced.append(SheetDraft.Placed(x: x, trackIndex: barIndex(in: top, before: index),
                                                   symbol: .bar(startTicks: start)))
                bottomPlaced.append(SheetDraft.Placed(x: x, trackIndex: barIndex(in: bottom, before: index),
                                                      symbol: .bar(startTicks: start)))
                // Every moment of the bar gets its own column, and the
                // columns share the bar by how long they last — but never
                // closer than a head's width, so two sixteenths can sit in
                // one bar without their noteheads landing on each other.
                // The first bar of a page carries the clef, the key and the
                // time signature in front of its music, so its notes start
                // after that framing instead of under it: a pickup rest
                // printed on top of the clef is not a pickup rest.
                let inset: Double = (index == 0 && rows.isEmpty) ? 6.8 : 0
                let musicX = x + inset
                let musicWidth = max(3.0, widths[offset] - inset)
                let columns = columnMap(columnsOf(index), x: musicX,
                                        measureWidth: musicWidth)
                place(staff: top, measure: index, start: start, x: musicX,
                      measureWidth: musicWidth, measureTicks: measureTicks,
                      columns: columns, into: &topPlaced)
                place(staff: bottom, measure: index, start: start, x: musicX,
                      measureWidth: musicWidth, measureTicks: measureTicks,
                      columns: columns, into: &bottomPlaced)
                x += widths[offset]
            }
            // the system closes with a barline, a thin double one at the end
            let closing: SheetDraft.Symbol = measure + chosen.count >= count
                ? .finalBar(startTicks: measureTicks * count)
                : .bar(startTicks: measureTicks * (measure + chosen.count))
            topPlaced.append(SheetDraft.Placed(x: x, trackIndex: -1, symbol: closing))
            bottomPlaced.append(SheetDraft.Placed(x: x, trackIndex: -1, symbol: closing))

            rows.append(SheetDraft.Row(clefTop: .treble, clefBottom: .bass,
                                       top: topPlaced, bottom: bottomPlaced,
                                       firstMeasure: firstMeasure,
                                       showsFraming: rows.isEmpty,
                                       width: x))
            measure += chosen.count
            firstMeasure += chosen.count
        }
        return rows
    }

    /// The index of the barline that opens a measure in the symbol list.
    private static func barIndex(in staff: Staff, before measure: Int) -> Int {
        var bars = 0
        for (index, symbol) in staff.symbols.enumerated() {
            switch symbol {
            case .bar, .finalBar:
                if bars == measure { return index }
                bars += 1
            default:
                break
            }
        }
        return staff.symbols.count - 1
    }

    /// Where each rhythmic column of one bar sits, in staff spaces. The gaps
    /// the layout asked for are fitted to the bar the system handed it, and
    /// the first column starts after its own ink, so nothing is ever printed
    /// on the opening barline or the clef.
    private static func columnMap(_ columns: [RhythmColumn], x: Double,
                                  measureWidth: Double) -> [Int: Double] {
        guard let first = columns.first, let last = columns.last else { return [:] }
        let lead = first.left + 0.35
        let trail = last.right + 0.35
        let air = columns.dropLast().map(\.gap).reduce(0, +)
        let scale = air > 0.001
            ? max(0.55, (measureWidth - lead - trail) / air) : 1
        var map: [Int: Double] = [:]
        var cursor = x + lead
        for (offset, column) in columns.enumerated() {
            map[column.moment] = cursor
            guard offset < columns.count - 1 else { break }
            cursor += column.gap * scale
        }
        return map
    }

    private static func place(staff: Staff, measure: Int, start: Int, x: Double,
                              measureWidth: Double, measureTicks: Int,
                              columns: [Int: Double],
                              into placed: inout [SheetDraft.Placed]) {
        guard measure < staff.measures.count else { return }
        for index in staff.measures[measure] {
            let symbol = staff.symbols[index]
            switch symbol {
            case .chord(let chord):
                // never let a head cross its own closing barline
                let moment = max(0, chord.startTicks - start)
                let px = min(columns[moment] ?? x + 1.1, x + measureWidth - 1.5)
                placed.append(SheetDraft.Placed(x: px, trackIndex: index, symbol: symbol))
            case .rest(let restStart, _):
                let wholeMeasure = staff.measures[measure].count == 1
                let px: Double
                if wholeMeasure {
                    px = x + measureWidth / 2
                } else {
                    let moment = max(0, restStart - start)
                    px = columns[moment] ?? x + 1.1
                }
                placed.append(SheetDraft.Placed(x: px, trackIndex: -1, symbol: symbol))
            case .restVoiced(let restStart, let kind, let voice):
                let wholeMeasure = staff.measures[measure].count == 1
                let moment = max(0, restStart - start)
                let px = wholeMeasure ? x + measureWidth / 2 : (columns[moment] ?? x + 1.1)
                // A rest takes the middle of the staff, the way an engraver
                // sets one: only when the other voice's chord is in the way
                // does it step out, above for the upper voice and below for
                // the lower one. A rest is never printed through a stem, and
                // it never floats to the edge of the staff for no reason.
                let canonical: Int = kind == .whole ? 6 : 4
                var target = canonical
                var blocked = true
                while blocked {
                    blocked = false
                    for index in staff.measures[measure] {
                        guard case .chord(let chord) = staff.symbols[index],
                              chord.startTicks == restStart else { continue }
                        for note in chord.notes where abs(note.staffPosition - target) <= 1 {
                            blocked = true
                        }
                    }
                    if blocked {
                        target += voice == 0 ? 2 : -2
                        if target > 12 || target < -4 { blocked = false }
                    }
                }
                // the chord keeps the column; the rest moves clear of its stem
                let sharesColumn = staff.measures[measure].contains { index in
                    if case .chord(let chord) = staff.symbols[index] {
                        return chord.startTicks == restStart
                    }
                    return false
                }
                let across = (sharesColumn && !wholeMeasure) ? (voice == 0 ? -1.55 : 1.55) : 0
                placed.append(SheetDraft.Placed(x: px, trackIndex: -1, symbol: symbol,
                                                yOffset: Double(target - canonical) / 2,
                                                xOffset: across))
            default:
                break
            }
        }
    }

    // MARK: empty

    private static func empty(options: SheetDraft.Options, pageWidth: Double) -> SheetDraft.Result {
        let row = SheetDraft.Row(
            clefTop: .treble, clefBottom: .bass,
            top: [.init(x: 9.5, trackIndex: 0, symbol: .bar(startTicks: 0)),
                  .init(x: 9.5, trackIndex: 1, symbol: .rest(startTicks: 0, kind: .whole))],
            bottom: [.init(x: 9.5, trackIndex: 0, symbol: .bar(startTicks: 0)),
                     .init(x: 9.5, trackIndex: 1, symbol: .rest(startTicks: 0, kind: .whole))],
            firstMeasure: 1, showsFraming: true, width: pageWidth)
        return SheetDraft.Result(options: options, fifths: 0,
                                 topTrack: [], bottomTrack: [],
                                 rows: [row], beamGroups: [],
                                 width: pageWidth, rowHeight: rowHeight,
                                 totalHeight: totalHeight(forRows: 1),
                                 rowsPerPage: systemsPerPage)
    }
}
