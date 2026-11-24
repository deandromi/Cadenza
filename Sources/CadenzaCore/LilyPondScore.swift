import Foundation

/// The engraved score written as a LilyPond source file.
///
/// LilyPond is the engraver a publisher uses, and it is the only part of the
/// sheet pipeline Cadenza does not draw itself: this type hands it the music
/// and LilyPond decides where every head, stem, beam, slur and system break
/// goes. So the file holds notes, meter, key and tempo — never a position.
///
/// Three decisions are musical, and all three are about not inventing:
///
/// - **A hand is one voice.** Everything from middle C up is the right hand,
///   everything below it the left, and a note lasts until the next attack of
///   that hand rather than into it: two pitches at once in one voice would
///   print as polyphony nobody played.
/// - **A chord is an instant.** Pitches struck at the same quantized tick are
///   one chord; anything later is its own attack, so a run stays a run
///   instead of folding into a cluster the player never played.
/// - **A held note is tied, never cut.** A note that crosses a barline is
///   written as far as the bar goes, then tied into its remainder in the next
///   bar — which is how an edition writes a note the player held.
///
/// And one about the page: a staff is printed only when a hand played on it,
/// so a one-hand take is one staff rather than a grand staff of empty bars.
public enum LilyPondScore {

    /// What the page says above the music.
    public struct Metadata: Sendable, Equatable {
        public var title: String?
        public var composer: String?
        public var subtitle: String?
        /// e.g. "Cadenza 1.5" — printed small, as an edition credits its engraver.
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

    // MARK: - the file

    public static func text(_ score: Score, metadata: Metadata = Metadata()) -> String {
        let framing = score.framing
        let bars = bars(score, framing: framing)
        let played = Hand.allCases.filter { hand in
            score.measures.contains { measure in
                measure.notes.contains { belongs($0.pitch, to: hand) }
            }
        }
        // A take that never touched the keyboard still needs a page to print.
        let printed = played.isEmpty ? [Hand.treble] : played

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
        if printed.count == 1 {
            lines.append("  \\new Staff \\with { \\clef \(printed[0].clef) } {")
        } else {
            lines.append("  \\new PianoStaff <<")
        }
        for (index, hand) in printed.enumerated() {
            let indent = printed.count > 1 ? "    " : "  "
            if printed.count > 1 {
                lines.append("    \\new Staff \\with { \\clef \(hand.clef) } {")
            }
            lines.append(contentsOf: staffBody(score, hand: hand, framing: framing,
                                               bars: bars, first: index == 0))
            lines.append(indent + "}")
        }
        if printed.count > 1 {
            lines.append("  >>")
        }
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

    private enum Hand: CaseIterable {
        case treble, bass

        var clef: String {
            switch self {
            case .treble: return "treble"
            case .bass: return "bass"
            }
        }

        var name: String {
            switch self {
            case .treble: return "treble"
            case .bass: return "bass"
            }
        }
    }

    private static func belongs(_ pitch: Int, to hand: Hand) -> Bool {
        hand == .treble ? pitch >= 60 : pitch < 60
    }

    /// One attack of one hand: the pitches struck together and how long the
    /// hand holds them. The length may cross barlines; the staff writes it in
    /// pieces and ties them.
    private struct Attack {
        let onset: Int
        let duration: Int
        let pitches: [Int]

        var end: Int { onset + duration }
    }

    /// One printed bar: the score's own measures, kept with their start so a
    /// pickup (a bar that begins before the first tick) still lines up.
    private struct Bar {
        let index: Int
        let start: Int
        let end: Int

        /// Ticks the bar actually prints: a pickup bar is short by design.
        var printedStart: Int { max(start, 0) }
        var printedLength: Int { max(0, end - printedStart) }
    }

    private static func bars(_ score: Score, framing: ScoreFraming) -> [Bar] {
        let measureTicks = framing.timeSignature.ticksPerMeasure
        if score.measures.isEmpty {
            return [Bar(index: 0, start: 0, end: measureTicks)]
        }
        return score.measures.map { measure in
            Bar(index: measure.index, start: measure.startTick,
                end: measure.startTick + measureTicks)
        }
    }

    /// Every attack of one hand, in order. Onsets are the score's own
    /// quantized ticks: a chord is what sounded at one instant, never what
    /// happened to fall inside one grid cell.
    private static func attacks(_ score: Score, hand: Hand) -> [Attack] {
        var pitches: [Int: Set<Int>] = [:]
        var sounding: [Int: Int] = [:]
        for measure in score.measures {
            for note in measure.notes where belongs(note.pitch, to: hand) {
                pitches[note.onsetTick, default: []].insert(note.pitch)
                sounding[note.onsetTick] = max(sounding[note.onsetTick] ?? 0, note.durationTicks)
            }
        }
        let onsets = pitches.keys.sorted()
        var result: [Attack] = []
        for (index, onset) in onsets.enumerated() {
            // A hand is one voice: the next attack of the same hand ends the
            // note that is still sounding.
            let limit = index + 1 < onsets.count ? onsets[index + 1] - onset : Int.max
            // The length is kept exactly and split into writable values when
            // the bar is written: rounding it down here silently cut the tail
            // off every note that outlives a single symbol.
            let duration = max(smallest, min(sounding[onset] ?? smallest, limit))
            result.append(Attack(onset: onset, duration: duration,
                                 pitches: (pitches[onset] ?? []).sorted()))
        }
        return result
    }

    private static func staffBody(_ score: Score, hand: Hand, framing: ScoreFraming,
                                  bars: [Bar], first: Bool) -> [String] {
        let events = attacks(score, hand: hand)
        var lines: [String] = []
        let prefix = "      "
        let key = lilyKey(framing.key)
        let meter = "\\time \(framing.timeSignature.beatsPerMeasure)/\(framing.timeSignature.beatUnit)"
        // Every staff carries the key and the meter, the way a piano score
        // prints its signature on both staves; the tempo is marked once.
        lines.append(prefix + "\\key \(key.tonic) \\\(key.mode)")
        if first {
            lines.append(prefix + meter + " \\tempo 4 = \(Int(framing.beatsPerMinute.rounded()))")
        } else {
            lines.append(prefix + meter)
        }
        // A pickup is a short first bar, and LilyPond has to be told its
        // length or it reads the bar as one that lost a note.
        if let opener = bars.first, opener.start < 0, opener.printedLength > 0 {
            lines.append(prefix + "\\partial " + partialToken(opener.printedLength))
        }

        for bar in bars {
            let start = bar.printedStart
            let end = bar.end
            var tokens: [String] = []
            var cursor = start
            for event in events where event.end > start && event.onset < end {
                let pieceStart = max(event.onset, start)
                let pieceEnd = min(event.end, end)
                guard pieceEnd > pieceStart else { continue }
                if pieceStart > cursor {
                    tokens.append(contentsOf: rests(for: pieceStart - cursor))
                }
                tokens.append(contentsOf: tone(event.pitches, ticks: pieceEnd - pieceStart,
                                               tiedOnward: event.end > pieceEnd,
                                               key: framing.key))
                cursor = pieceEnd
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
        while remaining >= smallest {
            guard let value = durations.filter({ $0.ticks <= remaining }).map(\.ticks).max() else { break }
            tokens.append("r" + (durationToken(value) ?? "32"))
            remaining -= value
        }
        return tokens
    }

    /// One held note, written as far as it goes and tied to what follows. A
    /// value too long for one symbol (a note held across a 5/4 bar) becomes a
    /// chain of tied symbols, so nothing is silently shortened.
    private static func tone(_ pitches: [Int], ticks: Int, tiedOnward: Bool,
                             key: KeySignature) -> [String] {
        let names = pitches.map { name(for: $0, in: key) }
        let head = names.count == 1 ? names[0] : "<" + names.joined(separator: " ") + ">"
        var remaining = ticks
        var tokens: [String] = []
        while remaining >= smallest {
            let value = floorDuration(remaining)
            guard value > 0, value <= remaining else { break }
            let left = remaining - value
            let tie = left > 0 || tiedOnward
            tokens.append(head + (durationToken(value) ?? "32") + (tie ? "~" : ""))
            remaining = left
        }
        if tokens.isEmpty {
            tokens.append(head + "32" + (tiedOnward ? "~" : ""))
        }
        return tokens
    }

    /// The length of a pickup bar as LilyPond wants it: a plain value when it
    /// is one, a multiple of a sixteenth when it is not.
    private static func partialToken(_ ticks: Int) -> String {
        if let token = durationToken(ticks) {
            return token
        }
        let sixteenth = scoreTicksPerQuarter / 4
        let units = max(1, Int((Double(ticks) / Double(sixteenth)).rounded()))
        return "16*\(units)"
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
        (15, "128"), (30, "64"), (60, "32"), (90, "32."), (120, "16"), (180, "16."),
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

    // MARK: - what the page promises

    /// One thing the written page gets wrong. An empty list is a legal page.
    public struct Issue: Sendable, Equatable, CustomStringConvertible {
        public let staff: String
        public let measure: Int
        public let message: String

        public var description: String { "\(staff) bar \(measure): \(message)" }
    }

    /// The page checked against the rules it is written by: every bar counts
    /// its full length (a pickup its own short one), every token is a value
    /// LilyPond can read, and a tie joins a bar's end to the same pitches at
    /// the next bar's start. This audits the path that ships — the offline
    /// checks run it, and `--sheet-eval` runs it on real takes.
    public static func audit(_ score: Score, text: String? = nil) -> [Issue] {
        let source = text ?? self.text(score)
        let measureTicks = score.framing.timeSignature.ticksPerMeasure
        let barList = bars(score, framing: score.framing)
        var issues: [Issue] = []

        for staff in staffBodies(source) {
            for (position, tokens) in staff.bars.enumerated() {
                let expected = position < barList.count ? barList[position].printedLength : measureTicks
                var total = 0
                var readable = true
                for token in tokens {
                    if let length = tickLength(ofToken: token) {
                        total += length
                    } else {
                        readable = false
                        issues.append(Issue(staff: staff.clef, measure: position + 1,
                                            message: "reads no value for \(token)"))
                    }
                }
                if readable && total != expected {
                    issues.append(Issue(staff: staff.clef, measure: position + 1,
                                        message: "counts \(total) ticks where the bar holds \(expected)"))
                }
            }
            for (position, tokens) in staff.bars.enumerated() where position + 1 < staff.bars.count {
                guard let last = tokens.last, last.hasSuffix("~") else { continue }
                let next = staff.bars[position + 1].first
                if next == nil || next!.hasPrefix("r") || pitchSet(of: next!) != pitchSet(of: last) {
                    issues.append(Issue(staff: staff.clef, measure: position + 1,
                                        message: "a tie leaves \(pitchSet(of: last)) into nothing"))
                }
            }
        }
        return issues
    }

    /// Pitches the page prints, each counted once however a tie splits it.
    public static func headCount(_ score: Score) -> Int {
        var heads = 0
        for hand in Hand.allCases {
            heads += attacks(score, hand: hand).reduce(0) { $0 + $1.pitches.count }
        }
        return heads
    }

    /// How the page divides a take: the staves it prints, the widest chord it
    /// inks, and how many notes it has to tie across a barline.
    public static func summary(of score: Score) -> (staves: Int, widestChord: Int, tiedAttacks: Int) {
        let measureTicks = max(1, score.framing.timeSignature.ticksPerMeasure)
        let played = Hand.allCases.filter { hand in
            score.measures.contains { measure in
                measure.notes.contains { belongs($0.pitch, to: hand) }
            }
        }
        var widest = 0
        var tied = 0
        for hand in Hand.allCases {
            for attack in attacks(score, hand: hand) {
                widest = max(widest, attack.pitches.count)
                let startBar = attack.onset / measureTicks
                let endBar = max(attack.onset, attack.end - 1) / measureTicks
                if endBar > startBar { tied += 1 }
            }
        }
        return (played.isEmpty ? 1 : played.count, widest, tied)
    }

    // MARK: - reading the page back (the audit's own parser)

    private struct ParsedStaff {
        let clef: String
        var bars: [[String]]
    }

    private static func staffBodies(_ source: String) -> [ParsedStaff] {
        var result: [ParsedStaff] = []
        var current: ParsedStaff?
        var pendingPartial = false

        func finish() {
            guard var staff = current else { return }
            if pendingPartial, let first = staff.bars.first, first.isEmpty {
                staff.bars.removeFirst()
            }
            result.append(staff)
            current = nil
        }

        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\\clef ") || trimmed.contains("\\clef ") {
                finish()
                pendingPartial = false
                let clef = trimmed.components(separatedBy: "\\clef ").last?
                    .components(separatedBy: " ").first ?? "treble"
                current = ParsedStaff(clef: clef, bars: [])
                continue
            }
            if trimmed == "}" || trimmed == ">>" {
                finish()
                continue
            }
            guard var staff = current else { continue }
            if trimmed.hasPrefix("\\partial") {
                pendingPartial = true
                staff.bars.append([])
                current = staff
                continue
            }
            if trimmed.hasPrefix("\\key") || trimmed.hasPrefix("\\time") || trimmed.isEmpty {
                continue
            }
            if trimmed.contains("|") {
                var body = trimmed
                if body.hasSuffix("|") { body.removeLast() }
                staff.bars.append(parseTokens(body))
                current = staff
            }
        }
        finish()
        return result.filter { !$0.bars.isEmpty }
    }

    private static func parseTokens(_ bar: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var depth = 0
        for character in bar {
            if character == "<" { depth += 1 }
            if character == ">" { depth -= 1 }
            if character == " ", depth == 0 {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens.filter {
            !$0.hasPrefix("\\") && !$0.hasPrefix("\"") && $0 != "|"
        }
    }

    private static func pitchSet(of token: String) -> Set<String> {
        var body = token
        if body.hasSuffix("~") { body.removeLast() }
        if let open = body.firstIndex(of: "<"), let close = body.lastIndex(of: ">") {
            return Set(body[body.index(after: open)..<close].split(separator: " ").map(String.init))
        }
        for entry in durations where body.hasSuffix(entry.token) {
            return [String(body.dropLast(entry.token.count))]
        }
        return [body]
    }

    private static func tickLength(ofToken token: String) -> Int? {
        var body = token
        if body.hasSuffix("~") { body.removeLast() }
        if body.hasPrefix("r") { body.removeFirst() }
        for entry in durations where body.hasSuffix(entry.token) {
            return entry.ticks
        }
        return nil
    }
}
