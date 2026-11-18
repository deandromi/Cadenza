/// Chord inference over transcribed notes.
///
/// Chords are identified per onset group: the pitch classes sounded together
/// are matched against a quality table, with the root disambiguated by
/// interval content rather than by assuming the lowest note is the root.
public struct Chord: Sendable, Equatable {
    public struct Quality: Sendable, Equatable {
        public let name: String
        /// Intervals above the root in semitones, always including 0.
        public let intervals: Set<Int>

        public init(_ name: String, _ intervals: Set<Int>) {
            self.name = name
            self.intervals = intervals
        }
    }

    public let root: String
    public let quality: Quality
    public let onsetGroup: Int

    public var symbol: String { root + quality.name }

    public static let qualities: [Quality] = [
        Quality("", [0, 4, 7]),              // major
        Quality("m", [0, 3, 7]),             // minor
        Quality("dim", [0, 3, 6]),           // diminished
        Quality("aug", [0, 4, 8]),           // augmented
        Quality("sus4", [0, 5, 7]),          // suspended fourth
        Quality("sus2", [0, 2, 7]),          // suspended second
        Quality("maj7", [0, 4, 7, 11]),      // major seventh
        Quality("7", [0, 4, 7, 10]),         // dominant seventh
        Quality("m7", [0, 3, 7, 10]),        // minor seventh
        Quality("m7b5", [0, 3, 6, 10]),      // half-diminished
        Quality("dim7", [0, 3, 6, 9]),       // fully diminished seventh
        Quality("6", [0, 4, 7, 9]),          // major sixth
        Quality("m6", [0, 3, 7, 9]),         // minor sixth
    ]

    static let noteNames = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

    /// Identify the chord played by one onset group, or nil when the pitch
    /// set matches no known quality. With several candidate roots the one
    /// whose spelling produces a known quality at every transposition of the
    /// sounding set wins; ties fall back to the lowest bass note.
    public static func identify(in notes: [NoteEvent], group: Int) -> Chord? {
        let groupNotes = notes.filter { $0.onsetGroup == group }
        guard groupNotes.count >= 3 else { return nil }

        let sounding = Set(groupNotes.map(\.pitchClass))
        let bass = groupNotes.min(by: { $0.pitch < $1.pitch })!.pitchClass

        var candidates: [(root: Int, quality: Quality)] = []
        for quality in Self.qualities {
            for root in 0..<12 {
                let spelled = Set(quality.intervals.map { ($0 + root) % 12 })
                if spelled == sounding {
                    candidates.append((root, quality))
                }
            }
        }
        guard let best = candidates.min(by: {
            let aIsBass = $0.root == bass
            let bIsBass = $1.root == bass
            if aIsBass != bIsBass { return aIsBass }
            return $0.root < $1.root
        }) else { return nil }

        return Chord(
            root: Self.noteNames[best.root],
            quality: best.quality,
            onsetGroup: group
        )
    }
}
