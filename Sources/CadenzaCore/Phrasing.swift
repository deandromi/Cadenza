import Foundation

// MARK: - what a phrase is made of

/// One sounding event as the phrase model sees it. A chord is one event:
/// the player struck it in one motion, so a slur covers it in one mark.
public struct PhraseEvent: Sendable, Equatable {
    public let onsetTick: Int
    public let endTick: Int
    /// Every pitch that sounded, so the model can tell a repeat from a line.
    public let pitches: [Int]

    public init(onsetTick: Int, endTick: Int, pitches: [Int]) {
        self.onsetTick = onsetTick
        self.endTick = endTick
        self.pitches = pitches
    }

    public var lowest: Int { pitches.min() ?? 0 }
    public var highest: Int { pitches.max() ?? 0 }
}

/// A phrase, named by the events it spans (indices into the stream it came
/// from, first and last included). Indices rather than ticks because two
/// chords may share an onset and a tick pair would not say which one ends.
public struct PhraseSpan: Sendable, Equatable {
    public let first: Int
    public let last: Int

    public init(first: Int, last: Int) {
        self.first = first
        self.last = last
    }

    public var count: Int { last - first + 1 }
}

// MARK: - the model

/// Where a player's line breathes, read from the performance alone.
///
/// A slur is not a legato rule: nearly every attack in a piano take runs on
/// from the one before (85% of them in the reference takes), so "note touches
/// the next" would slur the page end to end. A phrase is instead a run of
/// whole measures, which is what an engraver slurs:
///
/// - a phrase starts on the first attack inside a measure and closes on the
///   last attack before a barline, so every arc lands on the measure it
///   belongs to instead of drifting across one;
/// - it carries on into the next measure only when the next measure brings
///   music straight away: a rest of a beat or more between the bars, a bar
///   with nothing in it, or a leap wider than an octave closes the phrase;
/// - it never runs past two measures, and a phrase of fewer than three
///   attacks, or of one chord struck again and again, prints nothing — a
///   marking inferred from nothing is a marking the player did not make.
///
/// Consecutive phrases never share an event, so slurs never overlap.
public enum Phrasing {
    public struct Rules: Sendable, Equatable {
        /// Ticks in one measure of the framing.
        public let barTicks: Int
        /// Where measure zero begins; a pickup starts before zero.
        public let originTick: Int
        /// Silence at least this long is a breath. One beat by default.
        public let breathTicks: Int
        /// A leap at least this wide between two measures closes a phrase.
        public let leapSemitones: Int
        /// No phrase runs past this many measures.
        public let longestBars: Int
        /// Fewer attacks than this print no slur.
        public let minimumAttacks: Int

        public init(barTicks: Int, originTick: Int = 0, breathTicks: Int,
                    leapSemitones: Int = 12, longestBars: Int = 2,
                    minimumAttacks: Int = 3) {
            self.barTicks = max(1, barTicks)
            self.originTick = originTick
            self.breathTicks = max(1, breathTicks)
            self.leapSemitones = max(1, leapSemitones)
            self.longestBars = max(1, longestBars)
            self.minimumAttacks = max(2, minimumAttacks)
        }

        /// The rules a printed page is written by: a beat of silence is a
        /// breath, an octave is a leap, two measures are the ceiling.
        public init(signature: TimeSignature, originTick: Int = 0) {
            self.init(barTicks: signature.ticksPerMeasure, originTick: originTick,
                      breathTicks: signature.ticksPerBeat)
        }
    }

    /// The slurs the page should carry, in the order the events sound.
    ///
    /// Silences shorter than a breath are not breaks: a staccato chord inside
    /// a measure stays inside its phrase, which is how the marking reads.
    public static func spans(_ events: [PhraseEvent], rules: Rules) -> [PhraseSpan] {
        guard events.count >= rules.minimumAttacks else { return [] }
        // Attacks grouped by the measure they start in; the index kept with
        // each one is the index in the caller's stream.
        var perBar: [Int: [Int]] = [:]
        for (index, event) in events.enumerated() {
            perBar[barIndex(of: event, rules: rules), default: []].append(index)
        }
        let bars = perBar.keys.sorted()
        var spans: [PhraseSpan] = []
        var group: [Int] = []          // bar numbers in the open phrase
        var groupIndices: [Int] = []   // every event index in the open phrase

        func close() {
            defer { group = []; groupIndices = [] }
            guard let first = groupIndices.first, let last = groupIndices.last,
                  last > first, groupIndices.count >= rules.minimumAttacks else { return }
            let shapes = Set(groupIndices.map { events[$0].pitches.sorted() })
            guard shapes.count > 1 else { return }
            spans.append(PhraseSpan(first: first, last: last))
        }

        for bar in bars {
            let indices = perBar[bar] ?? []
            guard let firstOfBar = indices.first else { continue }
            if let previousBar = group.last, let previousLast = groupIndices.last {
                let gap = events[firstOfBar].onsetTick - events[previousLast].endTick
                let emptyBar = bar - previousBar > 1
                let breath = gap >= rules.breathTicks || emptyBar
                let leap = isLeap(from: events[previousLast], to: events[firstOfBar],
                                  by: rules.leapSemitones)
                let full = group.count >= rules.longestBars
                if breath || leap || full { close() }
            }
            group.append(bar)
            groupIndices.append(contentsOf: indices)
        }
        close()
        return spans
    }

    /// The measure an attack starts in. A pickup measure starts before zero,
    /// which is why the origin is subtracted before dividing.
    private static func barIndex(of event: PhraseEvent, rules: Rules) -> Int {
        Int(floor(Double(event.onsetTick - rules.originTick) / Double(rules.barTicks)))
    }

    /// Distance between two chords, measured from the nearest edge, so a
    /// chord held over a moving bass does not read as a leap.
    private static func isLeap(from: PhraseEvent, to: PhraseEvent, by width: Int) -> Bool {
        if to.lowest > from.highest { return to.lowest - from.highest >= width }
        if from.lowest > to.highest { return from.lowest - to.highest >= width }
        return false
    }

    /// The spans of one hand's stream, ready to mark tokens: the events are
    /// indexed, so a writer can ask "does a slur start here" without ticks.
    public static func marked(_ events: [PhraseEvent], rules: Rules)
        -> (starts: Set<Int>, ends: Set<Int>, spans: [PhraseSpan]) {
        let spans = spans(events, rules: rules)
        return (Set(spans.map(\.first)), Set(spans.map(\.last)), spans)
    }
}
