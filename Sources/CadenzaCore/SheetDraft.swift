import Foundation

/// SheetDraft turns the live note stream into engraved sheet geometry using
/// the classic quantize-and-orchestrate process popularized by Midi Sheet
/// Music (and its MidiToSheetMusic command-line descendant):
///
/// 1. Onsets convert to ticks at the chosen tempo, the first note shifted
///    to time zero.
/// 2. Chordify: onsets within a combine interval (40 ms) collapse onto the
///    chain's earliest start, so a human chord reads as one chord.
/// 3. Round durations: each note extends up to the next onset, capped at a
///    quarter-note grid, so the music reads legato with fewer rests.
/// 4. The single piano stream splits into two hand tracks by register.
/// 5. The key signature is the one needing the fewest accidentals.
/// 6. Each measure's clef comes from its average pitch.
/// 7. The measures slice along the time signature grid, gaps fill with
///    rests, and both hands align column by column at layout time.
/// 8. Beam groups follow the classic beat rules: pairs (on the beat first,
///    then anywhere), fours in simple meters, threes for triplets and 12/8,
///    sixes in 3/4 and 6/x; only eighth and sixteenth stems beam, never
///    across a bar or through a rest.
/// 9. Measures wrap into rows at the page width, leftover width spreading
///    across columns, capped at two staff spaces per column.
///
/// This is an original Swift implementation of that process, written for
/// Cadenza's live stream: pure value-type Swift, no view frameworks, fully
/// covered by CadenzaCoreChecks.
public enum SheetDraft {
    public static let ticksPerQuarter = 480

    /// A note halfway through the pipeline, quantized to ticks.
    public struct RunningNote: Sendable, Equatable {
        public var start: Int
        public var duration: Int
        public var pitch: Int

        public init(start: Int, duration: Int, pitch: Int) {
            self.start = start
            self.duration = duration
            self.pitch = pitch
        }
    }

    /// One sustain-pedal span in ticks: pressed at start, released at end.
    public struct PedalSpan: Sendable, Equatable {
        public let startTick: Int
        public let endTick: Int

        public init(startTick: Int, endTick: Int) {
            self.startTick = startTick
            self.endTick = endTick
        }
    }

    // MARK: options

    public struct Options: Sendable, Equatable {
        /// Tempo in quarter notes per minute.
        public var bpm: Double
        /// Time signature top: beats per measure.
        public var numerator: Int
        /// Time signature bottom: the note value that gets the beat.
        public var denominator: Int
        /// Onsets within this many milliseconds chordify together.
        public var combineMillis: Double

        public init(bpm: Double = 120, numerator: Int = 4, denominator: Int = 4, combineMillis: Double = 40) {
            precondition(numerator > 0)
            precondition([1, 2, 4, 8, 16, 32].contains(denominator), "denominator must be a note value")
            self.bpm = bpm
            self.numerator = numerator
            self.denominator = denominator
            self.combineMillis = combineMillis
        }

        /// One measure in ticks.
        public var measureTicks: Int {
            4 * ticksPerQuarter / denominator * numerator
        }
    }

    // MARK: model

    public enum Clef: Sendable, Equatable, Hashable {
        case treble, bass

        /// The pitch of this staff's bottom line: E4, G2.
        public var bottomLinePitch: Int {
            switch self {
            case .treble: return 64
            case .bass: return 43
            }
        }

        /// Staff position of a pitch: diatonic steps above the bottom line.
        public func position(ofPitch pitch: Int) -> Int {
            ScoreLayout.diatonicStep(pitch) - ScoreLayout.diatonicStep(bottomLinePitch)
        }
    }

    public enum Accidental: Sendable, Equatable, Hashable {
        case sharp, flat, natural, none
    }

    /// The head a duration draws as. Whole heads draw no stem.
    public enum Head: Sendable, Equatable, Hashable {
        case whole, half, filled
    }

    public enum RestKind: Sendable, Equatable, Hashable {
        case whole, half, quarter, eighth, sixteenth, thirtysecond
    }

    /// What a duration draws, by the classic whole / dotted half / half /
    /// dotted quarter / quarter / dotted eighth / eighth / sixteenth /
    /// thirty-second ladder.
    public static func noteValue(_ durationTicks: Int) -> (head: Head, dots: Int, flags: Int) {
        let whole = 4 * ticksPerQuarter
        if durationTicks >= 28 * whole / 32 { return (.whole, 0, 0) }
        if durationTicks >= 20 * whole / 32 { return (.half, 1, 0) }
        if durationTicks >= 14 * whole / 32 { return (.half, 0, 0) }
        if durationTicks >= 10 * whole / 32 { return (.filled, 1, 0) }
        if durationTicks >= 7 * whole / 32 { return (.filled, 0, 0) }
        if durationTicks >= 5 * whole / 32 { return (.filled, 1, 1) }
        if durationTicks >= 6 * whole / 64 { return (.filled, 0, 1) }
        if durationTicks >= 3 * whole / 64 { return (.filled, 0, 2) }
        return (.filled, 0, 3)
    }

    public struct NoteGlyph: Sendable, Equatable, Hashable {
        public let pitch: Int
        /// Diatonic steps above the staff's bottom line; staff lines are even.
        public let staffPosition: Int
        public let head: Head
        public let dots: Int
        public let accidental: Accidental
        /// Ledger lines the head needs, outermost first.
        public let ledgers: [Int]
    }

    /// One stem of a chord: the notes it carries, its direction, its flags,
    /// and the beam group carrying them (nil when the stem stands alone).
    public struct Stem: Sendable, Equatable, Hashable {
        public let noteRange: Range<Int>
        public let up: Bool
        public let flags: Int
        public let beamGroupId: Int?
    }

    public struct Chord: Sendable, Equatable, Hashable {
        public let startTicks: Int
        public let endTicks: Int
        public let notes: [NoteGlyph]
        public let stems: [Stem]

        init(startTicks: Int, endTicks: Int, notes: [NoteGlyph], stems: [Stem]) {
            self.startTicks = startTicks
            self.endTicks = endTicks
            self.notes = notes
            self.stems = stems
        }

        /// A copy with one stem retagged (beam groups and direction swaps).
        func retagging(stemIndex: Int, up: Bool, flags: Int, groupId: Int?) -> Chord {
            var stems = stems
            guard stems.indices.contains(stemIndex) else { return self }
            stems[stemIndex] = Stem(noteRange: stems[stemIndex].noteRange,
                                    up: up, flags: flags, beamGroupId: groupId)
            return Chord(startTicks: startTicks, endTicks: endTicks,
                         notes: notes, stems: stems)
        }
    }

    /// One drawn symbol in a hand track.
    public enum Symbol: Sendable, Equatable, Hashable {
        case chord(Chord)
        case rest(startTicks: Int, kind: RestKind)
        case bar(startTicks: Int)
        /// The barline that closes the piece.
        case finalBar(startTicks: Int)
        /// A clef change, shown just before the measure that needs it.
        case clefChange(Clef, startTicks: Int)
        /// An alignment column that one hand misses; drawn as nothing.
        case blank(startTicks: Int)
        /// The meter drawn once at the piece's start.
        case timeSignature
        /// The sustain pedal goes down here (drawn as "Ped." below the
        /// bass staff, the line running to the matching pedalUp).
        case pedalDown(startTicks: Int)
        /// The sustain pedal releases here (drawn as the release star).
        case pedalUp(startTicks: Int)

        public var startTicks: Int {
            switch self {
            case .chord(let c): return c.startTicks
            case .rest(let t, _): return t
            case .bar(let t), .finalBar(let t): return t
            case .clefChange(_, let t): return t
            case .blank(let t): return t
            case .pedalDown(let t), .pedalUp(let t): return t
            case .timeSignature: return 0
            }
        }

        /// Column items are the things that align between barlines.
        public var isColumn: Bool {
            switch self {
            case .chord, .rest, .blank, .clefChange, .pedalDown, .pedalUp: return true
            default: return false
            }
        }

        /// Natural width in staff spaces before justification.
        public var width: Double {
            switch self {
            case .chord(let c):
                var w = 2.2
                w += 1.1 * Double(c.notes.filter { $0.accidental != .none }.count)
                w += 0.6 * Double(c.notes.map(\.dots).max() ?? 0)
                if c.stems.contains(where: { $0.flags > 0 }) { w += 0.4 }
                return w
            case .rest: return 1.8
            case .bar, .finalBar: return 0.8
            case .clefChange: return 2.6
            case .blank: return 0
            case .timeSignature: return 2.2
            case .pedalDown: return 2.4
            case .pedalUp: return 1.2
            }
        }
    }

    /// A symbol placed at its x offset, carrying its index in the track's
    /// symbol list (blanks carry -1) so beam partners can be found.
    public struct Placed: Sendable, Equatable {
        public let x: Double
        public let trackIndex: Int
        public let symbol: Symbol
    }

    /// A beam group: the member chords (indices into one track's symbol
    /// list), the beam's stem direction, and the flags the members carried
    /// (0 extra beams, 1 for one beam, 2 for a double beam).
    public struct BeamGroup: Sendable, Equatable {
        public let id: Int
        public let track: Int
        public let chordIndices: [Int]
        public let up: Bool
        public let flags: Int
    }

    /// One system row: the top and bottom staves with their placed symbols.
    public struct Row: Sendable, Equatable {
        public let clefTop: Clef
        public let clefBottom: Clef
        public let top: [Placed]
        public let bottom: [Placed]
        /// Measure number of the row's first measure, starting at 1.
        public let firstMeasure: Int
        /// True when the row opens the piece and shows clef, key and meter.
        public let showsFraming: Bool
        /// The row's right edge, in staff spaces.
        public let width: Double
    }

    public struct Result: Sendable, Equatable {
        public let options: Options
        /// Guessed key signature in fifths; positive sharps, negative flats.
        public let fifths: Int
        /// The full symbol lists per hand track; rows are slices of these.
        public let topTrack: [Symbol]
        public let bottomTrack: [Symbol]
        public let rows: [Row]
        public let beamGroups: [BeamGroup]
        /// Page width in staff spaces.
        public let width: Double
        /// Height of one row in staff spaces.
        public let rowHeight: Double
        /// Total height in staff spaces, top margin included.
        public let totalHeight: Double
        /// Systems per printed page; the renderer opens a page gap between
        /// pages. Zero means one continuous strip.
        public let rowsPerPage: Int

        public init(options: Options, fifths: Int, topTrack: [Symbol], bottomTrack: [Symbol],
                    rows: [Row], beamGroups: [BeamGroup], width: Double, rowHeight: Double,
                    totalHeight: Double, rowsPerPage: Int = 0) {
            self.options = options
            self.fifths = fifths
            self.topTrack = topTrack
            self.bottomTrack = bottomTrack
            self.rows = rows
            self.beamGroups = beamGroups
            self.width = width
            self.rowHeight = rowHeight
            self.totalHeight = totalHeight
            self.rowsPerPage = rowsPerPage
        }
    }

    // MARK: key signature

    /// The pitch classes of a major scale with the given fifths.
    public static func majorScalePitchClasses(_ fifths: Int) -> Set<Int> {
        let tonic = ((fifths * 7) % 12 + 12) % 12
        return Set([0, 2, 4, 5, 7, 9, 11].map { (tonic + $0) % 12 })
    }

    /// The guessed key: the one needing the fewest accidentals for the
    /// played pitch classes, scanning G flat major through B major.
    public static func guessedFifths(pitches: [Int]) -> Int {
        var histogram = [Int](repeating: 0, count: 12)
        for pitch in pitches {
            histogram[((pitch % 12) + 12) % 12] += 1
        }
        var bestFifths = 0
        var bestOutside = Int.max
        for fifths in -6...5 {
            let scale = majorScalePitchClasses(fifths)
            var outside = 0
            for pitchClass in 0..<12 where !scale.contains(pitchClass) {
                outside += histogram[pitchClass]
            }
            if outside < bestOutside {
                bestOutside = outside
                bestFifths = fifths
            }
        }
        return bestFifths
    }

    /// The accidental a played pitch class needs in a key signature.
    public static func accidental(pitchClass: Int, fifths: Int) -> Accidental {
        let pc = ((pitchClass % 12) + 12) % 12
        if majorScalePitchClasses(fifths).contains(pc) { return .none }
        let naturals: Set<Int> = [0, 2, 4, 5, 7, 9, 11]
        if naturals.contains(pc) { return .natural }
        // Black keys: sharp side spells sharps (except A sharp, which
        // spellers write as B flat); flat side spells flats (except D
        // sharp, which reads as E flat enharmonics inverted).
        if fifths >= 0 { return pc == 10 ? .flat : .sharp }
        return pc == 3 ? .sharp : .flat
    }

    // MARK: quantization

    /// Ticks for a time in seconds at the given tempo.
    public static func ticks(seconds: Double, options: Options) -> Int {
        Int((seconds * Double(ticksPerQuarter) * options.bpm / 60).rounded())
    }

    /// Ticks for a duration in milliseconds at the given tempo.
    public static func ticks(ms: Double, options: Options) -> Int {
        Int((Double(ticksPerQuarter) * options.bpm * ms / 60_000).rounded())
    }

    /// Chordify: onsets within the combine interval collapse onto the
    /// chain's earliest start. Chains extend greedily, like the classic
    /// fold, so a strummed chord still reads as one chord.
    public static func chordify(_ notes: [RunningNote], options: Options) -> [RunningNote] {
        var result = notes.sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) }
        let interval = ticks(ms: options.combineMillis, options: options)
        guard interval > 0, !result.isEmpty else { return result }
        var i = 0
        while i < result.count {
            let anchor = result[i].start
            while i + 1 < result.count, result[i + 1].start - anchor <= interval {
                result[i + 1].start = anchor
                i += 1
            }
            i += 1
        }
        return result
    }

    /// Round durations: each note stretches to just before the next onset,
    /// capped by the largest quarter-grid divisor that fits; the last chord
    /// keeps its sounded duration, and run pairs (adjacent equal onsets)
    /// stay intact so beams can form.
    public static func roundDurations(_ notes: [RunningNote]) -> [RunningNote] {
        var result = notes
        let quarter = ticksPerQuarter
        var previousNote: RunningNote?
        for i in 0..<result.count {
            guard i + 1 < result.count else { break }
            let note = result[i]
            var nextStart = result[i + 1].start
            var j = i + 1
            while j < result.count, result[j].start == note.start {
                nextStart = j + 1 < result.count ? result[j + 1].start : result[j].start
                j += 1
            }
            let maximum = nextStart > note.start ? nextStart - note.start : 0
            var dur = 0
            if quarter <= maximum { dur = quarter }
            else if quarter / 2 <= maximum { dur = quarter / 2 }
            else if quarter / 3 <= maximum { dur = quarter / 3 }
            else if quarter / 4 <= maximum { dur = quarter / 4 }
            if dur < note.duration { dur = note.duration }
            if let previous = previousNote,
               previous.start + previous.duration == note.start,
               previous.duration == note.duration {
                dur = note.duration
            }
            result[i].duration = dur
            if result[i + 1].start != note.start {
                previousNote = result[i]
            }
        }
        return result
    }

    // MARK: hand split

    /// Split the quantized stream into two hand tracks. For each note, the
    /// cascade picks the hand:
    /// - more than an octave from the exact-start extremes: nearer hand;
    /// - else more than an octave from the overlapping extremes: nearer;
    /// - else the exact-start extremes span an octave: nearer extreme;
    /// - else the overlapping extremes span an octave: nearer;
    /// - else follow the last octave-spanning extremes.
    public static func splitHands(_ notes: [RunningNote], measureTicks: Int) -> (top: [RunningNote], bottom: [RunningNote]) {
        var top: [RunningNote] = []
        var bottom: [RunningNote] = []
        guard !notes.isEmpty else { return ([], []) }
        var previousHigh = 76
        var previousLow = 45
        var startIndex = 0
        for note in notes {
            while startIndex < notes.count,
                   notes[startIndex].start + notes[startIndex].duration < note.start {
                startIndex += 1
            }
            let overlapping = extremesOverlap(notes, from: startIndex,
                                               measureTicks: measureTicks, note: note)
            let exact = extremesExact(notes, from: startIndex,
                                      start: note.start, fallback: note.pitch)
            let pitch = note.pitch
            if exact.high - pitch > 12 || pitch - exact.low > 12 {
                if exact.high - pitch <= pitch - exact.low { top.append(note) } else { bottom.append(note) }
            } else if overlapping.high - pitch > 12 || pitch - overlapping.low > 12 {
                if overlapping.high - pitch <= pitch - overlapping.low { top.append(note) } else { bottom.append(note) }
            } else if exact.high - exact.low > 12 {
                if exact.high - pitch <= pitch - exact.low { top.append(note) } else { bottom.append(note) }
            } else if overlapping.high - overlapping.low > 12 {
                if overlapping.high - pitch <= pitch - overlapping.low { top.append(note) } else { bottom.append(note) }
            } else {
                if previousHigh - pitch <= pitch - previousLow { top.append(note) } else { bottom.append(note) }
            }
            if overlapping.high - overlapping.low > 12 {
                previousHigh = overlapping.high
                previousLow = overlapping.low
            }
        }
        return (top, bottom)
    }

    /// The highest and lowest pitch overlapping the note's lifetime, with
    /// the window cut one measure past the note's start.
    static func extremesOverlap(_ notes: [RunningNote], from startIndex: Int,
                                measureTicks: Int, note: RunningNote) -> (high: Int, low: Int) {
        var high = note.pitch
        var low = note.pitch
        let end = min(note.start + note.duration, note.start + measureTicks)
        var i = startIndex
        while i < notes.count, notes[i].start < end {
            let other = notes[i]
            if other.start + other.duration >= note.start, note.start - other.start < measureTicks {
                high = max(high, other.pitch)
                low = min(low, other.pitch)
            }
            i += 1
        }
        return (high, low)
    }

    /// The highest and lowest pitch starting exactly at the given time.
    static func extremesExact(_ notes: [RunningNote], from startIndex: Int,
                              start: Int, fallback: Int) -> (high: Int, low: Int) {
        var i = startIndex
        while i < notes.count, notes[i].start < start { i += 1 }
        var high = fallback
        var low = fallback
        while i < notes.count, notes[i].start == start {
            high = max(high, notes[i].pitch)
            low = min(low, notes[i].pitch)
            i += 1
        }
        return (high, low)
    }

    // MARK: clefs per measure

    /// The clef each measure draws: F4 and above heads treble, G3 and below
    /// heads bass, the in-between keeps the track's dominant clef, and an
    /// empty measure keeps the previous clef.
    public static func measureClefs(notes: [RunningNote], measureTicks: Int) -> [Clef] {
        let average = notes.isEmpty ? 60 : notes.map(\.pitch).reduce(0, +) / notes.count
        let main: Clef = average >= 60 ? .treble : .bass
        var result: [Clef] = []
        var clef = main
        var nextMeasure = measureTicks
        var index = 0
        while index < notes.count {
            var sum = 0
            var count = 0
            while index < notes.count, notes[index].start < nextMeasure {
                sum += notes[index].pitch
                count += 1
                index += 1
            }
            if count > 0 {
                let average = sum / count
                if average >= 65 { clef = .treble }
                else if average <= 55 { clef = .bass }
                else { clef = main }
            }
            result.append(clef)
            nextMeasure += measureTicks
        }
        if result.isEmpty { result.append(main) }
        return result
    }

    /// The clef active at a tick from a measure-clef list.
    public static func clef(at start: Int, clefs: [Clef], measureTicks: Int) -> Clef {
        guard !clefs.isEmpty else { return .treble }
        return clefs[max(0, min(start / measureTicks, clefs.count - 1))]
    }

    // MARK: chord symbols

    /// Group a hand's notes into chords: one per shared start, with heads,
    /// dots, accidentals, staff positions, ledger lines and stems.
    public static func makeChords(from notes: [RunningNote], fifths: Int, clefs: [Clef], measureTicks: Int) -> [Chord] {
        var result: [Chord] = []
        var i = 0
        while i < notes.count {
            let start = notes[i].start
            var group: [RunningNote] = []
            while i < notes.count, notes[i].start == start {
                group.append(notes[i])
                i += 1
            }
            result.append(makeChord(group, fifths: fifths, clefs: clefs, measureTicks: measureTicks))
        }
        return result
    }

    private static func makeChord(_ group: [RunningNote], fifths: Int, clefs: [Clef], measureTicks: Int) -> Chord {
        let start = group[0].start
        let end = group.map { $0.start + $0.duration }.max() ?? start
        let clef = Self.clef(at: start, clefs: clefs, measureTicks: measureTicks)
        let values = group.map { noteValue($0.duration) }
        var notes: [NoteGlyph] = []
        for (note, value) in zip(group, values) {
            let position = clef.position(ofPitch: note.pitch)
            notes.append(NoteGlyph(
                pitch: note.pitch,
                staffPosition: position,
                head: value.head,
                dots: value.dots,
                accidental: accidental(pitchClass: note.pitch, fifths: fifths),
                ledgers: ledgers(forPosition: position)
            ))
        }
        var stems: [Stem] = []
        if let change = values.firstIndex(where: { $0 != values[0] }) {
            // Mixed durations: lower notes stem down, the tail stems up.
            if values[0].head != .whole {
                stems.append(Stem(noteRange: 0..<change, up: false, flags: values[0].flags, beamGroupId: nil))
            }
            if values[change].head != .whole {
                stems.append(Stem(noteRange: change..<group.count, up: true, flags: values[change].flags, beamGroupId: nil))
            }
        } else if values[0].head != .whole {
            stems.append(Stem(noteRange: 0..<group.count,
                             up: stemsUp(positions: notes.map(\.staffPosition)),
                             flags: values[0].flags,
                             beamGroupId: nil))
        }
        return Chord(startTicks: start, endTicks: end, notes: notes, stems: stems)
    }

    /// Ledger lines a staff position needs: even positions from -2 down to
    /// the note below the staff, 10 up to the note above, outermost first.
    public static func ledgers(forPosition position: Int) -> [Int] {
        var result: [Int] = []
        if position < 0 {
            var p = -2
            while p >= position { result.append(p); p -= 2 }
        } else if position > 8 {
            var p = 10
            while p <= position { result.append(p); p += 2 }
            result.reverse()
        }
        return result
    }

    /// The classic stem direction: the chord's average on or below the
    /// middle line stems up, above it stems down.
    public static func stemsUp(positions: [Int]) -> Bool {
        guard !positions.isEmpty else { return true }
        return positions.map { 4 - $0 }.reduce(0, +) >= 0
    }

    // MARK: rests

    /// The rest symbols that fill a gap, by the classic buckets: whole,
    /// half, quarter and eighth gaps take one rest; dotted gaps split into
    /// plain plus a shorter one (dotted half = half + quarter); gaps that
    /// bucket to sixteenth or smaller draw nothing.
    public static func rests(start: Int, end: Int) -> [Symbol] {
        let gap = end - start
        guard gap > 0 else { return [] }
        let whole = 4 * ticksPerQuarter
        let q = ticksPerQuarter
        if gap >= 28 * whole / 32 { return [.rest(startTicks: start, kind: .whole)] }
        if gap >= 20 * whole / 32 {
            return [.rest(startTicks: start, kind: .half),
                    .rest(startTicks: start + 2 * q, kind: .quarter)]
        }
        if gap >= 14 * whole / 32 { return [.rest(startTicks: start, kind: .half)] }
        if gap >= 10 * whole / 32 {
            return [.rest(startTicks: start, kind: .quarter),
                    .rest(startTicks: start + q, kind: .eighth)]
        }
        if gap >= 7 * whole / 32 { return [.rest(startTicks: start, kind: .quarter)] }
        if gap >= 5 * whole / 32 {
            return [.rest(startTicks: start, kind: .eighth),
                    .rest(startTicks: start + q / 2, kind: .sixteenth)]
        }
        if gap >= 6 * whole / 64 { return [.rest(startTicks: start, kind: .eighth)] }
        return []
    }

    // MARK: symbol list

    /// A hand's symbol list: bars at the measure grid, chords in order,
    /// rests in gaps (clipped at bars), and clef changes just before the
    /// measure that flips. The closing final bar ends the piece.
    public static func symbols(from chords: [Chord], clefs: [Clef], options: Options, lastStart: Int) -> [Symbol] {
        var result: [Symbol] = []
        let measureTicks = options.measureTicks
        var measureTime = 0
        var chordIndex = 0
        var previousEnd = 0
        var previousClef = Self.clef(at: 0, clefs: clefs, measureTicks: measureTicks)
        while chordIndex < chords.count {
            let chord = chords[chordIndex]
            if measureTime <= chord.startTicks {
                let clefHere = Self.clef(at: measureTime, clefs: clefs, measureTicks: measureTicks)
                if clefHere != previousClef {
                    result.append(.clefChange(clefHere, startTicks: measureTime))
                }
                previousClef = clefHere
                result.append(contentsOf: rests(start: previousEnd, end: measureTime))
                result.append(.bar(startTicks: measureTime))
                previousEnd = max(previousEnd, measureTime)
                measureTime += measureTicks
            } else {
                result.append(contentsOf: rests(start: previousEnd, end: chord.startTicks))
                result.append(.chord(chord))
                previousEnd = max(previousEnd, chord.endTicks)
                previousClef = Self.clef(at: chord.startTicks, clefs: clefs, measureTicks: measureTicks)
                chordIndex += 1
            }
        }
        while measureTime <= lastStart {
            result.append(.bar(startTicks: measureTime))
            measureTime += measureTicks
        }
        result.append(.finalBar(startTicks: measureTime))
        return result
    }

    // MARK: beams

    /// Merges pedal spans into a hand track as pedalDown/pedalUp marks,
    /// inserted in tick order: after a barline at the same tick, before
    /// anything else there, so a pedal press reads inside its measure. A
    /// span reaching past the final bar clamps to it — a pedal held to the
    /// end releases where the music ends.
    static func insertingPedals(_ spans: [PedalSpan], into symbols: [Symbol]) -> [Symbol] {
        let finalBarTick = symbols.last(where: {
            if case .finalBar = $0 { return true }
            return false
        })?.startTicks
        var marks: [(tick: Int, symbol: Symbol)] = []
        for span in spans where span.endTick > span.startTick {
            let end = finalBarTick.map { min(span.endTick, $0) } ?? span.endTick
            marks.append((span.startTick, .pedalDown(startTicks: span.startTick)))
            marks.append((end, .pedalUp(startTicks: end)))
        }
        marks.sort { $0.tick < $1.tick }
        var result: [Symbol] = []
        var index = 0
        for mark in marks {
            while index < symbols.count {
                let symbol = symbols[index]
                if symbol.startTicks < mark.tick {
                    result.append(symbol)
                    index += 1
                    continue
                }
                if symbol.startTicks == mark.tick {
                    if case .bar = symbol { result.append(symbol); index += 1; continue }
                    if case .finalBar = symbol { result.append(symbol); index += 1; continue }
                }
                break
            }
            result.append(mark.symbol)
        }
        result.append(contentsOf: symbols[index...])
        return result
    }

    /// The stem summary the beamer compares: head, dots, flags, whether
    /// the chord carries two stems, and its average staff position.
    struct StemSummary: Equatable {
        var head: Head
        var dots: Int
        var flags: Int
        var twoStems: Bool
        var positions: [Int]
    }

    static func stemSummary(of symbol: Symbol) -> StemSummary? {
        guard case .chord(let chord) = symbol else { return nil }
        guard let primary = chord.stems.first else { return nil }
        let note = chord.notes[primary.noteRange.lowerBound]
        var positions: [Int] = []
        for stem in chord.stems {
            if let first = chord.notes.indices.first(where: { stem.noteRange.contains($0) }) {
                positions.append(chord.notes[first].staffPosition)
            }
            if let last = chord.notes.indices.last(where: { stem.noteRange.contains($0) }) {
                positions.append(chord.notes[last].staffPosition)
            }
        }
        return StemSummary(head: note.head, dots: note.dots, flags: primary.flags,
                           twoStems: chord.stems.count > 1,
                           positions: positions)
    }

    /// The beam groups for one track, in the classic order: sixes (3/4 and
    /// 6/x eighths), triplet threes on the beat, threes in 12/8, fours in
    /// simple meters, pairs on the beat, pairs anywhere.
    public static func beamGroups(for symbols: [Symbol], options: Options) -> [(indices: [Int], up: Bool, flags: Int, dotted: Bool)] {
        let measure = options.measureTicks
        let quarter = ticksPerQuarter
        let chordIndexes = symbols.enumerated().compactMap { i, s -> Int? in
            guard case .chord(let chord) = s, !chord.stems.isEmpty else { return nil }
            if let primary = chord.stems.first, primary.beamGroupId != nil { return nil }
            return i
        }
        var taken = Set<Int>()
        var groups: [(indices: [Int], up: Bool, flags: Int, dotted: Bool)] = []

        func membersAreAdjacent(_ window: [Int]) -> Bool {
            for k in 1..<window.count {
                for s in symbols[(window[k - 1] + 1)..<window[k]] {
                    switch s {
                    case .chord, .blank: continue
                    default: return false
                    }
                }
                if symbols[window[k - 1]].startTicks / measure != symbols[window[k]].startTicks / measure {
                    return false
                }
                if window[k] == window[k - 1] { return false }
            }
            return true
        }

        func canBeam(_ window: [Int], mustStartOnBeat: Bool) -> Bool {
            guard window.count >= 2 else { return false }
            guard let base = stemSummary(of: symbols[window[0]]) else { return false }
            guard let tail = stemSummary(of: symbols[window[window.count - 1]]) else { return false }
            let dotted8to16 = window.count == 2 && base.dots == 1 && base.flags == 1
                && tail.dots == 0 && tail.flags == 2 && membersAreAdjacent([window[0], window[1]])
            if base.head == .whole || base.head == .half { return false }
            if base.flags == 0 { return false }
            if base.dots > 0 && !dotted8to16 { return false }
            if base.flags != tail.flags && !dotted8to16 { return false }
            let firstMeasure = symbols[window[0]].startTicks / measure
            for index in window {
                guard case .chord = symbols[index] else { return false }
                guard let summary = stemSummary(of: symbols[index]) else { return false }
                if taken.contains(index) { return false }
                if symbols[index].startTicks / measure != firstMeasure { return false }
                if summary.head == .whole || summary.head == .half { return false }
                if summary.flags != base.flags, !(dotted8to16 && index == window[window.count - 1]) { return false }
                if summary.dots > 0, !((index == window[0] && dotted8to16) || summary.dots == 0) { return false }
            }
            let firstStart = symbols[window[0]].startTicks
            let tolerance = quarter / 6
            switch window.count {
            case 6:
                guard base.flags == 1,
                      (options.numerator == 3 && options.denominator == 4)
                      || (options.numerator == 6 && options.denominator == 8)
                      || (options.numerator == 6 && options.denominator == 4) else { return false }
                if options.numerator == 6 && options.denominator == 4, firstStart % (quarter * 3) > tolerance {
                    return false
                }
            case 4:
                if options.numerator == 3 && options.denominator == 8 { return false }
                let simpleMeter = options.numerator == 2 || options.numerator == 4 || options.numerator == 8
                if !simpleMeter && base.flags != 2 { return false }
                let beat = base.flags == 1 ? quarter * 2 : quarter
                if firstStart % beat > tolerance { return false }
            case 3:
                let triplet = base.flags == 2 && base.dots == 0
                let twelveEight = base.flags == 1 && options.numerator == 12 && options.denominator == 8
                guard triplet || twelveEight else { return false }
                let beat = twelveEight ? quarter / 2 * 3 : quarter
                if firstStart % beat > tolerance { return false }
            default:
                if mustStartOnBeat, firstStart % quarter > tolerance { return false }
            }
            return true
        }

        func sweep(_ count: Int, onBeat: Bool) {
            var i = 0
            while i < chordIndexes.count {
                guard i + count <= chordIndexes.count else { break }
                let window = Array(chordIndexes[i..<(i + count)])
                if membersAreAdjacent(window), canBeam(window, mustStartOnBeat: onBeat) {
                    var up = true
                    var decided = false
                    for index in window {
                        if let summary = stemSummary(of: symbols[index]), summary.twoStems {
                            // A two-stem chord fixes the beam to its lower
                            // (down) stem.
                            up = false
                            decided = true
                            break
                        }
                    }
                    if !decided {
                        let positions = window.compactMap { stemSummary(of: symbols[$0])?.positions }.flatMap { $0 }
                        up = stemsUp(positions: positions)
                    }
                    for index in window { taken.insert(index) }
                    let base = stemSummary(of: symbols[window[0]])
                    let tail = stemSummary(of: symbols[window[window.count - 1]])
                    let flags = base?.flags ?? 1
                    let dotted = window.count == 2 && base?.dots == 1 && base?.flags == 1
                        && tail?.dots == 0 && tail?.flags == 2
                    groups.append((window, up, flags, dotted))
                    i += count
                } else {
                    i += 1
                }
            }
        }

        let sixMeter = (options.numerator == 3 && options.denominator == 4)
            || (options.numerator == 6 && options.denominator == 8)
            || (options.numerator == 6 && options.denominator == 4)
        if sixMeter { sweep(6, onBeat: true) }
        sweep(3, onBeat: true)
        sweep(4, onBeat: true)
        sweep(2, onBeat: true)
        sweep(2, onBeat: false)
        return groups
    }

    /// Apply beam groups: member chord stems in the beaming stem lose their
    /// flags and carry the group's global id. In two-stem chords the stem
    /// matching the group's direction beams; the other keeps its flags.
    public static func applyBeams(to symbols: inout [Symbol],
                                  groups: [(indices: [Int], up: Bool, flags: Int, dotted: Bool)],
                                  idOffset: Int) {
        for (groupId, group) in groups.enumerated() {
            for index in group.indices {
                guard case .chord(let chord) = symbols[index] else { continue }
                if chord.stems.isEmpty { continue }
                var stemIndex = 0
                if chord.stems.count > 1 {
                    // The lower stem points down, the upper up; match the beam.
                    stemIndex = group.up ? chord.stems.count - 1 : 0
                }
                symbols[index] = .chord(chord.retagging(
                    stemIndex: stemIndex, up: group.up, flags: 0, groupId: idOffset + groupId
                ))
            }
        }
    }

    // MARK: measure cells and rows

    /// Both hands share the same bar times, so each measure is a cell of
    /// column items between its barlines. Returns one pair per measure.
    static func measureCells(top: [Symbol], bottom: [Symbol], measureTicks: Int)
        -> [(start: Int, top: [Symbol], bottom: [Symbol])] {
        func cells(_ symbols: [Symbol]) -> [(start: Int, items: [Symbol])] {
            var result: [(Int, [Symbol])] = []
            var start = 0
            var items: [Symbol] = []
            for s in symbols {
                switch s {
                case .bar(let t):
                    result.append((start, items))
                    start = t
                    items = []
                case .finalBar:
                    result.append((start, items))
                    items = []
                default:
                    if s.isColumn { items.append(s) }
                }
            }
            return result
        }
        let topCells = cells(top)
        let bottomCells = cells(bottom)
        let count = max(topCells.count, bottomCells.count)
        var result: [(Int, [Symbol], [Symbol])] = []
        for i in 0..<count {
            let t = i < topCells.count ? topCells[i].items : []
            let b = i < bottomCells.count ? bottomCells[i].items : []
            let start = i < topCells.count
                ? topCells[i].start
                : (i < bottomCells.count ? bottomCells[i].start : 0)
            result.append((start, t, b))
        }
        return result
    }

    /// The row layout: measures accumulate whole into rows at the page
    /// width; each measure's columns are the union of both hands' column
    /// times; a hand missing a column draws a zero-width blank. Leftover
    /// row width spreads equally across columns, capped at two spaces.
    /// Track indices run through the original symbol lists so beam
    /// partners stay findable.
    public static func layoutRows(top: [Symbol], bottom: [Symbol], clefsTop: [Clef], clefsBottom: [Clef],
                                  options: Options, pageWidth: Double) -> [Row] {
        let measureTicks = options.measureTicks
        let cells = measureCells(top: top, bottom: bottom, measureTicks: measureTicks)
        let framingWidth = 9.5
        var rows: [Row] = []
        var cellIndex = 0

        // An index of (track, symbol index) -> symbol for track lookups.
        func trackIndexOf(_ symbol: Symbol, at after: Int, list: [Symbol]) -> Int {
            var i = after
            while i < list.count {
                if list[i] == symbol { return i }
                i += 1
            }
            return -1
        }

        while cellIndex < cells.count {
            var width = framingWidth
            var fitting: [Int] = []
            while cellIndex < cells.count {
                let cell = cells[cellIndex]
                var cellWidth = cell.top.reduce(0.0) { $0 + $1.width }
                cellWidth = max(cellWidth, cell.bottom.reduce(0.0) { $0 + $1.width })
                cellWidth = max(cellWidth, 1.6) + 0.8
                if !fitting.isEmpty, width + cellWidth > pageWidth { break }
                width += cellWidth
                fitting.append(cellIndex)
                cellIndex += 1
            }
            if fitting.isEmpty {
                fitting.append(cellIndex)
                cellIndex += 1
            }

            // Column times across the row's measures.
            var columnTimes: [Int] = []
            for cellNumber in fitting {
                let cell = cells[cellNumber]
                var times = Set<Int>()
                for s in cell.top + cell.bottom where s.isColumn {
                    times.insert(s.startTicks)
                }
                columnTimes.append(contentsOf: times.sorted())
            }

            // Leftover width spreads across columns, up to two each.
            var extra = 0.0
            if width < pageWidth, !columnTimes.isEmpty {
                extra = min(2.0, (pageWidth - width) / Double(columnTimes.count))
                width = min(pageWidth, width + extra * Double(columnTimes.count))
            }

            var topPlaced: [Placed] = []
            var bottomPlaced: [Placed] = []
            var tx = framingWidth
            var bx = framingWidth
            var topCursor = 0
            var bottomCursor = 0
            let firstStart = cells[fitting[0]].start

            for cellNumber in fitting {
                let cell = cells[cellNumber]
                let barSymbol = Symbol.bar(startTicks: cell.start)
                topCursor = advanceCursor(topCursor, in: top, to: barSymbol.startTicks)
                bottomCursor = advanceCursor(bottomCursor, in: bottom, to: barSymbol.startTicks)
                topPlaced.append(Placed(x: tx, trackIndex: topCursor, symbol: barSymbol))
                bottomPlaced.append(Placed(x: bx, trackIndex: bottomCursor, symbol: barSymbol))
                tx += barSymbol.width
                bx += barSymbol.width

                // This measure's own column times, split between hands.
                var times = Set<Int>()
                for s in cell.top + cell.bottom where s.isColumn && s.startTicks >= cell.start
                    && s.startTicks < cell.start + measureTicks {
                    times.insert(s.startTicks)
                }
                for t in times.sorted() {
                    func draw(_ items: [Symbol], x: inout Double, cursor: inout Int,
                              placed: inout [Placed], list: [Symbol]) {
                        // every column item at this time takes its place in
                        // order (a pedal mark and its chord share a column)
                        var placedAny = false
                        for item in items where item.isColumn && item.startTicks == t {
                            let index = trackIndexOf(item, at: cursor, list: list)
                            placed.append(Placed(x: x, trackIndex: index, symbol: item))
                            x += item.width + extra
                            if index >= 0 { cursor = index }
                            placedAny = true
                        }
                        if !placedAny {
                            placed.append(Placed(x: x, trackIndex: -1, symbol: .blank(startTicks: t)))
                            x += extra
                        }
                    }
                    draw(cell.top, x: &tx, cursor: &topCursor, placed: &topPlaced, list: top)
                    draw(cell.bottom, x: &bx, cursor: &bottomCursor, placed: &bottomPlaced, list: bottom)
                }
            }

            // The closing bar of the piece lands at the last row's end.
            let end = cells[fitting[fitting.count - 1]].start + measureTicks
            let closing: Symbol = cellIndex >= cells.count ? .finalBar(startTicks: end) : .bar(startTicks: end)
            let topClose = { () -> Int in var i = topCursor; while i < top.count { if top[i] == closing { return i }; i += 1 }; return topCursor }()
            let bottomClose = { () -> Int in var i = bottomCursor; while i < bottom.count { if bottom[i] == closing { return i }; i += 1 }; return bottomCursor }()
            topPlaced.append(Placed(x: tx, trackIndex: topClose, symbol: closing))
            bottomPlaced.append(Placed(x: bx, trackIndex: bottomClose, symbol: closing))
            tx += closing.width
            bx += closing.width

            let firstMeasure = firstStart / measureTicks + 1
            let clefTop = Self.clef(at: firstStart, clefs: clefsTop, measureTicks: measureTicks)
            let clefBottom = Self.clef(at: firstStart, clefs: clefsBottom, measureTicks: measureTicks)
            rows.append(Row(clefTop: clefTop, clefBottom: clefBottom,
                            top: topPlaced, bottom: bottomPlaced,
                            firstMeasure: firstMeasure,
                            showsFraming: firstStart == 0,
                            width: max(tx, bx)))
        }
        if rows.isEmpty {
            rows.append(Row(clefTop: .treble, clefBottom: .bass, top: [], bottom: [],
                           firstMeasure: 1, showsFraming: true, width: framingWidth))
        }
        return rows
    }

    /// Move the cursor to the first symbol at or after the given time.
    private static func advanceCursor(_ cursor: Int, in symbols: [Symbol], to start: Int) -> Int {
        var i = cursor
        while i < symbols.count, symbols[i].startTicks < start { i += 1 }
        return i
    }

    // MARK: the pipeline

    /// Engrave the live note stream into a complete sheet draft. Pedal
    /// spans arrive in ticks ( pedal down to release); they engrave as
    /// Ped./release marks under the bass staff.
    public static func draft(notes: [NoteEvent] /* live stream */, options: Options, pageWidth: Double = 88,
                             pedals: [PedalSpan] = []) -> Result {
        SheetEngraver.engrave(notes: notes, options: options, pageWidth: pageWidth, pedals: pedals)
    }

    /// The options a performance itself argues for: tempo from the pulse of
    /// the played onsets, meter from where the accents fall. A session has no
    /// file header to read, so this is how the sheet picks a 3/4 waltz over a
    /// default 4/4, which no amount of engraving can fix afterwards.
    public static func inferredOptions(notes: [NoteEvent]) -> Options {
        guard notes.count >= 4 else { return Options() }
        let tempo = Engraver.inferTempo(notes)
        let meter = Engraver.inferTimeSignature(notes, tempo: tempo)
        let bass = bassMeterGuess(notes, tempo: tempo)
        let numerator = bass ?? meter.beatsPerMeasure
        return Options(bpm: tempo,
                       numerator: numerator,
                       denominator: meter.beatUnit)
    }

    /// The meter the left hand argues for.
    ///
    /// A waltz bass lands on the downbeat and nowhere else, so the lowest
    /// note of each attack clusters on the bar line of the true meter and
    /// smears under a wrong one. That is a sharper signal than the full
    /// onset histogram, which every meter explains about equally well once
    /// subdivisions are in play. Nil when the bass says nothing.
    public static func bassMeterGuess(_ notes: [NoteEvent], tempo: Double) -> Int? {
        let quarter = 60.0 / tempo
        guard quarter > 0.05 else { return nil }
        // the lowest note of every attack: the bass voice. Attacks are
        // grouped by onset rather than by onsetGroup, because an imported
        // MIDI file carries no group ids.
        var lowest: [Int: (onset: Double, pitch: Int)] = [:]
        for note in notes {
            let slot = Int((note.onset / 0.05).rounded())
            if let current = lowest[slot] {
                if note.pitch < current.pitch {
                    lowest[slot] = (min(current.onset, note.onset), note.pitch)
                }
            } else {
                lowest[slot] = (note.onset, note.pitch)
            }
        }
        let all = lowest.values.sorted { $0.onset < $1.onset }
        // the bass voice proper: the attacks whose lowest note sits in the
        // bottom of the piece's register. Inner chords on the weak beats sit
        // a third or fifth higher and would smear the very barline this
        // measures.
        let floor = all.map(\.pitch).min() ?? 0
        let deep = all.filter { $0.pitch <= floor + 7 }
        let bass = deep.count >= 4 ? deep : all
        guard bass.count >= 4 else { return nil }
        let origin = bass[0].onset
        var best: (numerator: Int, score: Double)?
        for numerator in [3, 4, 2] {
            let bar = quarter * Double(numerator)
            let window = 0.12  // an eighth of a 3/4 bar, near enough to hear
            var hits = 0
            for note in bass {
                let position = ((note.onset - origin).truncatingRemainder(dividingBy: bar)) / bar
                if position < window || position > 1 - window { hits += 1 }
            }
            let share = Double(hits) / Double(bass.count)
            // how much better than chance on a grid this coarse
            let score = share - 2 * window
            if ProcessInfo.processInfo.environment["CDZ_METER_DEBUG"] != nil {
                print(String(format: "[meter] %d/4 share %.2f score %.2f", numerator, share, score))
            }
            if best == nil || score > best!.score + 0.02 {
                best = (numerator, score)
            }
        }
        guard let best, best.score > 0.03 else { return nil }
        return best.numerator
    }

    private static func emptyResult(options: Options) -> Result {
        var top: [Symbol] = [.bar(startTicks: 0), .finalBar(startTicks: options.measureTicks)]
        var bottom: [Symbol] = [.bar(startTicks: 0), .finalBar(startTicks: options.measureTicks)]
        func place(_ list: [Symbol]) -> [Placed] {
            var x = 9.5
            return list.enumerated().map { i, s in
                let p = Placed(x: x, trackIndex: i, symbol: s)
                x += s.width
                return p
            }
        }
        let row = Row(clefTop: .treble, clefBottom: .bass,
                      top: place(top), bottom: place(bottom),
                      firstMeasure: 1, showsFraming: true, width: 88)
        let rowHeight = 4.0 + ScoreLayout.staffGap + 4.0 + 12.0
        return Result(options: options, fifths: 0, topTrack: top, bottomTrack: bottom,
                      rows: [row], beamGroups: [], width: 88, rowHeight: rowHeight,
                      totalHeight: rowHeight + 6.0, rowsPerPage: SheetEngraver.systemsPerPage)
    }
}
