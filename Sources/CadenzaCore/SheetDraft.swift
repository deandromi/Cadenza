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
        /// Onsets within this many milliseconds chordify together. A rolled
        /// chord spreads its notes over up to ~90 ms; a sixteenth line at a
        /// walking tempo spreads them further apart than that, so this is the
        /// window that folds a roll back into the chord it is.
        public var combineMillis: Double

        public init(bpm: Double = 120, numerator: Int = 4, denominator: Int = 4, combineMillis: Double = 90) {
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

        /// Staff position of a *spelled* note: the step its letter sits on,
        /// which is not the step its pitch class would take in a sharp key.
        /// A flat key writes A flat on the A line, where a sharp spelling
        /// would put a G sharp on the G line, a second lower.
        public func position(ofStep step: Int) -> Int {
            step - ScoreLayout.diatonicStep(bottomLinePitch)
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

    /// What a duration draws: the largest value of the classic ladder that
    /// fits inside it. Engraving shares the old rule that a note never
    /// prints longer than the time it owns — a half note in an 840-tick slot
    /// would run straight through the column after it — so a length that
    /// falls between rungs takes the rung below.
    public static func noteValue(_ durationTicks: Int) -> (head: Head, dots: Int, flags: Int) {
        let ladder: [(ticks: Int, value: (Head, Int, Int))] = [
            (4 * ticksPerQuarter, (.whole, 0, 0)),
            (3 * ticksPerQuarter, (.half, 1, 0)),
            (2 * ticksPerQuarter, (.half, 0, 0)),
            (3 * ticksPerQuarter / 2, (.filled, 1, 0)),
            (ticksPerQuarter, (.filled, 0, 0)),
            (3 * ticksPerQuarter / 4, (.filled, 1, 1)),
            (ticksPerQuarter / 2, (.filled, 0, 1)),
            (3 * ticksPerQuarter / 8, (.filled, 1, 2)),
            (ticksPerQuarter / 4, (.filled, 0, 2)),
            (ticksPerQuarter / 8, (.filled, 0, 3)),
        ]
        for rung in ladder where durationTicks >= rung.ticks { return rung.value }
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
        /// The voice the chord belongs to: two voices on one staff each keep
        /// their own timeline, and the rhythm audit needs to know which.
        public let voice: Int

        init(startTicks: Int, endTicks: Int, notes: [NoteGlyph], stems: [Stem], voice: Int = 0) {
            self.startTicks = startTicks
            self.endTicks = endTicks
            self.notes = notes
            self.stems = stems
            self.voice = voice
        }

        /// A copy with one stem retagged (beam groups and direction swaps).
        func retagging(stemIndex: Int, up: Bool, flags: Int, groupId: Int?) -> Chord {
            var stems = stems
            guard stems.indices.contains(stemIndex) else { return self }
            stems[stemIndex] = Stem(noteRange: stems[stemIndex].noteRange,
                                    up: up, flags: flags, beamGroupId: groupId)
            return Chord(startTicks: startTicks, endTicks: endTicks,
                         notes: notes, stems: stems, voice: voice)
        }
    }

    /// One drawn symbol in a hand track.
    public enum Symbol: Sendable, Equatable, Hashable {
        case chord(Chord)
        case rest(startTicks: Int, kind: RestKind)
        /// A rest that belongs to one of two voices on a staff: the upper
        /// voice's rests sit above the middle line, the lower voice's below,
        /// so the two never print on top of each other.
        case restVoiced(startTicks: Int, kind: RestKind, voice: Int)
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
            case .restVoiced(let t, _, _): return t
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
            case .chord, .rest, .restVoiced, .blank, .clefChange, .pedalDown, .pedalUp: return true
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
            case .rest, .restVoiced: return 1.8
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
        /// How far off its natural lane the symbol sits, in staff spaces:
        /// a rest in a two-voice bar steps aside from the other voice's
        /// chord instead of printing through it.
        public var yOffset: Double = 0
        /// How far to the right of its column the symbol sits, in staff
        /// spaces: a rest that shares its moment with the other voice's chord
        /// moves out of the chord's stem.
        public var xOffset: Double = 0
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

    /// One tie: a pitch that keeps sounding through a barline, from the last
    /// column of one measure to the first of the next. The engraver decides
    /// this; the renderer draws exactly these and nothing else.
    public struct Tie: Sendable, Equatable, Hashable {
        public let track: Int
        public let pitch: Int
        /// Absolute ticks of the outgoing note, the end of its measure.
        public let fromTicks: Int
        /// Absolute ticks of the incoming note, the start of the next measure.
        public let toTicks: Int

        public init(track: Int, pitch: Int, fromTicks: Int, toTicks: Int) {
            self.track = track
            self.pitch = pitch
            self.fromTicks = fromTicks
            self.toTicks = toTicks
        }
    }

    /// One phrase mark: the notes a player joined without lifting the key,
    /// from the first of the run to the last. The engraver decides where a
    /// slur begins and ends; the renderer draws exactly these.
    public struct Slur: Sendable, Equatable, Hashable {
        public let track: Int
        public let fromTicks: Int
        public let toTicks: Int

        public init(track: Int, fromTicks: Int, toTicks: Int) {
            self.track = track
            self.fromTicks = fromTicks
            self.toTicks = toTicks
        }
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
        /// Where the row writes an octave higher or lower than it sounds.
        public let octaves: [OctaveMark]

        public init(clefTop: Clef, clefBottom: Clef, top: [Placed], bottom: [Placed],
                    firstMeasure: Int, showsFraming: Bool, width: Double,
                    octaves: [OctaveMark] = []) {
            self.clefTop = clefTop
            self.clefBottom = clefBottom
            self.top = top
            self.bottom = bottom
            self.firstMeasure = firstMeasure
            self.showsFraming = showsFraming
            self.width = width
            self.octaves = octaves
        }
    }

    /// A stretch of bars written an octave away from its sounding pitch: a
    /// high passage is set an octave lower under an "8va", a low one an octave
    /// higher under an "8vb". The reading is a courtesy to the eye; the music
    /// is untouched, and the mark is what tells the player so.
    public struct OctaveMark: Sendable, Equatable {
        /// 0 for the treble staff, 1 for the bass staff.
        public let staff: Int
        public let from: Double
        public let to: Double
        /// True for 8va over the staff, false for 8vb under it.
        public let up: Bool

        public init(staff: Int, from: Double, to: Double, up: Bool) {
            self.staff = staff
            self.from = from
            self.to = to
            self.up = up
        }
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
        /// The ties the score carries, one per pitched continuation.
        public let ties: [Tie]
        /// The phrase marks the score carries, one per joined run of notes.
        public let slurs: [Slur]
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
                    rows: [Row], beamGroups: [BeamGroup], ties: [Tie] = [],
                    slurs: [Slur] = [],
                    width: Double, rowHeight: Double,
                    totalHeight: Double, rowsPerPage: Int = 0) {
            self.options = options
            self.fifths = fifths
            self.topTrack = topTrack
            self.bottomTrack = bottomTrack
            self.ties = ties
            self.slurs = slurs
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

    /// The guessed key.
    ///
    /// Counting the notes that fall outside each scale picks the smallest
    /// signature, and that is exactly how a waltz in D major came out in C
    /// major: it holds a C natural on every dominant seventh, so C scored as
    /// well as D and the plain signature won. The page then wore a sharp on
    /// every F and every C, which is what a reader sees as "wrong" long before
    /// they can name the key.
    ///
    /// A key is not the absence of accidentals, it is a *weighting* of the
    /// twelve pitch classes, and the classic Krumhansl–Kessler profiles are
    /// that weighting measured from listeners. So: correlate the played
    /// distribution against every key's profile, take the best match, and use
    /// the size of the signature only to settle a near tie. A note's weight is
    /// the time it sounds, so a held chord outvotes a passing sixteenth.
    public static func guessedFifths(pitches: [Int]) -> Int {
        guessedFifths(weights: pitches.map { (pitch: $0, weight: 1) })
    }

    /// The same guess, with each note weighted by how long it sounds.
    public static func guessedFifths(weights: [(pitch: Int, weight: Int)]) -> Int {
        var histogram = [Double](repeating: 0, count: 12)
        for entry in weights {
            histogram[((entry.pitch % 12) + 12) % 12] += Double(max(1, entry.weight))
        }
        guard histogram.contains(where: { $0 > 0 }) else { return 0 }
        // Krumhansl–Kessler key profiles, starting on the tonic.
        let major = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
        let minor = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
        var scored: [(fifths: Int, correlation: Double)] = []
        for tonic in 0..<12 {
            for (profile, isMinor) in [(major, false), (minor, true)] {
                let rotated = (0..<12).map { profile[((($0 - tonic) % 12) + 12) % 12] }
                scored.append((fifths: fifths(tonic: tonic, isMinor: isMinor),
                               correlation: correlation(histogram, rotated)))
            }
        }
        guard let best = scored.map(\.correlation).max() else { return 0 }
        // Two keys equally close to the ear: the smaller signature is the one a
        // player wants to read, so it settles the tie.
        let near = scored.filter { $0.correlation >= best - 0.02 }
        let chosen = near.sorted { a, b in
            if abs(a.fifths) != abs(b.fifths) { return abs(a.fifths) < abs(b.fifths) }
            return a.correlation > b.correlation
        }.first
        return chosen?.fifths ?? 0
    }

    /// How many sharps (positive) or flats (negative) a key is written with.
    /// A minor key borrows the signature of its relative major, three
    /// semitones up.
    static func fifths(tonic: Int, isMinor: Bool) -> Int {
        let majorTonic = isMinor ? (tonic + 3) % 12 : tonic
        let wheel = [0: 0, 7: 1, 2: 2, 9: 3, 4: 4, 11: 5, 6: 6,
                     1: -5, 8: -4, 3: -3, 10: -2, 5: -1]
        return wheel[majorTonic] ?? 0
    }

    /// Pearson correlation of two twelve-bin profiles.
    private static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let count = Double(min(a.count, b.count))
        guard count > 0 else { return 0 }
        let meanA = a.reduce(0, +) / count
        let meanB = b.reduce(0, +) / count
        var covariance = 0.0
        var varianceA = 0.0
        var varianceB = 0.0
        for index in 0..<Int(count) {
            let da = a[index] - meanA
            let db = b[index] - meanB
            covariance += da * db
            varianceA += da * da
            varianceB += db * db
        }
        guard varianceA > 0, varianceB > 0 else { return 0 }
        return covariance / (varianceA * varianceB).squareRoot()
    }

    /// The accidental a played pitch class needs in a key signature.
    /// How a key writes a pitch: the letter it sits on, and the accidental it
    /// carries. Positions are steps above C0, so callers can compare them.
    ///
    /// The spelling follows the key, the way a player reads it: a flat key
    /// writes A flat where a sharp key writes G sharp, and the two land on
    /// different lines. The accidental is only printed when the key signature
    /// does not already say it.
    public static func spelling(ofPitch pitch: Int, fifths: Int) -> (step: Int, accidental: Accidental) {
        let naturals = [0, 2, 4, 5, 7, 9, 11]
        let octave = pitch / 12 - 1
        let pc = ((pitch % 12) + 12) % 12
        var letter = 0
        for index in 0..<7 where naturals[index] <= pc { letter = index }
        if naturals[letter] != pc {
            // a black key: flat keys spell it as the letter above, and B flat
            // is written as a B even in sharp keys, the way scores always do
            if fifths < 0 || pc == 10 { letter = (letter + 1) % 7 }
        }
        let delta = pc - naturals[letter]
        var key: [Int: Int] = [:]
        if fifths > 0 {
            for (index, sharpLetter) in [3, 0, 4, 1, 5, 2, 6].prefix(min(7, fifths)).enumerated() {
                _ = index
                key[sharpLetter] = 1
            }
        } else if fifths < 0 {
            for flatLetter in [6, 2, 5, 1, 4, 0, 3].prefix(min(7, -fifths)) {
                key[flatLetter] = -1
            }
        }
        let keyDelta = key[letter] ?? 0
        let accidental: Accidental = delta == keyDelta
            ? .none
            : (delta == 0 ? .natural : (delta > 0 ? .sharp : .flat))
        return (octave * 7 + letter, accidental)
    }

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
