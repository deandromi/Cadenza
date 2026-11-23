import Foundation

/// The layout pass: turns an engraved Score into drawable geometry — systems
/// of measures on a grand staff, noteheads at their staff positions with
/// stems, flags, dots and accidentals, rests, the key signature and chord
/// symbols. Pure Swift and view-free: the app draws whatever comes out, and
/// the checks assert on the geometry directly.
///
/// Vertical unit: a staff line gap (`lineGap`); one diatonic step is half of
/// it. A note's `staffPosition` counts diatonic steps above the staff's
/// bottom line, so the staff lines sit at 0, 2, 4, 6, 8 and the renderer
/// converts position to y without knowing which staff it is drawing.
public enum ScoreLayout {

    /// The gap between two staff lines, in points.
    public static let lineGap: Double = 9

    /// Gap between the two staves of the grand staff, in line gaps.
    public static let staffGap: Double = 5.0

    /// Left padding of a measure that shows clef, key and meter.
    public static let framingPad: Double = 66

    /// Left padding of an ordinary measure, right of the barline.
    public static let barlinePad: Double = 12

    /// Horizontal space per onset group inside a measure.
    public static let groupSpacing: Double = 30

    /// Minimum measure width, so empty measures still read as measures.
    public static let minMeasureWidth: Double = 54

    // MARK: pitch to staff position

    /// Diatonic step of a pitch: C4 is 28, each octave adds 7, each natural
    /// step in the octave adds 1. Accidentals do not move the step.
    public static func diatonicStep(_ pitch: Int) -> Int {
        let octave = pitch / 12 - 1
        let pc = ((pitch % 12) + 12) % 12
        let naturalPc = [0, 2, 4, 5, 7, 9, 11]
        var letter = 0
        for index in 0..<7 where naturalPc[index] <= pc {
            letter = index
        }
        return octave * 7 + letter
    }

    /// The bottom line of the treble staff is E4.
    public static let trebleBottomLinePitch = 64
    /// The bottom line of the bass staff is G2.
    public static let bassBottomLinePitch = 43

    /// Staff position (diatonic steps above the bottom line) of a pitch on
    /// the treble staff.
    public static func treblePosition(_ pitch: Int) -> Int {
        diatonicStep(pitch) - diatonicStep(trebleBottomLinePitch)
    }

    /// Staff position of a pitch on the bass staff.
    public static func bassPosition(_ pitch: Int) -> Int {
        diatonicStep(pitch) - diatonicStep(bassBottomLinePitch)
    }

    /// Middle C and above go to the treble staff, below to the bass.
    public static func isTreble(_ pitch: Int) -> Bool {
        pitch >= 60
    }

    // MARK: note values

    public enum HeadStyle: Sendable, Equatable {
        case filled   // quarter and shorter
        case hollow   // half
        case whole    // whole and longer, no stem
    }

    public enum Accidental: Sendable, Equatable {
        case sharp, flat, natural
    }

    /// What a duration in ticks draws as: head style, dots, flags, stem.
    public static func noteValue(_ durationTicks: Int) -> (head: HeadStyle, dots: Int, flags: Int, stem: Bool) {
        switch durationTicks {
        case 3840, 1920: return (.whole, 0, 0, false)
        case 1440: return (.hollow, 1, 0, true)
        case 960: return (.hollow, 0, 0, true)
        case 720: return (.filled, 1, 0, true)
        case 480: return (.filled, 0, 0, true)
        case 360: return (.filled, 1, 1, true)
        case 240: return (.filled, 0, 1, true)
        case 180: return (.filled, 1, 2, true)
        case 120: return (.filled, 0, 2, true)
        default: return (.filled, 0, 0, true)
        }
    }

    // MARK: key signatures

    /// The letters in circle-of-fifths order: F C G D A E B.
    private static let sharpOrder = [3, 0, 4, 1, 5, 2, 6]
    /// Flats in circle order: B E A D G C F.
    private static let flatOrder = [6, 2, 5, 1, 4, 0, 3]

    /// The letters a key signature with the given fifths alters.
    private static func alteredLetters(_ fifths: Int) -> Set<Int> {
        if fifths > 0 {
            return Set(sharpOrder.prefix(fifths))
        } else if fifths < 0 {
            return Set(flatOrder.prefix(-fifths))
        }
        return []
    }

    /// The accidental a pitch needs against a key signature, nil when the
    /// key signature already covers it.
    public static func accidental(for pitch: Int, fifths: Int) -> Accidental? {
        let pc = ((pitch % 12) + 12) % 12
        let naturalPc = [0, 2, 4, 5, 7, 9, 11]
        var letter = 0
        for index in 0..<7 where naturalPc[index] <= pc {
            letter = index
        }
        let alteration = pc - naturalPc[letter]
        let altered = alteredLetters(fifths)
        if fifths > 0 {
            if altered.contains(letter) {
                if alteration == 0 { return .natural }
                if alteration > 0 { return nil }
                return .flat
            }
        } else if fifths < 0 {
            if altered.contains(letter) {
                if alteration == 0 { return .natural }
                if alteration < 0 { return nil }
                return .sharp
            }
        }
        if alteration > 0 { return .sharp }
        if alteration < 0 { return .flat }
        return nil
    }

    /// One glyph of the key signature: where the sharp or flat sits on each
    /// staff, in staff positions. Treble sharp order: F5 C5 G5 D5 A4 E5 B4;
    /// bass: F3 C3 G3 D3 A2 E3 B2; flats mirror them.
    public struct KeyGlyph: Sendable, Equatable {
        public let treblePosition: Int
        public let bassPosition: Int
        public let accidental: Accidental
        public init(treblePosition: Int, bassPosition: Int, accidental: Accidental) {
            self.treblePosition = treblePosition
            self.bassPosition = bassPosition
            self.accidental = accidental
        }
    }

    /// The key signature glyphs for a fifths value, in order.
    public static func keyGlyphs(_ fifths: Int) -> [KeyGlyph] {
        // The key signature's own ladder, on the lines and spaces an edition
        // uses. A signature is read as a shape as much as a set of accidents,
        // and two of these used to stand a step away from where every edition
        // prints them: E flat on the D line, D flat on the E line, and the
        // seventh flat of C flat major under the staff.
        //   treble lines E4 G4 B4 D5 F5 (steps 0 2 4 6 8)
        //   bass lines   G2 B2 D3 F3 A3 (steps 0 2 4 6 8)
        let trebleSharps = [8, 5, 9, 6, 3, 7, 4]
        let bassSharps = [6, 3, 7, 4, 8, 5, 2]
        // The flat ladder, in the order the signature adds them: B, E, A, D,
        // G, C, F. In the bass the A flat stands on the top line and the G flat
        // in the space under it — a signature that dropped them a fifth read as
        // a scale running downhill instead of a key.
        let trebleFlats = [4, 7, 3, 6, 2, 5, 1]
        let bassFlats = [2, 5, 8, 4, 7, 3, 6]
        if fifths > 0 {
            return (0..<fifths).map { KeyGlyph(
                treblePosition: trebleSharps[$0],
                bassPosition: bassSharps[$0],
                accidental: .sharp
            ) }
        } else if fifths < 0 {
            return (0..<(-fifths)).map { KeyGlyph(
                treblePosition: trebleFlats[$0],
                bassPosition: bassFlats[$0],
                accidental: .flat
            ) }
        }
        return []
    }

    // MARK: laid-out geometry

    public struct Note: Sendable, Equatable {
        public let pitch: Int
        /// x within the measure, right edge of the notehead
        public let x: Double
        /// diatonic steps above the staff's bottom line
        public let staffPosition: Int
        public let head: HeadStyle
        public let dots: Int
        public let flags: Int
        public let stemUp: Bool
        public let accidental: Accidental?
        /// staff positions needing a ledger line through the notehead
        public let ledgerPositions: [Int]
        public let velocity: Int
        public init(pitch: Int, x: Double, staffPosition: Int, head: HeadStyle, dots: Int, flags: Int, stemUp: Bool, accidental: Accidental?, ledgerPositions: [Int], velocity: Int) {
            self.pitch = pitch
            self.x = x
            self.staffPosition = staffPosition
            self.head = head
            self.dots = dots
            self.flags = flags
            self.stemUp = stemUp
            self.accidental = accidental
            self.ledgerPositions = ledgerPositions
            self.velocity = velocity
        }
    }

    public struct Rest: Sendable, Equatable {
        public let x: Double
        /// a whole rest hangs from the fourth line, a half rest sits on the
        /// middle line
        public let staffPosition: Int
        public let whole: Bool
        public init(x: Double, staffPosition: Int, whole: Bool) {
            self.x = x
            self.staffPosition = staffPosition
            self.whole = whole
        }
    }

    public struct ChordSymbol: Sendable, Equatable {
        /// x within the measure
        public let x: Double
        public let symbol: String
        public init(x: Double, symbol: String) {
            self.x = x
            self.symbol = symbol
        }
    }

    public struct Measure: Sendable, Equatable {
        public let index: Int
        /// x within the system
        public let x: Double
        public let width: Double
        public let treble: [Note]
        public let bass: [Note]
        public let trebleRest: Rest?
        public let bassRest: Rest?
        public let chord: ChordSymbol?
        /// this measure opens a system: clef, key and meter draw here
        public let showsFraming: Bool
        public init(index: Int, x: Double, width: Double, treble: [Note], bass: [Note], trebleRest: Rest?, bassRest: Rest?, chord: ChordSymbol?, showsFraming: Bool) {
            self.index = index
            self.x = x
            self.width = width
            self.treble = treble
            self.bass = bass
            self.trebleRest = trebleRest
            self.bassRest = bassRest
            self.chord = chord
            self.showsFraming = showsFraming
        }
    }

    public struct System: Sendable, Equatable {
        /// y of the treble staff's top line, from the top of the layout
        public let y: Double
        public let measures: [Measure]
        public init(y: Double, measures: [Measure]) {
            self.y = y
            self.measures = measures
        }
    }

    public struct Result: Sendable, Equatable {
        public let systems: [System]
        public let keyGlyphs: [KeyGlyph]
        public let fifths: Int
        public let beatsPerMeasure: Int
        public let beatUnit: Int
        public let beatsPerMinute: Double
        public let lineGap: Double
        public let width: Double
        public let height: Double
        public init(systems: [System], keyGlyphs: [KeyGlyph], fifths: Int, beatsPerMeasure: Int, beatUnit: Int, beatsPerMinute: Double, lineGap: Double, width: Double, height: Double) {
            self.systems = systems
            self.keyGlyphs = keyGlyphs
            self.fifths = fifths
            self.beatsPerMeasure = beatsPerMeasure
            self.beatUnit = beatUnit
            self.beatsPerMinute = beatsPerMinute
            self.lineGap = lineGap
            self.width = width
            self.height = height
        }
    }

    // MARK: the pass

    /// Lays a score out on a grand staff inside the given width, wrapping
    /// measures into systems. Deterministic: same score, same geometry.
    public static func layout(_ score: Score, width: Double) -> Result {
        let fifths = score.framing.key.fifths
        let gap = lineGap

        // split the measures into systems by width
        var systems: [System] = []
        var current: [Measure] = []
        var currentWidth = 0.0
        let usable = width

        for (measureIndex, measure) in score.measures.enumerated() {
            if !current.isEmpty {
                // would this measure overflow the system? then it opens the
                // next one, and a system's first measure carries the framing
                let probe = layoutMeasure(measure, index: measureIndex, showsFraming: false, fifths: fifths, score: score)
                if currentWidth + probe.width > usable {
                    systems.append(System(y: 0, measures: current))
                    current = []
                    currentWidth = 0
                }
            }
            let showsFraming = measureIndex == 0 || current.isEmpty
            let laid = layoutMeasure(measure, index: measureIndex, showsFraming: showsFraming, fifths: fifths, score: score)
            let moved = Measure(
                index: laid.index, x: currentWidth, width: laid.width,
                treble: laid.treble, bass: laid.bass,
                trebleRest: laid.trebleRest, bassRest: laid.bassRest,
                chord: laid.chord, showsFraming: laid.showsFraming
            )
            current.append(moved)
            currentWidth += laid.width
        }
        if !current.isEmpty {
            systems.append(System(y: 0, measures: current))
        }

        // stack the systems vertically
        let systemHeight = 4 * gap + staffGap * gap + 4 * gap
        let topMargin = 3.8 * gap   // room for chord symbols above the staff
        let laidSystems = systems.enumerated().map { index, system in
            System(y: topMargin + Double(index) * (systemHeight + 2.5 * gap), measures: system.measures)
        }
        let height = topMargin + Double(max(1, laidSystems.count)) * systemHeight
            + Double(max(0, laidSystems.count - 1)) * 2.5 * gap + gap

        return Result(
            systems: laidSystems,
            keyGlyphs: keyGlyphs(fifths),
            fifths: fifths,
            beatsPerMeasure: score.framing.timeSignature.beatsPerMeasure,
            beatUnit: score.framing.timeSignature.beatUnit,
            beatsPerMinute: score.framing.beatsPerMinute,
            lineGap: gap,
            width: width,
            height: height
        )
    }

    /// Lays one measure out at x = 0; the caller offsets it.
    private static func layoutMeasure(
        _ measure: ScoreMeasure,
        index: Int,
        showsFraming: Bool,
        fifths: Int,
        score: Score
    ) -> Measure {
        let leftPad = showsFraming ? framingPad : barlinePad
        let byOnset = Dictionary(grouping: measure.notes, by: { $0.onsetTick })
        let groups = byOnset.keys.sorted()
        let width = max(minMeasureWidth, leftPad + Double(max(groups.count, 1)) * groupSpacing + 10)

        func place(_ notes: [ScoreNote], treble: Bool) -> [Note] {
            var laid: [Note] = []
            for (groupIndex, onset) in groups.enumerated() {
                let chordNotes = (byOnset[onset] ?? []).sorted { $0.pitch < $1.pitch }
                let x = leftPad + 8 + Double(groupIndex) * groupSpacing
                let positions = chordNotes.map { treble ? treblePosition($0.pitch) : bassPosition($0.pitch) }
                let meanPosition = positions.isEmpty ? 0 : Double(positions.reduce(0, +)) / Double(positions.count)
                let stemUp = meanPosition <= 4
                for note in chordNotes {
                    let position = treble ? treblePosition(note.pitch) : bassPosition(note.pitch)
                    let value = noteValue(note.durationTicks)
                    var ledgers: [Int] = []
                    var positionCursor = position
                    while positionCursor < 0 {
                        ledgers.append(positionCursor)
                        positionCursor += 2
                    }
                    positionCursor = position
                    while positionCursor > 8 {
                        ledgers.append(positionCursor)
                        positionCursor -= 2
                    }
                    laid.append(Note(
                        pitch: note.pitch,
                        x: x,
                        staffPosition: position,
                        head: value.head,
                        dots: value.dots,
                        flags: value.flags,
                        stemUp: value.stem ? stemUp : true,
                        accidental: accidental(for: note.pitch, fifths: fifths),
                        ledgerPositions: ledgers,
                        velocity: note.velocity
                    ))
                }
            }
            return laid
        }

        let trebleNotes = place(measure.notes.filter { isTreble($0.pitch) }, treble: true)
        let bassNotes = place(measure.notes.filter { !isTreble($0.pitch) }, treble: false)

        // an empty staff gets a whole rest hanging from its fourth line
        let trebleRest = trebleNotes.isEmpty
            ? Rest(x: width / 2, staffPosition: 6, whole: true) : nil
        let bassRest = bassNotes.isEmpty
            ? Rest(x: width / 2, staffPosition: 6, whole: true) : nil

        // the first chord symbol that falls inside this measure
        let measureStart = measure.startTick
        let measureEnd = measure.startTick + score.framing.timeSignature.ticksPerMeasure
        let chord = score.chords.first(where: { $0.onsetTick >= measureStart && $0.onsetTick < measureEnd })
            .map { ChordSymbol(x: leftPad + 4, symbol: $0.symbol) }

        return Measure(
            index: index,
            x: 0,
            width: width,
            treble: trebleNotes,
            bass: bassNotes,
            trebleRest: trebleRest,
            bassRest: bassRest,
            chord: chord,
            showsFraming: showsFraming
        )
    }
}
