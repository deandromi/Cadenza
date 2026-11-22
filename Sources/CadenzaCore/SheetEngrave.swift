import Foundation

/// The engraver: turns the played note stream into sheet geometry that reads
/// like notation instead of a scatter of heads.
///
/// It works on a fixed sixteenth-note grid, the way notation software does:
///
/// 1. Every onset snaps to the nearest sixteenth, and human chord spread
///    disappears because notes landing on the same grid point become one
///    chord. This is the step the old pipeline lacked: it rounded onsets to
///    the next played note, so a rolled chord became four columns of noise.
/// 2. Durations snap to the grid too and never cross a barline; a note that
///    would run past the bar is cut at the bar, which is what a tied note
///    would do on paper.
/// 3. Notes go to the staff their pitch belongs to, split at middle C, with
///    the treble staff in treble clef and the bass staff in bass clef for
///    the whole piece. No clef wanders mid-page.
/// 4. Each staff is filled with rests, so every beat of every measure is
///    accounted for and the bars line up.
/// 5. Key signature, accidentals (shown once per measure per staff), note
///    heads, dots, flags and stems come from the quantized durations.
/// 6. Eighths and sixteenths beam inside their beat, never across a bar and
///    never through a rest.
/// 7. Measures pack into systems on a page width, and each measure spaces
///    its columns by time, so both hands share one rhythmic scale.
public enum SheetEngraver {

    /// A note on the sixteenth grid.
    private struct Event {
        var start: Int
        var duration: Int
        var pitch: Int
        /// The finger holds the key past the barline: the sheet ties the
        /// note over instead of closing it with a rest.
        var tied: Bool = false
    }

    /// One rhythmic column of a measure: a chord or a rest.
    private enum Column {
        case chord(SheetDraft.Chord)
        case rest(kind: SheetDraft.RestKind, start: Int)
    }

    /// One staff's symbol list, with where each measure's columns sit in it.
    private struct Staff {
        var symbols: [SheetDraft.Symbol] = []
        /// Symbol indices of each measure's columns, barline excluded.
        var measures: [[Int]] = []
    }

    public static func engrave(notes: [NoteEvent], options: SheetDraft.Options,
                               pageWidth: Double,
                               pedals: [SheetDraft.PedalSpan] = [],
                               originTicks: Int? = nil) -> SheetDraft.Result {
        let measureTicks = options.measureTicks
        let grid = max(1, SheetDraft.ticksPerQuarter / 4)

        // 1. Cluster rolled chords.
        //
        // A played chord rarely lands on one tick: the notes arrive within a
        // few tens of milliseconds of each other. Chaining any two onsets
        // closer than a tenth of a beat folds such a roll back into the one
        // chord it is, while a genuine sixteenth line (a whole grid step
        // apart) stays separate.
        var raw = notes.map { note in
            Event(start: SheetDraft.ticks(seconds: note.onset, options: options),
                  duration: max(1, SheetDraft.ticks(seconds: note.duration, options: options)),
                  pitch: note.pitch)
        }
        guard let earliest = raw.map(\.start).min() else {
            return empty(options: options, pageWidth: pageWidth)
        }
        raw.sort { ($0.start, $0.pitch) < ($1.start, $1.pitch) }
        let window = max(30, min(grid - 20, SheetDraft.ticks(seconds: 0.09, options: options)))

        var clusters: [[Event]] = []
        var anchors: [Int] = []
        for event in raw {
            if let last = anchors.last, event.start - last <= window {
                clusters[clusters.count - 1].append(event)
            } else {
                clusters.append([event])
                anchors.append(event.start)
            }
        }

        // 2. Barlines follow the performance.
        //
        // A fixed three beats from the first note walks off the page: a
        // human tempo drifts a few percent, and by the tenth bar every note
        // lands on the offbeat. So each barline starts from the previous one
        // plus a bar and then steps to the nearest played attack, which
        // keeps the harmony on the beat where it was played.
        //
        // A MIDI file is not a performance: its ticks are the notation, and
        // the file's own measure grid is the truth. So an imported file hands
        // its bar origin in, and the barlines stay exactly a measure apart —
        // an upbeat then prints as the rests in front of it, the way the
        // printed page does, instead of walking every barline forward to the
        // first attack it can find.
        let root = originTicks.map { snap($0, to: grid) } ?? snap(earliest, to: grid)
        let lastTick = raw.map { $0.start + $0.duration }.max() ?? measureTicks
        var barStarts = [0]
        if let origin = originTicks {
            let originTick = snap(origin, to: grid)
            var position = 0
            let end = max(0, lastTick - originTick)
            while position < end {
                position += measureTicks
                barStarts.append(position)
            }
        } else {
            let reach = max(grid * 2, measureTicks / 6)
            while barStarts.last.map({ $0 + root < lastTick + measureTicks }) ?? false {
                let expected = barStarts[barStarts.count - 1] + measureTicks
                let nearby = anchors
                    .map { snap($0, to: grid) - root }
                    .filter { abs($0 - expected) <= reach }
                let chosen = nearby.min { abs($0 - expected) < abs($1 - expected) } ?? expected
                // a barline never moves more than half a bar: a note half a bar
                // away is the next beat, not this bar's downbeat
                let floor = barStarts[barStarts.count - 1] + measureTicks / 2
                barStarts.append(max(floor, chosen))
            }
        }

        // 3. Notes land on the grid of their own bar.
        // First, where the player actually struck each key: a note carried
        // over a barline may only continue into a bar where that key was not
        // struck again. A re-struck note is a new note, not a tie.
        var attacks = Set<String>()
        for cluster in clusters {
            guard let anchor = cluster.map(\.start).min() else { continue }
            let absolute = snap(anchor, to: grid) - root
            var bar = 0
            for (index, start) in barStarts.enumerated() where start <= absolute { bar = index }
            let local = max(0, absolute - barStarts[bar])
            for note in cluster { attacks.insert("\(bar)-\(local)-\(note.pitch)") }
        }
        var byMeasure: [[Event]] = Array(repeating: [], count: barStarts.count)
        var strongest: [String: Event] = [:]
        for cluster in clusters {
            guard let anchor = cluster.map(\.start).min() else { continue }
            let absolute = snap(anchor, to: grid) - root
            var bar = 0
            for (index, start) in barStarts.enumerated() where start <= absolute {
                bar = index
            }
            let barStart = barStarts[bar]
            let local = max(0, absolute - barStart)
            guard local < measureTicks else { continue }
            for note in cluster {
                // A note still sounding at the barline is written again on the
                // next downbeat and tied to what came before: one note across
                // two bars, the way a score writes a held key. The segment
                // plan comes first, because whether a tie is written depends
                // on whether the continuation is written at all: a key struck
                // again, or a finger that lifts just past the line, ends the
                // note at the barline instead.
                var segments: [(bar: Int, start: Int, length: Int)] = []
                var remaining = snap(note.duration, to: grid)
                var barIndex = bar
                var startLocal = local
                while remaining > 0, barIndex < byMeasure.count {
                    if !segments.isEmpty,
                       attacks.contains("\(barIndex)-\(startLocal)-\(note.pitch)") { break }
                    let room = measureTicks - startLocal
                    let inThisBar = min(remaining, room)
                    if inThisBar >= grid || room == measureTicks {
                        segments.append((barIndex, startLocal, max(grid, inThisBar)))
                    }
                    let carry = remaining - room
                    // A note that sustains less than a beat past the barline
                    // is the pedal ringing, not a held key: the player struck
                    // again on the downbeat, so the note ends at the line and
                    // no tie is written.
                    if carry > 0, carry < 2 * SheetDraft.ticksPerQuarter { break }
                    remaining -= inThisBar
                    barIndex += 1
                    startLocal = 0
                }
                for (offset, segment) in segments.enumerated() {
                    let key = "\(segment.bar)-\(segment.start)-\(note.pitch)"
                    let length = segment.length
                    if (strongest[key]?.duration ?? -1) < length {
                        strongest[key] = Event(start: segment.start, duration: length,
                                               pitch: note.pitch,
                                               tied: offset < segments.count - 1)
                    }
                }
            }
        }
        // each key carries its measure, so the symbols land in order
        for (key, event) in strongest {
            guard let bar = Int(key.split(separator: "-").first ?? "") else { continue }
            byMeasure[bar].append(event)
        }
        for index in byMeasure.indices {
            byMeasure[index].sort { ($0.start, $0.pitch) < ($1.start, $1.pitch) }
        }

        let pitches = strongest.values.map(\.pitch)

        // 4. key: the signature that needs the fewest accidentals.
        let fifths = SheetDraft.guessedFifths(pitches: pitches)

        // 5. hands by register, split at middle C.
        var treble: [[Event]] = Array(repeating: [], count: byMeasure.count)
        var bass: [[Event]] = Array(repeating: [], count: byMeasure.count)
        for (index, events) in byMeasure.enumerated() {
            for event in events {
                if event.pitch >= 60 {
                    treble[index].append(event)
                } else {
                    bass[index].append(event)
                }
            }
        }
        var top = staff(events: treble, clef: .treble, options: options, fifths: fifths)
        var bottom = staff(events: bass, clef: .bass, options: options, fifths: fifths)

        // 6. beaming inside the beat, then the systems.
        var groups: [SheetDraft.BeamGroup] = []
        var nextID = 0
        applyBeams(to: &top, track: 0, options: options, groups: &groups, nextID: &nextID)
        applyBeams(to: &bottom, track: 1, options: options, groups: &groups, nextID: &nextID)

        let ties = SheetEngraver.ties(in: top.symbols, measureTicks: measureTicks, track: 0)
            + SheetEngraver.ties(in: bottom.symbols, measureTicks: measureTicks, track: 1)
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
                                 rows: rows, beamGroups: groups, ties: ties,
                                 width: max(pageWidth, widest), rowHeight: rowHeight,
                                 totalHeight: totalHeight(forRows: rows.count),
                                 rowsPerPage: systemsPerPage)
    }

    // MARK: ties

    /// The pitched continuations a score has to tie. A note marked as running
    /// past its barline is tied to the first column of the next measure that
    /// strikes the same pitch; if nothing does, there is no tie and the note
    /// simply ends where it ended.
    static func ties(in symbols: [SheetDraft.Symbol], measureTicks: Int, track: Int) -> [SheetDraft.Tie] {
        guard measureTicks > 0 else { return [] }
        // the columns of each measure, in order
        var measures: [Int: [(start: Int, chord: SheetDraft.Chord)]] = [:]
        for symbol in symbols {
            guard case .chord(let chord) = symbol else { continue }
            let measure = chord.startTicks / measureTicks
            measures[measure, default: []].append((chord.startTicks, chord))
        }
        for key in measures.keys {
            measures[key]?.sort { $0.start < $1.start }
        }
        var result: [SheetDraft.Tie] = []
        for (measure, columns) in measures.sorted(by: { $0.key < $1.key }) {
            guard let last = columns.last,
                  let next = measures[measure + 1]?.first else { continue }
            for note in last.chord.notes where note.tieToNext {
                guard next.chord.notes.contains(where: { $0.pitch == note.pitch }) else { continue }
                result.append(SheetDraft.Tie(track: track, pitch: note.pitch,
                                             fromTicks: last.start, toTicks: next.start))
            }
        }
        return result
    }

    // MARK: page metrics

    /// Seven measures to a system and four systems to a page: the
    /// proportions of an engraved edition rather than a scrolling strip.
    /// Ten made the page a wall of bars; a waltz breathes at seven.
    public static let measuresPerSystem = 10
    public static let systemsPerPage = 4
    /// How wide a system is, in staff spaces: the paper the sheet is laid
    /// out for, and the width the renderer and the PDF agree on.
    public static let pageWidth = 86.0

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

    // MARK: the grid

    private static func snap(_ ticks: Int, to grid: Int) -> Int {
        Int((Double(ticks) / Double(grid)).rounded()) * grid
    }

    /// One staff's symbol list: barline, columns, rests filling every gap,
    /// measure after measure.
    private static func staff(events: [[Event]], clef: SheetDraft.Clef,
                              options: SheetDraft.Options, fifths: Int) -> Staff {
        let measureTicks = options.measureTicks
        let gridSmall = max(1, SheetDraft.ticksPerQuarter / 4)
        var result = Staff()
        let measureCount = events.count
        for measure in 0..<measureCount {
            var grouped: [Int: [Event]] = [:]
            for event in events[measure] {
                grouped[event.start, default: []].append(event)
            }
            // events carry their bar-relative position; the symbol list
            // records where the bar sits in the piece
            let absolute = measure * measureTicks
            let end = measureTicks
            result.symbols.append(.bar(startTicks: absolute))
            var indices: [Int] = []
            var cursor = 0
            // the accidentals this measure has already printed, by line
            var shownAccidentals = Set<String>()
            let moments = grouped.keys.sorted()
            if moments.isEmpty {
                // an empty bar is one whole rest, centred, not a bar of beats
                result.measures.append([result.symbols.count])
                result.symbols.append(.rest(startTicks: absolute, kind: .whole))
                continue
            }
            for (momentIndex, moment) in moments.enumerated() {
                var notes = grouped[moment] ?? []
                notes.sort { $0.pitch < $1.pitch }
                guard !notes.isEmpty else { continue }
                if moment > cursor {
                    for rest in SheetDraft.rests(start: cursor, end: moment) {
                        indices.append(result.symbols.count)
                        result.symbols.append(lifted(rest, by: absolute))
                    }
                }
                // A played length includes every gap a finger leaves. On
                // paper the note carries the beat: it lasts until the next
                // chord of its staff, never past the bar. This is what
                // stops a legato waltz from reading as rests with notes in
                // between.
                let next = momentIndex + 1 < moments.count ? moments[momentIndex + 1] : end
                let room = end - moment
                // which of these notes is still sounding when the bar ends:
                // those get a tie over the barline
                let held = Set(notes.filter(\.tied).map(\.pitch))
                // The slot this column owns: until the hand's next column,
                // never past the bar. A chord is one vertical unit, so every
                // head in it takes the same value — one hand cannot hold a
                // half and strike an eighth under one stem. The value fills
                // the slot when the player held the key through it; a note
                // let go early prints short and rests close the bar after it,
                // instead of stretching a staccato to the barline.
                let slot = max(gridSmall, min(room, next - moment))
                let played = min(notes.map(\.duration).max() ?? slot, slot)
                let value = played * 2 >= slot
                    ? slot
                    : max(gridSmall, (played / gridSmall) * gridSmall)
                notes = notes.map { note in
                    var copy = note
                    copy.duration = value
                    return copy
                }
                indices.append(result.symbols.count)
                result.symbols.append(.chord(chord(from: notes, at: absolute + moment,
                                                   clef: clef, fifths: fifths, held: held,
                                                   shown: &shownAccidentals)))
                let chordEnd = min(end, notes.map { $0.start + $0.duration }.max() ?? moment)
                cursor = max(cursor, chordEnd)
            }
            if cursor < end {
                for rest in SheetDraft.rests(start: cursor, end: end) {
                    indices.append(result.symbols.count)
                    result.symbols.append(lifted(rest, by: absolute))
                }
            }
            if indices.isEmpty {
                indices.append(result.symbols.count)
                result.symbols.append(.rest(startTicks: absolute, kind: .whole))
            }
            result.measures.append(indices)
        }
        result.symbols.append(.finalBar(startTicks: measureCount * measureTicks))
        return result
    }

    /// Rests are built bar by bar; the symbol list keeps one timeline for
    /// the whole piece, so every symbol can be placed the same way.
    private static func lifted(_ symbol: SheetDraft.Symbol, by offset: Int) -> SheetDraft.Symbol {
        guard case .rest(let start, let kind) = symbol else { return symbol }
        return .rest(startTicks: start + offset, kind: kind)
    }

    /// One chord from the notes sharing a grid moment.
    private static func chord(from notes: [Event], at start: Int,
                              clef: SheetDraft.Clef, fifths: Int,
                              held: Set<Int> = [],
                              shown: inout Set<String>) -> SheetDraft.Chord {
        var glyphs: [SheetDraft.NoteGlyph] = []
        for note in notes {
            let value = SheetDraft.noteValue(note.duration)
            let position = clef.position(ofPitch: note.pitch)
            var accidental = SheetDraft.accidental(pitchClass: ((note.pitch % 12) + 12) % 12,
                                                   fifths: fifths)
            // a measure remembers: the same accidental on the same line shows
            // once, and a line the key already spells carries none
            if accidental != .none {
                let key = "\(position)-\(accidental)"
                if shown.contains(key) {
                    accidental = .none
                } else {
                    shown.insert(key)
                }
            }
            glyphs.append(SheetDraft.NoteGlyph(
                pitch: note.pitch,
                staffPosition: position,
                head: value.head,
                dots: value.dots,
                accidental: accidental,
                ledgers: SheetDraft.ledgers(forPosition: position),
                tieToNext: held.contains(note.pitch)))
        }
        var stems: [SheetDraft.Stem] = []
        let values = notes.map { SheetDraft.noteValue($0.duration) }
        if values.allSatisfy({ $0.head == .whole }) {
            stems = []
        } else {
            // One stem per chord: the shortest printed value sets the flags and the
            // average head position sets the direction. Splitting a chord into two
            // voices drew two stems through the same heads, which reads as a bug.
            var shortest = values[0]
            for value in values where value.flags > shortest.flags { shortest = value }
            let positions = glyphs.map(\.staffPosition)
            let up = positions.reduce(0, +) / max(1, positions.count) < 4
            stems = [SheetDraft.Stem(noteRange: 0..<notes.count, up: up,
                                     flags: shortest.flags, beamGroupId: nil)]
        }
        // the events carry bar-local starts, this chord carries an absolute
        // one: the end is the start plus the longest played length
        let longest = notes.map(\.duration).max() ?? 0
        return SheetDraft.Chord(startTicks: start, endTicks: start + longest,
                               notes: glyphs, stems: stems)
    }

    // MARK: beaming

    /// Beams neighbouring eighths and sixteenths inside one beat of one
    /// measure. A rest, a barline or a longer note ends the group.
    private static func applyBeams(to staff: inout Staff, track: Int,
                                   options: SheetDraft.Options,
                                   groups: inout [SheetDraft.BeamGroup],
                                   nextID: inout Int) {
        let beat = SheetDraft.ticksPerQuarter
        for indices in staff.measures {
            var run: [Int] = []
            func close() {
                guard run.count >= 2 else { run = []; return }
                var up = true
                var flags = 1
                if case .chord(let first) = staff.symbols[run[0]],
                   let stem = first.stems.first {
                    up = stem.up
                    flags = stem.flags
                }
                for index in run {
                    guard case .chord(let chord) = staff.symbols[index],
                          let stem = chord.stems.first else { continue }
                    flags = max(flags, stem.flags)
                }
                for index in run {
                    guard case .chord(let chord) = staff.symbols[index] else { continue }
                    let stems = chord.stems.map { stem in
                        SheetDraft.Stem(noteRange: stem.noteRange, up: stem.up,
                                        flags: max(stem.flags, flags), beamGroupId: nextID)
                    }
                    staff.symbols[index] = .chord(SheetDraft.Chord(
                        startTicks: chord.startTicks, endTicks: chord.endTicks,
                        notes: chord.notes, stems: stems))
                }
                groups.append(SheetDraft.BeamGroup(id: nextID, track: track,
                                                   chordIndices: run, up: up, flags: flags))
                nextID += 1
                run = []
            }
            for index in indices {
                guard case .chord(let chord) = staff.symbols[index] else {
                    close()
                    continue
                }
                let flags = chord.stems.first?.flags ?? 0
                let beamable = flags > 0 && chord.notes.allSatisfy { $0.dots == 0 }
                guard beamable else { close(); continue }
                if let last = run.last, case .chord(let previous) = staff.symbols[last],
                   previous.startTicks / beat != chord.startTicks / beat {
                    close()
                }
                run.append(index)
                if run.count == 4 { close() }
            }
            close()
        }
    }

    // MARK: systems

    /// Systems take ten measures, then stretch to fill the page: a dense
    /// bar takes the width its rhythm needs, air is shared out between the
    /// rest, and every system ends flush right the way an engraved page does.
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
                default: return nil
                }
            }
        }

        /// One barline, air per rhythmic column, room for an accidental. The
        /// per-column air is wider than the closest two heads may sit, so a
        /// bar is never handed a width that forces its columns to collide.
        func naturalWidth(_ measure: Int) -> Double {
            let columns = Set(starts(top, measure) + starts(bottom, measure)).count
            // A bar's width is its rhythm: one column of air per moment, plus
            // the barline. An engraver fits ten bars on this page, so the
            // column is about one head wide, not a head plus a gap.
            return 0.9 + Double(max(1, columns)) * 1.45
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
                let width = naturalWidth(candidate)
                if chosen.count >= 2, naturals.reduce(0, +) + width > usable { break }
                chosen.append(candidate)
                naturals.append(width)
            }
            // The system closes flush right: the paper left over is shared
            // out between the bars. A single bar too dense for the page is
            // squeezed rather than allowed to overflow.
            let naturalTotal = naturals.reduce(0, +)
            let stretch = naturalTotal > 0
                ? min(max(usable / naturalTotal, 0.92), 2.3) : 1.0
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
                let moments = Set(starts(top, index) + starts(bottom, index)).sorted()
                let columns = columnMap(moments: moments, x: musicX,
                                        measureWidth: musicWidth,
                                        measureTicks: measureTicks)
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

    /// Where each rhythmic column of one bar sits, in staff spaces. The
    /// gaps are proportional to the time each column holds, with a floor of
    /// one head's width so dense bars stay readable, then fitted to the bar.
    private static func columnMap(moments: [Int], x: Double,
                                  measureWidth: Double, measureTicks: Int) -> [Int: Double] {
        let inner = max(3.0, measureWidth - 2.6)
        // an accidental needs its own air to the left of the head, so two
        // columns never sit closer than this
        let floorGap = 1.55
        guard !moments.isEmpty else { return [:] }
        var gaps: [Double] = []
        for (offset, moment) in moments.enumerated() {
            let next = offset + 1 < moments.count ? moments[offset + 1] : measureTicks
            let span = Double(max(0, next - moment)) / Double(measureTicks)
            gaps.append(max(floorGap, span * inner))
        }
        let total = gaps.reduce(0, +)
        let fit = total > 0 ? inner / total : 1
        var map: [Int: Double] = [:]
        var cursor = x + 1.1
        for (offset, moment) in moments.enumerated() {
            map[moment] = cursor
            cursor += gaps[offset] * fit
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
