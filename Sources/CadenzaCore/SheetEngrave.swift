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
            let absolute = pulse(snap(anchor, to: grid)) - root
            var bar = 0
            for (index, start) in barStarts.enumerated() where start <= absolute { bar = index }
            let local = max(0, absolute - barStarts[bar])
            for note in cluster { attacks.insert("\(bar)-\(local)-\(note.pitch)") }
        }
        var byMeasure: [[Event]] = Array(repeating: [], count: barStarts.count)
        var strongest: [String: Event] = [:]
        for cluster in clusters {
            guard let anchor = cluster.map(\.start).min() else { continue }
            let absolute = pulse(snap(anchor, to: grid)) - root
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
        // 6. each staff splits into voices, fills its rests and beams inside
        // the beat; then the systems.
        var groups: [SheetDraft.BeamGroup] = []
        var nextID = 0
        let top = staff(events: treble, clef: .treble, options: options, fifths: fifths,
                        track: 0, groups: &groups, nextID: &nextID)
        let bottom = staff(events: bass, clef: .bass, options: options, fifths: fifths,
                           track: 1, groups: &groups, nextID: &nextID)

        let ties = SheetEngraver.ties(in: top.symbols, track: 0)
            + SheetEngraver.ties(in: bottom.symbols, track: 1)
        let slurs = SheetEngraver.slurs(in: top.symbols, measureTicks: measureTicks, track: 0)
            + SheetEngraver.slurs(in: bottom.symbols, measureTicks: measureTicks, track: 1)
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

    // MARK: ties

    /// The phrase marks a track carries: runs of notes the player joined
    /// without lifting the key, kept inside one bar and capped at four notes,
    /// which is how a phrase is written rather than how a finger moves.
    static func slurs(in symbols: [SheetDraft.Symbol], measureTicks: Int,
                      track: Int) -> [SheetDraft.Slur] {
        let columns = symbols.compactMap { symbol -> SheetDraft.Chord? in
            if case .chord(let chord) = symbol { return chord }
            return nil
        }.sorted { $0.startTicks < $1.startTicks }
        var runs: [[SheetDraft.Chord]] = []
        var run: [SheetDraft.Chord] = []
        func flush() {
            if run.count >= 2 { runs.append(run) }
            run = []
        }
        for chord in columns {
            if let last = run.last {
                let sameBar = chord.startTicks / measureTicks == last.startTicks / measureTicks
                let joined = chord.startTicks == last.endTicks
                if !sameBar || !joined || run.count == 4 { flush() }
            }
            run.append(chord)
        }
        flush()
        return runs.compactMap { group in
            guard let first = group.first, let last = group.last,
                  first.startTicks != last.startTicks else { return nil }
            return SheetDraft.Slur(track: track, fromTicks: first.startTicks,
                                   toTicks: last.startTicks)
        }
    }

    /// The ties a track's own symbols ask for: wherever a head says it keeps
    /// sounding and the very next column carries the same pitch, the two are
    /// tied. That covers a value split inside a bar and a note held over a
    /// barline with one rule, instead of two.
    static func ties(in symbols: [SheetDraft.Symbol], track: Int) -> [SheetDraft.Tie] {
        let columns = symbols.compactMap { symbol -> SheetDraft.Chord? in
            if case .chord(let chord) = symbol { return chord }
            return nil
        }.sorted { $0.startTicks < $1.startTicks }
        var result: [SheetDraft.Tie] = []
        for (index, chord) in columns.enumerated() where index + 1 < columns.count {
            let next = columns[index + 1]
            guard next.startTicks == chord.endTicks else { continue }
            for note in chord.notes where note.tieToNext {
                guard next.notes.contains(where: { $0.pitch == note.pitch }) else { continue }
                result.append(SheetDraft.Tie(track: track, pitch: note.pitch,
                                             fromTicks: chord.startTicks,
                                             toTicks: next.startTicks))
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

    /// Onset magnetism. A played note lands near the pulse, not on it, and a
    /// sheet that prints that jitter as sixteenths is a sheet nobody can read:
    /// an onset within a sixteenth of an eighth belongs to the eighth. Only
    /// what is genuinely between eighths stays on the sixteenth grid.
    private static func pulse(_ ticks: Int) -> Int {
        let quarter = SheetDraft.ticksPerQuarter
        let tolerance = max(1, quarter / 8)
        let nearest = Int((Double(ticks) / Double(quarter / 2)).rounded()) * (quarter / 2)
        return abs(nearest - ticks) <= tolerance ? nearest : ticks
    }

    private static func snap(_ ticks: Int, to grid: Int) -> Int {
        Int((Double(ticks) / Double(grid)).rounded()) * grid
    }

    /// One staff's symbol list: barline, columns, rests filling every gap,
    /// measure after measure.
    ///
    /// A staff holds up to two voices, the way a piano score does: a chord
    /// struck while the previous one is still sounding belongs to the second
    /// voice — the same rule MuseScore's MIDI import uses to split a taken
    /// staff. Voice one stems up and voice two stems down, each voice fills
    /// its own silences and beams inside its own beats, and that is what turns
    /// one chord stream into a melody sitting over an accompaniment.
    private static func staff(events: [[Event]], clef: SheetDraft.Clef,
                              options: SheetDraft.Options, fifths: Int, track: Int,
                              groups: inout [SheetDraft.BeamGroup],
                              nextID: inout Int) -> Staff {
        let measureTicks = options.measureTicks
        let gridSmall = max(1, SheetDraft.ticksPerQuarter / 4)
        let beat = SheetDraft.ticksPerQuarter
        var result = Staff()
        let measureCount = events.count
        for measure in 0..<measureCount {
            let absolute = measure * measureTicks
            result.symbols.append(.bar(startTicks: absolute))
            var indices: [Int] = []
            // what each voice prints in this bar, in order: a rest in the
            // sequence closes the beam it interrupts
            var sequences: [[(isChord: Bool, index: Int)]] = [[], []]

            var grouped: [Int: [Event]] = [:]
            for event in events[measure] {
                grouped[event.start, default: []].append(event)
            }
            let moments = grouped.keys.sorted()
            guard !moments.isEmpty else {
                // an empty bar is one whole rest, centred, not a bar of beats
                indices.append(result.symbols.count)
                result.symbols.append(.rest(startTicks: absolute, kind: .whole))
                result.measures.append(indices)
                continue
            }

            // 1. the columns of the bar, then their voices
            var columns: [(start: Int, notes: [Event], voice: Int)] = []
            for moment in moments {
                var notes = grouped[moment] ?? []
                notes.sort { $0.pitch < $1.pitch }
                columns.append((moment, notes, 0))
            }
            var voiceEnd = [0, 0]
            for index in columns.indices {
                let start = columns[index].start
                let voice = (0..<2).first { voiceEnd[$0] <= start } ?? 0
                columns[index].voice = voice
                voiceEnd[voice] = max(voiceEnd[voice],
                                      start + (columns[index].notes.map(\.duration).max() ?? 0))
            }
            let voiceCount = Set(columns.map(\.voice)).count

            var shownAccidentals = Set<String>()
            for voice in 0..<2 {
                let mine = columns.indices.filter { columns[$0].voice == voice }
                if mine.isEmpty {
                    // a silent upper voice still prints its whole-bar rest,
                    // above the lower voice's music
                    if voice == 0, columns.contains(where: { $0.voice == 1 }) {
                        sequences[0].append((false, result.symbols.count))
                        indices.append(result.symbols.count)
                        result.symbols.append(.restVoiced(startTicks: absolute, kind: .whole, voice: 0))
                    }
                    continue
                }
                var cursor = 0
                for (position, columnIndex) in mine.enumerated() {
                    let column = columns[columnIndex]
                    if column.start > cursor {
                        for rest in SheetDraft.rests(start: cursor, end: column.start) {
                            sequences[voice].append((false, result.symbols.count))
                            indices.append(result.symbols.count)
                            result.symbols.append(lifted(rest, by: absolute,
                                                         voice: voiceCount > 1 ? voice : nil))
                        }
                    }
                    let next = position + 1 < mine.count ? columns[mine[position + 1]].start : measureTicks
                    // The slot this column owns: until the same voice's next
                    // column, never past the bar. A chord is one vertical
                    // unit, so every head in it takes the same value. The
                    // value fills the slot when the player held the key
                    // through it; a note let go early prints short and rests
                    // close the bar after it, instead of stretching a
                    // staccato to the barline.
                    let slot = max(gridSmall, min(measureTicks - column.start, next - column.start))
                    let played = min(column.notes.map(\.duration).max() ?? slot, slot)
                    let value = played * 2 >= slot
                        ? slot
                        : max(gridSmall, (played / gridSmall) * gridSmall)
                    let notes = column.notes.map { note -> Event in
                        var copy = note
                        copy.duration = value
                        return copy
                    }
                    // which of these notes is still sounding when the bar
                    // ends: those get a tie over the barline
                    let held = Set(notes.filter(\.tied).map(\.pitch))
                    sequences[voice].append((true, result.symbols.count))
                    indices.append(result.symbols.count)
                    result.symbols.append(.chord(chord(from: notes, at: absolute + column.start,
                                                       clef: clef, fifths: fifths, held: held,
                                                       shown: &shownAccidentals,
                                                       voice: voice,
                                                       polyphonic: voiceCount > 1)))
                    cursor = max(cursor, column.start + value)
                }
                if cursor < measureTicks {
                    for rest in SheetDraft.rests(start: cursor, end: measureTicks) {
                        sequences[voice].append((false, result.symbols.count))
                        indices.append(result.symbols.count)
                        result.symbols.append(lifted(rest, by: absolute,
                                                     voice: voiceCount > 1 ? voice : nil))
                    }
                }
            }
            if indices.isEmpty {
                indices.append(result.symbols.count)
                result.symbols.append(.rest(startTicks: absolute, kind: .whole))
            }
            result.measures.append(indices)

            // 2. beams, inside the beat and inside the voice
            for voice in 0..<2 {
                beam(sequence: sequences[voice], symbols: &result.symbols,
                     track: track, beat: beat, groups: &groups, nextID: &nextID)
            }
        }
        result.symbols.append(.finalBar(startTicks: measureCount * measureTicks))
        return result
    }

    /// Beam the eighths and sixteenths of one voice inside one beat: a rest,
    /// a barline, a longer note or a new beat closes the group, and four is
    /// the longest run a beat can hold.
    private static func beam(sequence: [(isChord: Bool, index: Int)],
                             symbols: inout [SheetDraft.Symbol], track: Int, beat: Int,
                             groups: inout [SheetDraft.BeamGroup], nextID: inout Int) {
        var run: [Int] = []
        func close() {
            defer { run = [] }
            guard run.count >= 2 else { return }
            var up = true
            var flags = 1
            if case .chord(let first) = symbols[run[0]], let stem = first.stems.first {
                up = stem.up
                flags = stem.flags
            }
            for index in run {
                if case .chord(let chord) = symbols[index], let stem = chord.stems.first {
                    flags = max(flags, stem.flags)
                }
            }
            for index in run {
                guard case .chord(let chord) = symbols[index] else { continue }
                let stems = chord.stems.map { stem in
                    SheetDraft.Stem(noteRange: stem.noteRange, up: stem.up,
                                    flags: max(stem.flags, flags), beamGroupId: nextID)
                }
                symbols[index] = .chord(SheetDraft.Chord(startTicks: chord.startTicks,
                                                         endTicks: chord.endTicks,
                                                         notes: chord.notes, stems: stems))
            }
            groups.append(SheetDraft.BeamGroup(id: nextID, track: track,
                                               chordIndices: run, up: up, flags: flags))
            nextID += 1
        }
        for entry in sequence {
            guard entry.isChord, case .chord(let chord) = symbols[entry.index],
                  let stem = chord.stems.first else { close(); continue }
            let beamable = stem.flags > 0 && chord.notes.allSatisfy { $0.dots == 0 }
            guard beamable else { close(); continue }
            if let last = run.last, case .chord(let previous) = symbols[last],
               previous.startTicks / beat != chord.startTicks / beat {
                close()
            }
            run.append(entry.index)
            if run.count == 4 { close() }
        }
        close()
    }

    /// Rests are built bar by bar; the symbol list keeps one timeline for
    /// the whole piece, so every symbol can be placed the same way. A bar
    /// with two voices marks its rests so each sits in its own half of the
    /// staff.
    private static func lifted(_ symbol: SheetDraft.Symbol, by offset: Int,
                               voice: Int?) -> SheetDraft.Symbol {
        guard case .rest(let start, let kind) = symbol else { return symbol }
        if let voice {
            return .restVoiced(startTicks: start + offset, kind: kind, voice: voice)
        }
        return .rest(startTicks: start + offset, kind: kind)
    }

    /// One chord from the notes sharing a grid moment.
    private static func chord(from notes: [Event], at start: Int,
                              clef: SheetDraft.Clef, fifths: Int,
                              held: Set<Int> = [],
                              shown: inout Set<String>,
                              voice: Int = 0,
                              polyphonic: Bool = false) -> SheetDraft.Chord {
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
            // One stem per chord: the shortest printed value sets the flags.
            // In a bar with two voices the voice decides the direction, the
            // way polyphony is written; with one voice the classic rule does.
            var shortest = values[0]
            for value in values where value.flags > shortest.flags { shortest = value }
            let positions = glyphs.map(\.staffPosition)
            let up = polyphonic
                ? voice == 0
                : positions.reduce(0, +) / max(1, positions.count) < 4
            stems = [SheetDraft.Stem(noteRange: 0..<notes.count, up: up,
                                     flags: shortest.flags, beamGroupId: nil)]
        }
        // the events carry bar-local starts, this chord carries an absolute
        // one: the end is the start plus the longest played length
        let longest = notes.map(\.duration).max() ?? 0
        return SheetDraft.Chord(startTicks: start, endTicks: start + longest,
                               notes: glyphs, stems: stems)
    }

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
