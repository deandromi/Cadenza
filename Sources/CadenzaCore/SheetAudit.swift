import Foundation

/// What the sheet promises a player, checked on the finished draft.
///
/// The rhythm stage is only worth anything if its rules hold everywhere, so
/// they are stated once here and asserted in two places: the offline checks
/// run this audit on a waltz performance, and the `--sheet-rules` probe runs
/// it on a real file. The rules:
///
/// - every voice tiles every bar exactly: its symbols start at the barline,
///   meet without a gap or an overlap, and end at the next barline;
/// - a symbol prints exactly the room it owns — the head, dots and flags the
///   renderer draws are the value the engraver decided;
/// - no value contradicts the meter: every chord is a value this bar can hold
///   where it stands, so nothing hides a beat;
/// - a tie joins two pieces that both exist, carry that pitch and meet.
extension SheetDraft {
    public struct RhythmIssue: Sendable, Equatable, CustomStringConvertible {
        public let track: Int
        public let measure: Int
        public let voice: Int
        public let tick: Int
        public let message: String

        public var description: String {
            "track \(track) measure \(measure) voice \(voice) t\(tick): \(message)"
        }
    }

    /// Every rhythm rule the draft breaks; an empty list is a legal sheet.
    public static func rhythmAudit(_ result: Result) -> [RhythmIssue] {
        var issues: [RhythmIssue] = []
        let measureTicks = result.options.measureTicks
        let meter = Meter(result.options)

        for (track, symbols) in [result.topTrack, result.bottomTrack].enumerated() {
            // the barline that opens each measure, and the symbols inside it
            var measures: [(start: Int, items: [(voice: Int, start: Int, length: Int, symbol: Symbol)])] = []
            for symbol in symbols {
                switch symbol {
                case .bar(let tick):
                    measures.append((tick, []))
                case .finalBar:
                    if measures.isEmpty { measures.append((0, [])) }
                default:
                    guard !measures.isEmpty else { continue }
                    switch symbol {
                    case .chord(let chord):
                        measures[measures.count - 1].items.append(
                            (chord.voice, chord.startTicks, chord.endTicks - chord.startTicks, symbol))
                    case .rest(let tick, let kind):
                        measures[measures.count - 1].items.append(
                            (0, tick, Self.restLength(kind), symbol))
                    case .restVoiced(let tick, let kind, let voice):
                        measures[measures.count - 1].items.append(
                            (voice, tick, Self.restLength(kind), symbol))
                    default:
                        break
                    }
                }
            }

            for (number, measure) in measures.enumerated() {
                let barEnd = number + 1 < measures.count
                    ? measures[number + 1].start
                    : measure.start + measureTicks
                for voice in 0..<2 {
                    var columns = measure.items
                        .filter { $0.voice == voice }
                        .sorted { $0.start < $1.start }
                    // A whole rest alone in a bar stands for the bar itself, in
                    // any meter: that is the convention an empty bar is drawn
                    // by, and it is the one exception to "prints its room".
                    if columns.count == 1, case .rest(_, .whole) = columns[0].symbol {
                        columns[0].length = barEnd - columns[0].start
                    }
                    if columns.count == 1, case .restVoiced(_, .whole, _) = columns[0].symbol {
                        columns[0].length = barEnd - columns[0].start
                    }
                    guard !columns.isEmpty else { continue }
                    var cursor = measure.start
                    for column in columns {
                        if column.start != cursor {
                            issues.append(RhythmIssue(
                                track: track, measure: number + 1, voice: voice, tick: column.start,
                                message: column.start > cursor
                                    ? "\(cursor)..\(column.start) is empty"
                                    : "lands on \(cursor), which is already filled"))
                        }
                        cursor = max(cursor, column.start + column.length)
                    }
                    if cursor != barEnd {
                        issues.append(RhythmIssue(
                            track: track, measure: number + 1, voice: voice, tick: cursor,
                            message: "voice stops at \(cursor), the bar ends at \(barEnd)"))
                    }
                }

                // what is drawn is what was decided
                for item in measure.items {
                    guard case .chord(let chord) = item.symbol else { continue }
                    let value = noteValue(item.length)
                    let flags = chord.stems.map(\.flags).max() ?? 0
                    for note in chord.notes {
                        if note.head != value.head || note.dots != value.dots {
                            issues.append(RhythmIssue(
                                track: track, measure: number + 1, voice: item.voice,
                                tick: chord.startTicks,
                                message: "pitch \(note.pitch) prints \(note.head)/\(note.dots) dots in a \(item.length) tick room"))
                        }
                    }
                    if value.head != .whole, flags != value.flags {
                        issues.append(RhythmIssue(
                            track: track, measure: number + 1, voice: item.voice,
                            tick: chord.startTicks,
                            message: "stem carries \(flags) flags in a \(item.length) tick room"))
                    }
                    if chord.endTicks > barEnd {
                        issues.append(RhythmIssue(
                            track: track, measure: number + 1, voice: item.voice,
                            tick: chord.startTicks, message: "the head runs past the barline"))
                    }
                    // the value must be one the meter allows where it stands
                    let local = chord.startTicks - measure.start
                    if !meter.fits(item.length, at: local) {
                        issues.append(RhythmIssue(
                            track: track, measure: number + 1, voice: item.voice,
                            tick: chord.startTicks,
                            message: "a \(item.length) tick value hides a beat at +\(local)"))
                    }
                }
            }
        }

        // ties join real pieces that meet
        for tie in result.ties {
            let symbols = tie.track == 0 ? result.topTrack : result.bottomTrack
            func has(_ tick: Int) -> Bool {
                symbols.contains { symbol in
                    guard case .chord(let chord) = symbol, chord.startTicks == tick else { return false }
                    return chord.notes.contains { $0.pitch == tie.pitch }
                }
            }
            if !has(tie.fromTicks) {
                issues.append(RhythmIssue(track: tie.track, measure: tie.fromTicks / measureTicks + 1,
                                          voice: 0, tick: tie.fromTicks, message: "tie leaves a note that is not there"))
            }
            if !has(tie.toTicks) {
                issues.append(RhythmIssue(track: tie.track, measure: tie.toTicks / measureTicks + 1,
                                          voice: 0, tick: tie.toTicks, message: "tie arrives where that pitch is not written"))
            }
        }
        return issues
    }

    /// How long a rest symbol lasts.
    public static func restLength(_ kind: RestKind) -> Int {
        switch kind {
        case .whole: return 4 * ticksPerQuarter
        case .half: return 2 * ticksPerQuarter
        case .quarter: return ticksPerQuarter
        case .eighth: return ticksPerQuarter / 2
        case .sixteenth: return ticksPerQuarter / 4
        case .thirtysecond: return ticksPerQuarter / 8
        }
    }
}
