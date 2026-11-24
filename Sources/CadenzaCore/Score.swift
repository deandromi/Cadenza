/// The engraved score: measures of quantized notes on a tick grid, framed by
/// the tempo, key and meter the engraver chose from the performance. The
/// model is deliberately layout-free — a renderer decides what these look
/// like, so the same score can reach paper, glass or MusicXML.
///
/// Ticks: 480 per quarter note, the MIDI convention, so quantized values
/// stay integers down to the 32nd note and its dots.

/// A quarter note's worth of ticks, fixed everywhere in the score.
public let scoreTicksPerQuarter = 480

/// A time signature: 4/4 as beatsPerMeasure 4, beatUnit 4.
public struct TimeSignature: Sendable, Equatable, Hashable {
    /// Number of beat units per measure, the time signature's numerator.
    public let beatsPerMeasure: Int
    /// The note value one beat counts in, as a denominator: 4 for a quarter.
    public let beatUnit: Int

    public init(beatsPerMeasure: Int, beatUnit: Int) {
        self.beatsPerMeasure = beatsPerMeasure
        self.beatUnit = beatUnit
    }

    /// Ticks per measure: 4/4 is 4 * 480, 6/8 is 6 * 240.
    public var ticksPerMeasure: Int {
        scoreTicksPerQuarter * 4 * beatsPerMeasure / beatUnit
    }

    /// Ticks in one beat unit.
    public var ticksPerBeat: Int {
        scoreTicksPerQuarter * 4 / beatUnit
    }
}

/// The key the engraver heard, spelled as MusicXML wants it.
public struct KeySignature: Sendable, Equatable, Hashable {
    /// Root pitch class, C = 0.
    public let tonic: Int
    public let isMinor: Bool

    public init(tonic: Int, isMinor: Bool) {
        self.tonic = ((tonic % 12) + 12) % 12
        self.isMinor = isMinor
    }

    /// Sharp count of the key signature on the circle of fifths, negative
    /// for flats: C major and A minor are 0, G major 1, F major -1.
    public var fifths: Int {
        // a fifth's pitch-class arithmetic: seven semitones per fifth, the
        // same walk the circle takes, folded into the -6...5 range MusicXML
        // expects
        let walk = isMinor ? (tonic + 3) % 12 : tonic
        let raw = (walk * 7) % 12
        return raw > 6 ? raw - 12 : raw
    }

    /// Spelled name: "C major", "A minor".
    public var name: String {
        let letters = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "G♯", "A", "B♭", "B"]
        return letters[tonic] + (isMinor ? " minor" : " major")
    }
}

/// The framing the engraving pass chose for one performance.
public struct ScoreFraming: Sendable, Equatable {
    /// Inferred tempo in quarter notes per minute.
    public let beatsPerMinute: Double
    public let timeSignature: TimeSignature
    public let key: KeySignature

    public init(beatsPerMinute: Double, timeSignature: TimeSignature, key: KeySignature) {
        self.beatsPerMinute = beatsPerMinute
        self.timeSignature = timeSignature
        self.key = key
    }

    /// Seconds per quarter note at the chosen tempo.
    public var quarterSeconds: Double { 60.0 / beatsPerMinute }
}

/// One note as the score holds it: a pitch on the tick grid.
public struct ScoreNote: Sendable, Equatable {
    public let pitch: Int
    /// Onset in ticks from the score's start.
    public let onsetTick: Int
    /// Duration in ticks, snapped to a writable note value.
    public let durationTicks: Int
    public let velocity: Int

    public init(pitch: Int, onsetTick: Int, durationTicks: Int, velocity: Int) {
        self.pitch = pitch
        self.onsetTick = onsetTick
        self.durationTicks = durationTicks
        self.velocity = velocity
    }
}

/// A chord symbol placed above the staff.
public struct ScoreChordSymbol: Sendable, Equatable {
    /// Where the chord lands, in ticks from the score's start.
    public let onsetTick: Int
    public let symbol: String

    public init(onsetTick: Int, symbol: String) {
        self.onsetTick = onsetTick
        self.symbol = symbol
    }
}

/// A sustain pedal as the score holds it: where it went down and where it
/// came up, in ticks from the score's start.
public struct ScorePedal: Sendable, Equatable {
    public let startTick: Int
    public let endTick: Int

    public init(startTick: Int, endTick: Int) {
        self.startTick = startTick
        self.endTick = endTick
    }
}

/// One measure of the engraved score.
public struct ScoreMeasure: Sendable, Equatable {
    /// Zero-based sequential number; measure 1 shows the framing.
    public let index: Int
    public let startTick: Int
    public let notes: [ScoreNote]

    public init(index: Int, startTick: Int, notes: [ScoreNote]) {
        self.index = index
        self.startTick = startTick
        self.notes = notes
    }
}

/// The engraved performance: framing first, then the measures the framing
/// cut, with chord symbols where the chord engine heard changes.
public struct Score: Sendable, Equatable {
    public let framing: ScoreFraming
    public let measures: [ScoreMeasure]
    public let chords: [ScoreChordSymbol]
    /// The pedals the player made, merged so one press prints one mark.
    public let pedals: [ScorePedal]
    /// The soft pedal (una corda), which changes colour rather than length
    /// and gets its own two marks.
    public let softPedals: [ScorePedal]

    public init(framing: ScoreFraming, measures: [ScoreMeasure], chords: [ScoreChordSymbol],
                pedals: [ScorePedal] = [], softPedals: [ScorePedal] = []) {
        self.framing = framing
        self.measures = measures
        self.chords = chords
        self.pedals = pedals
        self.softPedals = softPedals
    }

    /// Total ticks the score spans, measures included.
    public var endTick: Int {
        let lastNote = measures.flatMap(\.notes).map { $0.onsetTick + $0.durationTicks }.max() ?? 0
        let lastMeasure = measures.last.map { $0.startTick } ?? 0
        return max(lastNote, lastMeasure)
    }
}
