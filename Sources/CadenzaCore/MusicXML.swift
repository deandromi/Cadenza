import Foundation

/// MusicXML export: the engraved score as a partwise MusicXML 4.0 document,
/// the interchange format MuseScore, Sibelius and Dorico open directly. The
/// document is built by walking the score's measures in order; nothing here
/// makes a musical decision of its own — every choice was made in the score.
public enum MusicXML {

    /// One quarter note counts 120 divisions, so every writable duration
    /// from the sixteenth to the dotted whole stays a whole number.
    private static let divisions = 120
    private static let ticksPerDivision = scoreTicksPerQuarter / 4

    public static func write(_ score: Score) -> String {
        let measureTicks = score.framing.timeSignature.ticksPerMeasure
        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append("<score-partwise version=\"4.0\">")
        lines.append("  <part-list>")
        lines.append("    <score-part id=\"P1\">")
        lines.append("      <part-name>Piano</part-name>")
        lines.append("    </score-part>")
        lines.append("  </part-list>")
        lines.append("  <part id=\"P1\">")

        let written = Self.consecutiveMeasures(score.measures, measureTicks: measureTicks)
        for measure in written {
            lines.append("    <measure number=\"\(measure.index + 1)\">")
            if measure.index == score.measures.first?.index {
                lines.append(contentsOf: attributes(framing: score.framing))
            }
            for chord in score.chords
            where chord.onsetTick >= measure.startTick
                && chord.onsetTick < measure.startTick + measureTicks {
                lines.append("      <direction placement=\"above\">")
                lines.append("        <direction-type>")
                lines.append("          <words>\(escaped(chord.symbol))</words>")
                lines.append("        </direction-type>")
                lines.append("        <offset>\((chord.onsetTick - measure.startTick) / ticksPerDivision)</offset>")
                lines.append("      </direction>")
            }
            lines.append(contentsOf: measureBody(measure, measureTicks: measureTicks))
            lines.append("    </measure>")
        }

        lines.append("  </part>")
        lines.append("</score-partwise>")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The measure-one header: divisions, the chosen key and meter, and
    /// the metronome mark carrying the chosen tempo.
    private static func attributes(framing: ScoreFraming) -> [String] {
        var lines: [String] = []
        lines.append("      <attributes>")
        lines.append("        <divisions>\(divisions)</divisions>")
        lines.append("        <key>")
        lines.append("          <fifths>\(framing.key.fifths)</fifths>")
        lines.append("          <mode>\(framing.key.isMinor ? "minor" : "major")</mode>")
        lines.append("        </key>")
        lines.append("        <time>")
        lines.append("          <beats>\(framing.timeSignature.beatsPerMeasure)</beats>")
        lines.append("          <beat-type>\(framing.timeSignature.beatUnit)</beat-type>")
        lines.append("        </time>")
        lines.append("      </attributes>")
        lines.append("      <direction placement=\"above\">")
        lines.append("        <direction-type>")
        lines.append("          <metronome>")
        lines.append("            <beat-unit>quarter</beat-unit>")
        lines.append("            <per-minute>\(Int(framing.beatsPerMinute.rounded()))</per-minute>")
        lines.append("          </metronome>")
        lines.append("        </direction-type>")
        lines.append("      </direction>")
        return lines
    }

    /// The notes, chords and rests of one measure, in document order: gaps
    /// become rests, durations stay inside the bar, stacked notes carry the
    /// chord mark, and the bar fills with rest to its end.
    private static func measureBody(
        _ measure: ScoreMeasure,
        measureTicks: Int
    ) -> [String] {
        var lines: [String] = []
        let measureEnd = measure.startTick + measureTicks
        var cursorTick = measure.startTick
        var lastOnset: Int?

        for note in measure.notes {
            let onset = note.onsetTick
            if onset > cursorTick {
                lines.append(contentsOf: rest(from: cursorTick, to: min(onset, measureEnd)))
            }
            let duration = min(note.durationTicks, measureEnd - onset)
            guard duration > 0 else { continue }
            let stacked = onset == lastOnset
            lines.append(contentsOf: keyed(note, duration: duration, chorded: stacked))
            lastOnset = onset
            cursorTick = onset + duration
        }

        if cursorTick < measureEnd {
            lines.append(contentsOf: rest(from: cursorTick, to: measureEnd))
        }
        return lines
    }

    private static func keyed(_ note: ScoreNote, duration: Int, chorded: Bool) -> [String] {
        var lines: [String] = []
        lines.append("      <note>")
        if chorded {
            lines.append("        <chord/>")
        }
        lines.append("        <pitch>")
        let spelling = Self.spelling(note.pitch)
        lines.append("          <step>\(spelling.step)</step>")
        if spelling.alter != 0 {
            lines.append("          <alter>\(spelling.alter)</alter>")
        }
        lines.append("          <octave>\(note.pitch / 12 - 1)</octave>")
        lines.append("        </pitch>")
        lines.append("        <duration>\(duration / ticksPerDivision)</duration>")
        if let type = noteType(duration) {
            lines.append("        <type>\(type.value)</type>")
            for _ in 0..<type.dots {
                lines.append("        <dot/>")
            }
        }
        lines.append("        <voice>1</voice>")
        lines.append("      </note>")
        return lines
    }

    private static func rest(from: Int, to: Int) -> [String] {
        let duration = to - from
        guard duration > 0 else { return [] }
        var lines: [String] = []
        lines.append("      <note>")
        lines.append("        <rest/>")
        lines.append("        <duration>\(duration / ticksPerDivision)</duration>")
        if let type = noteType(duration) {
            lines.append("        <type>\(type.value)</type>")
            for _ in 0..<type.dots {
                lines.append("        <dot/>")
            }
        }
        lines.append("        <voice>1</voice>")
        lines.append("      </note>")
        return lines
    }

    /// The note value a duration reads as, nearest plain or dotted shape
    /// from the breve down to the sixteenth, in true tick arithmetic:
    /// a quarter is scoreTicksPerQuarter, a whole is twice that.
    private static func noteType(_ ticks: Int) -> (value: String, dots: Int)? {
        let plain: [(value: String, base: Int)] = [
            ("breve", 8 * scoreTicksPerQuarter),
            ("whole", 4 * scoreTicksPerQuarter),
            ("half", 2 * scoreTicksPerQuarter),
            ("quarter", scoreTicksPerQuarter),
            ("eighth", scoreTicksPerQuarter / 2),
            ("16th", scoreTicksPerQuarter / 4),
        ]
        var best: (value: String, dots: Int, gap: Int)?
        for candidate in plain {
            for dots in 0...1 {
                let span = dots == 1 ? candidate.base + candidate.base / 2 : candidate.base
                let gap = abs(span - ticks)
                if gap < (best?.gap ?? Int.max) {
                    best = (candidate.value, dots, gap)
                }
            }
        }
        guard let best else { return nil }
        return (best.value, best.dots)
    }

    /// Pitch-class spelling, sharps for the black keys; B stays natural
    /// and A-sharp's twin reads as B-flat, the piano's habit.
    private static func spelling(_ pitch: Int) -> (step: String, alter: Int) {
        switch ((pitch % 12) + 12) % 12 {
        case 0: return ("C", 0)
        case 1: return ("C", 1)
        case 2: return ("D", 0)
        case 3: return ("D", 1)
        case 4: return ("E", 0)
        case 5: return ("F", 0)
        case 6: return ("F", 1)
        case 7: return ("G", 0)
        case 8: return ("G", 1)
        case 9: return ("A", 0)
        case 10: return ("B", -1)
        case 11: return ("B", 0)
        default: return ("C", 0)
        }
    }

    /// Silent measures still belong in the document: consecutive numbers,
    /// filled as whole-measure rests, so readers never lose the count.
    private static func consecutiveMeasures(
        _ measures: [ScoreMeasure],
        measureTicks: Int
    ) -> [ScoreMeasure] {
        guard let first = measures.first, let last = measures.last else { return measures }
        var byIndex = Dictionary(uniqueKeysWithValues: measures.map { ($0.index, $0) })
        for index in first.index...last.index where byIndex[index] == nil {
            byIndex[index] = ScoreMeasure(
                index: index,
                startTick: index * measureTicks,
                notes: []
            )
        }
        return (first.index...last.index).map { byIndex[$0]! }
    }

    private static func escaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
