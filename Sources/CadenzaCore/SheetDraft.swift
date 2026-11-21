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
        /// The played note runs past this barline: the sheet ties the head
        /// over the bar instead of striking it again on the next downbeat.
        public var tieToNext: Bool = false
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
        // A key signature is a guess, and a wrong guess with five accidentals is
        // worse than a plain signature with one passing note outside it. So: score
        // every key by the time spent outside it, then prefer the key with the
        // fewest accidentals among those within a note or so of the best score.
        var scored: [(fifths: Int, outside: Int)] = []
        for fifths in -4...4 {
            let scale = majorScalePitchClasses(fifths)
            var outside = 0
            for pitchClass in 0..<12 where !scale.contains(pitchClass) {
                outside += histogram[pitchClass]
            }
            scored.append((fifths, outside))
        }
        guard let best = scored.map(\.outside).min() else { return 0 }
        let tolerance = max(1, pitches.count / 40)
        let near = scored.filter { $0.outside <= best + tolerance }
        let chosen = near.sorted { a, b in
            if a.outside != b.outside { return a.outside < b.outside }
            if abs(a.fifths) != abs(b.fifths) { return abs(a.fifths) < abs(b.fifths) }
            return a.fifths < b.fifths
        }.first
        return chosen?.fifths ?? 0
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
}
