import Foundation

/// The engraved score written as a LilyPond source file.
///
/// LilyPond is the engraver a publisher uses, and it is the only part of the
/// sheet pipeline Cadenza does not draw itself: this type hands it the music
/// and LilyPond decides where every head, stem, beam and slur of air goes. So
/// the file holds notes, meter, key and tempo — never a position.
///
/// The one musical decision left here is what belongs to a hand. A piano has
/// two staves and a performance is one stream: everything from middle C up is
/// the right hand, everything below it the left, the same line the screen's
/// layout draws. A hand is read as one voice, so a note lasts until the next
/// attack of that hand rather than into it — two pitches sounding at once in
/// one voice would print as polyphony nobody played.
public enum LilyPondScore {

    /// What the page says above the music.
    public struct Metadata: Sendable, Equatable {
        public var title: String?
        public var composer: String?
        public var subtitle: String?
        /// e.g. "Cadenza 1.4" — printed small, as an edition credits its engraver.
        public var tagline: String?

        public init(title: String? = nil, composer: String? = nil, subtitle: String? = nil,
                    tagline: String? = nil) {
            self.title = title
            self.composer = composer
            self.subtitle = subtitle
            self.tagline = tagline
        }
    }

    /// LilyPond reads the file it was written for; 2.26 is what the app ships.
    public static let version = "2.26.0"

    public static func text(_ score: Score, metadata: Metadata = Metadata()) -> String {
        let framing = score.framing
        var lines: [String] = []
        lines.append("\\version \"\(version)\"")
        lines.append("")
        if let header = header(metadata) {
            lines.append(header)
            lines.append("")
        }
        lines.append("#(set-global-staff-size 19.9)")
        // The title is drawn in the top margin, and the first system is placed
        // under it: the default margin is shallower than a title, which put the
        // music through its own heading.
        lines.append("\\paper { top-margin = 26\\mm }")
        lines.append("\\layout {")
        lines.append("  \\context {")
        lines.append("    \\Staff")
        lines.append("    printKeyCancellation = ##f")
        lines.append("  }")
        lines.append("}")
        lines.append("")
        lines.append("\\score {")
        lines.append("  \\new PianoStaff <<")
        for (index, hand) in [Hand.treble, Hand.bass].enumerated() {
            let clef = hand == .treble ? "treble" : "bass"
            lines.append("    \\new Staff \\with { \\clef \(clef) } {")
            lines.append(contentsOf: staffBody(score, hand: hand, framing: framing, first: index == 0))
            lines.append("    }")
        }
        lines.append("  >>")
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - header

    private static func header(_ metadata: Metadata) -> String? {
        var fields: [String] = []
        if let title = metadata.title, !title.isEmpty {
            fields.append("  title = \(quoted(title))")
        }
        if let subtitle = metadata.subtitle, !subtitle.isEmpty {
            fields.append("  subtitle = \(quoted(subtitle))")
        }
        if let composer = metadata.composer, !composer.isEmpty {
            fields.append("  composer = \(quoted(composer))")
        }
        if let tagline = metadata.tagline, !tagline.isEmpty {
            fields.append("  tagline = \(quoted(tagline))")
        }
        return fields.isEmpty ? nil : "\\header {\n" + fields.joined(separator: "\n") + "\n}"
    }

    /// LilyPond's strings are Scheme strings: a backslash and a quote escape,
    /// everything else — a title in Dutch, an apostrophe — travels unharmed.
    private static func quoted(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if character == "\\" || character == "\"" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return "\"\(escaped)\""
    }

    // MARK: - the two hands

    private enum Hand { case treble, bass }

    private static func belongs(_ pitch: Int, to hand: Hand) -> Bool {
        hand == .treble ? pitch >= 60 : pitch < 60
    }

    /// One attack of one hand: the pitches struck together and how long the
    /// hand holds them.
    private struct Attack {
        let onset: Int
        var duration: Int
        let pitches: [Int]
    }

    /// The grid an attack lands on. The score quantizes to a sixteenth, which
    /// is right for a line of runs and wrong for a page: a performance of a
    /// waltz puts an attack near every sixteenth, and printing them all turns
    /// three chords into a thicket. An eighth folds the flams and the roll of
    /// a chord back into the beat they belong to — the same grid the published
    /// editions of these pieces are read on.
    static let attackGrid = 240

    private static func attacks(_ score: Score, hand: Hand, measureTicks: Int) -> [Attack] {
        var byOnset: [Int: ([Int], Int)] = [:]
        for measure in score.measures {
            let barEnd = measure.startTick + measureTicks
            for note in measure.notes where belongs(note.pitch, to: hand) {
                // Rounded down, never up: a note a hair before the barline
                // belongs to the bar it was played in.
                let snapped = (note.onsetTick / attackGrid) * attackGrid
                // A note stops at the barline. A chord carried over a bar
                // would tie into whatever the next bar starts with, which is
                // not the same music and reads as a mistake.
                let room = max(0, barEnd - snapped)
                var entry = byOnset[snapped] ?? ([], 0)
                entry.0.append(note.pitch)
                entry.1 = max(entry.1, min(note.durationTicks + note.onsetTick - snapped, room))
                byOnset[snapped] = entry
            }
        }
        let sorted = byOnset.keys.sorted()
        var result: [Attack] = []
        for (index, onset) in sorted.enumerated() {
            let (pitches, duration) = byOnset[onset]!
            // A hand is one voice: the next attack of the same hand ends the
            // note that is still sounding.
            let limit = index + 1 < sorted.count ? sorted[index + 1] - onset : duration
            let writable = floorDuration(max(Self.smallest, min(duration, limit)))
            let unique = Array(Set(pitches)).sorted()
            result.append(Attack(onset: onset, duration: writable, pitches: unique))
        }
        return result
    }

    private static func staffBody(_ score: Score, hand: Hand, framing: ScoreFraming,
                                  first: Bool) -> [String] {
        let measureTicks = framing.timeSignature.ticksPerMeasure
        let events = attacks(score, hand: hand, measureTicks: measureTicks)
        var lines: [String] = []
        let prefix = "      "
        if first {
            let key = lilyKey(framing.key)
            let meter = "\\time \(framing.timeSignature.beatsPerMeasure)/\(framing.timeSignature.beatUnit)"
            let tempo = "\\tempo 4 = \(Int(framing.beatsPerMinute.rounded()))"
            lines.append(prefix + "\\key \(key.tonic) \\\(key.mode)")
            lines.append(prefix + meter + " " + tempo)
        }
        // The bars are the score's own measures, not a count from zero: the
        // engraver aligns measure one to the strongest downbeat, so bar one can
        // start on any tick and every bar after it inherits that offset.
        let bars = score.measures.isEmpty
            ? [ScoreMeasure(index: 0, startTick: 0, notes: [])]
            : score.measures
        for measure in bars {
            let start = measure.startTick
            let end = start + measureTicks
            var tokens: [String] = []
            var cursor = start
            for attack in events where attack.onset >= start && attack.onset < end {
                if attack.onset > cursor {
                    tokens.append(contentsOf: rests(for: attack.onset - cursor))
                }
                tokens.append(noteToken(pitches: attack.pitches, ticks: attack.duration,
                                        key: framing.key))
                cursor = min(end, max(cursor, attack.onset + attack.duration))
            }
            if cursor < end {
                tokens.append(contentsOf: rests(for: end - cursor))
            }
            lines.append(prefix + tokens.joined(separator: " ") + " |")
        }
        if !lines.isEmpty {
            lines[lines.count - 1] += " \\bar \"|.\""
        }
        return lines
    }

    // MARK: - one measure

    /// A rest has no pitch, so a gap is filled with the fewest symbols: the
    /// longest rest that still fits, again and again.
    private static func rests(for ticks: Int) -> [String] {
        var remaining = ticks
        var tokens: [String] = []
        while remaining > 0 {
            let value = durations.filter { $0.ticks <= remaining }.map(\.ticks).max() ?? smallest
            tokens.append("r" + (durationToken(value) ?? "32"))
            remaining -= value
        }
        return tokens
    }

    private static func noteToken(pitches: [Int], ticks: Int, key: KeySignature) -> String {
        let duration = durationToken(floorDuration(ticks)) ?? "32"
        let names = pitches.map { name(for: $0, in: key) }
        if names.count == 1 {
            return names[0] + duration
        }
        return "<" + names.joined(separator: " ") + ">" + duration
    }

    // MARK: - pitches

    private static let letters = ["c", "d", "e", "f", "g", "a", "b"]
    private static let letterSemitones = [0, 2, 4, 5, 7, 9, 11]

    /// A MIDI number has up to two correct spellings; the key decides which.
    /// In five flats the black key above C is a D flat, and printing a C sharp
    /// there would put an accidental on every line of the page.
    static func name(for midi: Int, in key: KeySignature) -> String {
        let pitchClass = ((midi % 12) + 12) % 12
        var best: (letter: String, alter: Int, cost: Int)?
        for (index, letter) in letters.enumerated() {
            var difference = pitchClass - letterSemitones[index]
            difference = ((difference % 12) + 12) % 12
            if difference > 6 { difference -= 12 }
            guard abs(difference) <= 1 else { continue }
            // A natural pitch is always spelled as itself; a chromatic one
            // leans the way the signature leans.
            var cost = abs(difference) * 10
            if difference != 0 {
                let prefersFlat = key.fifths < 0
                if (difference < 0) == prefersFlat { cost -= 1 }
            }
            if best == nil || cost < best!.cost {
                best = (letter, difference, cost)
            }
        }
        let letter = best?.letter ?? "c"
        let alter = best?.alter ?? 0
        let naturalMidi = midi - alter
        let octave = naturalMidi / 12 - 4
        let marks = octave > 0 ? String(repeating: "'", count: octave)
            : String(repeating: ",", count: max(0, -octave))
        let accidental = alter > 0 ? "is" : alter < 0 ? "es" : ""
        return letter + accidental + marks
    }

    // MARK: - keys

    static func lilyKey(_ key: KeySignature) -> (tonic: String, mode: String) {
        let major = ["ces", "ges", "des", "aes", "ees", "bes", "f", "c", "g", "d", "a", "e", "b", "fis", "cis"]
        let minor = ["aes", "ees", "bes", "f", "c", "g", "d", "a", "e", "b", "fis", "cis", "gis", "dis", "ais"]
        let fifths = max(-7, min(7, key.fifths))
        let table = key.isMinor ? minor : major
        return (table[fifths + 7], key.isMinor ? "minor" : "major")
    }

    // MARK: - durations

    /// Every value LilyPond prints as one symbol, with its tick length at the
    /// score's 480 ticks per quarter.
    private static let durations: [(ticks: Int, token: String)] = [
        (30, "64"), (60, "32"), (90, "32."), (120, "16"), (180, "16."),
        (240, "8"), (360, "8."), (480, "4"), (720, "4."),
        (960, "2"), (1440, "2."), (1920, "1"), (2880, "1."),
        (3840, "\\breve"), (5760, "\\breve."),
    ]

    private static let smallest = 30

    static func durationToken(_ ticks: Int) -> String? {
        durations.first { $0.ticks == ticks }?.token
    }

    /// The longest writable value that still fits inside `ticks`. A length
    /// that is not on the table is rounded down, and the rest of the room
    /// becomes air rather than a bar that counts wrong.
    static func floorDuration(_ ticks: Int) -> Int {
        durations.map(\.ticks).filter { $0 <= ticks }.max() ?? smallest
    }
}
