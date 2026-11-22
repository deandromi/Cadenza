import AppKit
import CadenzaCore
import Foundation

extension SmokeMain {
    /// The rule audit. "Looks like music" is not a check; a score either obeys
    /// the rules of notation or it does not. This walks the engraved draft and
    /// counts every violation it can prove: note values longer than their slot,
    /// rests that do not fill their gap, beams across a beat or a rest, stems
    /// pointing the wrong way, ties without a partner, accidentals printed
    /// twice, ledger lines that do not belong, and staves that disagree on a
    /// column's x. Run with `--sheet-rules <midi>`.
    @MainActor
    static func runSheetRules(path: String) {
        guard let file = try? MidiReader.read(url: URL(fileURLWithPath: path)) else {
            print("rules: cannot read \(path)")
            return
        }
        let meter = file.timeSignatures.first?.signature
        let options = SheetDraft.Options(bpm: file.initialTempo > 0 ? file.initialTempo : 120,
                                         numerator: meter?.beatsPerMeasure ?? 4,
                                         denominator: meter?.beatUnit ?? 4)
        let result = SheetDraft.draft(notes: file.heldNotes, options: options,
                                      pageWidth: SheetEngraver.pageWidth,
                                      originTicks: 0)
        let measureTicks = max(1, options.measureTicks)
        let quarter = SheetDraft.ticksPerQuarter

        enum Rule: String, CaseIterable {
            case slotOverrun = "note value longer than its slot"
            case underrun = "gap between columns never filled"
            case restFill = "rest does not fill its gap"
            case beamAcrossBar = "beam crosses a barline"
            case beamAcrossBeat = "beam crosses a beat"
            case beamOverRest = "beam jumps a rest"
            case beamFlags = "beam over mixed note values"
            case stemMissing = "noteheads without a stem"
            case stemDirection = "stem points the wrong way"
            case stemFlags = "flags disagree with the printed value"
            case tiePartner = "tie without a partner"
            case tiePitch = "tie to a pitch that is not there"
            case tieRepeat = "tie printed twice"
            case accidentalRepeat = "accidental printed twice in one bar"
            case accidentalNeedless = "accidental the key already spells"
            case ledger = "wrong ledger lines"
            case staffMisaligned = "the two staves disagree on a column"
            case offPaper = "symbol outside its row"
        }

        var report: [Rule: (count: Int, examples: [String])] = [:]
        func flag(_ rule: Rule, _ example: @autoclosure () -> String) {
            var entry = report[rule] ?? (0, [])
            entry.count += 1
            if entry.examples.count < 3 { entry.examples.append(example()) }
            report[rule] = entry
        }

        /// The length a printed value actually lasts.
        func printedTicks(head: SheetDraft.Head, dots: Int, flags: Int) -> Int {
            var value: Int
            switch head {
            case .whole: value = 4 * quarter
            case .half: value = 2 * quarter
            case .filled: value = quarter
            }
            for _ in 0..<flags { value /= 2 }
            if dots > 0 { value += value / 2 }
            return value
        }

        func restTicks(_ kind: SheetDraft.RestKind) -> Int {
            switch kind {
            case .whole: return 4 * quarter
            case .half: return 2 * quarter
            case .quarter: return quarter
            case .eighth: return quarter / 2
            case .sixteenth: return quarter / 4
            case .thirtysecond: return quarter / 8
            }
        }

        // One hand, measure by measure: the barline opens each measure.
        struct Measure {
            let start: Int
            let items: [(index: Int, symbol: SheetDraft.Symbol)]
        }
        func split(_ symbols: [SheetDraft.Symbol]) -> [Measure] {
            var measures: [Measure] = []
            var start = 0
            var items: [(Int, SheetDraft.Symbol)] = []
            for (index, symbol) in symbols.enumerated() {
                switch symbol {
                case .bar(let tick):
                    // a barline opens the measure that follows it
                    if !items.isEmpty || !measures.isEmpty {
                        measures.append(Measure(start: start, items: items))
                    }
                    start = tick
                    items = []
                case .finalBar:
                    measures.append(Measure(start: start, items: items))
                    items = []
                default:
                    items.append((index, symbol))
                }
            }
            return measures
        }

        for (track, symbols) in [result.topTrack, result.bottomTrack].enumerated() {
            let measures = split(symbols)
            var shown = Set<String>()
            for (number, measure) in measures.enumerated() {
                // the last measure of a performance can stop mid-bar
                let isLast = number == measures.count - 1
                let barEnd = isLast
                    ? min(measure.start + measureTicks,
                          measures.last.map { $0.start + measureTicks } ?? measure.start + measureTicks)
                    : measure.start + measureTicks
                shown.removeAll()
                // A bar with two voices carries two timelines; each fills its
                // own silences, so the single-timeline tiling check below only
                // applies to a monophonic bar.
                let polyphonic = measure.items.contains { item in
                    if case .restVoiced = item.symbol { return true }
                    return false
                }
                // the column timeline of this bar, in order
                var columns: [(start: Int, end: Int, label: String)] = []
                for (index, symbol) in measure.items {
                    switch symbol {
                    case .chord(let chord):
                        let value = chord.notes.map { note -> Int in
                            var ticks = quarter
                            switch note.head {
                            case .whole: ticks = 4 * quarter
                            case .half: ticks = 2 * quarter
                            case .filled: ticks = quarter
                            }
                            return ticks
                        }
                        let printed = chord.notes.map {
                            printedTicks(head: $0.head, dots: $0.dots, flags: chord.stems.map(\.flags).max() ?? 0)
                        }.max() ?? 0
                        let slot = chord.endTicks - chord.startTicks
                        if printed > slot {
                            flag(.slotOverrun, "t\(track) m\(number + 1) t\(chord.startTicks) printed \(printed) slot \(slot)")
                        }
                        _ = value
                        if chord.endTicks > barEnd {
                            flag(.slotOverrun, "t\(track) m\(number + 1) chord ends past the bar")
                        }
                        columns.append((chord.startTicks, chord.endTicks, "chord"))
                        // stems
                        let positions = chord.notes.map(\.staffPosition)
                        let allWhole = chord.notes.allSatisfy { $0.head == .whole }
                        if allWhole {
                            if !chord.stems.isEmpty {
                                flag(.stemFlags, "t\(track) m\(number + 1) whole chord carries a stem")
                            }
                        } else if chord.stems.isEmpty {
                            flag(.stemMissing, "t\(track) m\(number + 1) t\(chord.startTicks)")
                        } else {
                            let wantUp = Double(positions.reduce(0, +)) / Double(max(1, positions.count)) < 4
                            for stem in chord.stems {
                                if !polyphonic, stem.up != wantUp {
                                    flag(.stemDirection, "t\(track) m\(number + 1) t\(chord.startTicks) up=\(stem.up)")
                                }
                                // a note that lasts a beat or longer never
                                // wears a flag: only eighths and shorter do
                                if slot >= quarter, stem.flags > 0 {
                                    flag(.stemFlags, "t\(track) m\(number + 1) t\(chord.startTicks) \(slot) ticks with \(stem.flags) flags")
                                }
                            }
                        }
                        // accidentals and ledgers
                        for note in chord.notes {
                            let expected = SheetDraft.accidental(pitchClass: ((note.pitch % 12) + 12) % 12,
                                                                 fifths: result.fifths)
                            let key = "\(note.staffPosition)"
                            if note.accidental == .none, expected != .none, !shown.contains(key) {
                                // no glyph and the key does not spell it
                                flag(.accidentalNeedless, "t\(track) m\(number + 1) t\(note.pitch) unmarked")
                            }
                            if note.accidental != .none {
                                if shown.contains(key) {
                                    flag(.accidentalRepeat, "t\(track) m\(number + 1) pos \(key)")
                                }
                                shown.insert(key)
                                if expected == .none {
                                    flag(.accidentalNeedless, "t\(track) m\(number + 1) t\(note.pitch)")
                                }
                            }
                            if note.ledgers != SheetDraft.ledgers(forPosition: note.staffPosition) {
                                flag(.ledger, "t\(track) m\(number + 1) pos \(note.staffPosition)")
                            }
                        }
                        _ = index
                    case .rest(let tick, let kind), .restVoiced(let tick, let kind, _):
                        let length = restTicks(kind)
                        columns.append((tick, tick + length, "rest \(kind)"))
                    default:
                        break
                    }
                }
                if ProcessInfo.processInfo.environment["SHEET_DUMP"] == "\(number + 1)", track == 0 {
                    for column in columns { print("dump m\(number + 1) \(column.start)..\(column.end) \(column.label)") }
                }

                // the bar must be filled end to end, in order, without overlap
                var cursor = measure.start
                if polyphonic { continue }
                _ = ()
                var previous = "barline"
                for column in columns.sorted(by: { $0.start < $1.start }) {
                    if column.start > cursor {
                        flag(.underrun, "t\(track) m\(number + 1) \(cursor)..\(column.start) is empty")
                        flag(.restFill, "t\(track) m\(number + 1) gap \(cursor)..\(column.start) has no rest")
                    }
                    if column.start < cursor {
                        flag(.restFill, "t\(track) m\(number + 1) \(column.label) at \(column.start) lands on \(previous) ending \(cursor)")
                    }
                    cursor = max(cursor, column.end)
                    previous = "\(column.label) \\(column.start)"
                }
                if cursor < barEnd {
                    flag(.underrun, "t\(track) m\(number + 1) \(cursor)..\(barEnd) is empty")
                }
            }
        }

        // Beams have to live inside one beat of one bar, with nothing between.
        for group in result.beamGroups {
            let symbols = group.track == 0 ? result.topTrack : result.bottomTrack
            guard group.chordIndices.count >= 2 else {
                flag(.beamAcrossBeat, "a beam of \(group.chordIndices.count)")
                continue
            }
            var starts: [Int] = []
            for index in group.chordIndices {
                guard index < symbols.count, case .chord(let chord) = symbols[index] else { continue }
                starts.append(chord.startTicks)
            }
            guard starts.count == group.chordIndices.count else { continue }
            if Set(starts.map { $0 / measureTicks }).count > 1 {
                flag(.beamAcrossBar, "beam \(group.id) at t\(starts[0])")
            }
            if options.numerator <= 4 {
                let beat = quarter * max(1, 4 / options.denominator)
                if Set(starts.map { $0 / beat }).count > 1 {
                    flag(.beamAcrossBeat, "beam \(group.id) at t\(starts[0])")
                }
            }
            let first = group.chordIndices.min() ?? 0
            let last = group.chordIndices.max() ?? 0
            if last > first {
                for index in (first + 1)..<last where index < symbols.count {
                    if case .rest = symbols[index] {
                        flag(.beamOverRest, "beam \(group.id) at t\(starts[0])")
                    }
                }
            }
            var flags = Set<Int>()
            for index in group.chordIndices where index < symbols.count {
                if case .chord(let chord) = symbols[index] {
                    for stem in chord.stems { flags.insert(stem.flags) }
                    if chord.stems.contains(where: { $0.beamGroupId != group.id }) {
                        flag(.beamFlags, "beam \(group.id) member has another group")
                    }
                }
            }
            if flags.count > 1 {
                flag(.beamFlags, "beam \(group.id) mixes \(flags.sorted())")
            }
        }

        // Ties: same pitch on both ends, from the last column of a bar to the
        // first of the next, and never twice for one pitch.
        for tie in result.ties {
            let symbols = tie.track == 0 ? result.topTrack : result.bottomTrack
            func chord(at tick: Int) -> SheetDraft.Chord? {
                for symbol in symbols {
                    if case .chord(let chord) = symbol, chord.startTicks == tick { return chord }
                }
                return nil
            }
            guard let from = chord(at: tie.fromTicks) else {
                flag(.tiePartner, "tie t\(tie.fromTicks) has no note")
                continue
            }
            guard let to = chord(at: tie.toTicks) else {
                flag(.tiePartner, "tie to t\(tie.toTicks) has no note")
                continue
            }
            if !from.notes.contains(where: { $0.pitch == tie.pitch }) {
                flag(.tiePitch, "tie t\(tie.fromTicks) pitch \(tie.pitch)")
            }
            if !to.notes.contains(where: { $0.pitch == tie.pitch }) {
                flag(.tiePitch, "tie t\(tie.toTicks) pitch \(tie.pitch)")
            }
            if tie.fromTicks / measureTicks + 1 != tie.toTicks / measureTicks {
                flag(.tiePartner, "tie t\(tie.fromTicks)..t\(tie.toTicks) skips a bar")
            }
        }
        var seenTies = Set<String>()
        for tie in result.ties {
            let key = "\(tie.track)-\(tie.pitch)-\(tie.fromTicks)"
            if !seenTies.insert(key).inserted {
                flag(.tieRepeat, "tie t\(tie.fromTicks) pitch \(tie.pitch)")
            }
        }

        // Both staves must place a shared column on the same x, and no symbol
        // may hang outside its row.
        for (number, row) in result.rows.enumerated() {
            var topX: [Int: Double] = [:]
            var bottomX: [Int: Double] = [:]
            for placed in row.top {
                if case .chord(let chord) = placed.symbol { topX[chord.startTicks] = placed.x }
                if placed.x > row.width + 0.01 || placed.x < 0 {
                    flag(.offPaper, "row \(number + 1) top x \(placed.x)")
                }
            }
            for placed in row.bottom {
                if case .chord(let chord) = placed.symbol { bottomX[chord.startTicks] = placed.x }
                if placed.x > row.width + 0.01 || placed.x < 0 {
                    flag(.offPaper, "row \(number + 1) bottom x \(placed.x)")
                }
            }
            for (tick, x) in topX {
                if let other = bottomX[tick], abs(other - x) > 0.01 {
                    flag(.staffMisaligned, "row \(number + 1) t\(tick) top \(x) bottom \(other)")
                }
            }
        }

        var total = 0
        for rule in Rule.allCases {
            guard let entry = report[rule] else { continue }
            total += entry.count
            print("rules: \(entry.count)× \(rule.rawValue)")
            for example in entry.examples { print("        \(example)") }
        }
        if total == 0 {
            print("rules: clean — \(result.rows.count) systems, \(result.ties.count) ties, \(result.beamGroups.count) beams")
        } else {
            print("rules: \(total) violations over \(result.rows.count) systems")
        }
    }
}
