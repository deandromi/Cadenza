import Foundation

/// Beam groups under the classic beat rules, the pedals that ride between
/// them, and the beams themselves.
extension SheetDraft {
    // MARK: beams

    /// Merges pedal spans into a hand track as pedalDown/pedalUp marks,
    /// inserted in tick order: after a barline at the same tick, before
    /// anything else there, so a pedal press reads inside its measure. A
    /// span reaching past the final bar clamps to it — a pedal held to the
    /// end releases where the music ends.
    static func insertingPedals(_ spans: [PedalSpan], into symbols: [Symbol]) -> [Symbol] {
        let finalBarTick = symbols.last(where: {
            if case .finalBar = $0 { return true }
            return false
        })?.startTicks
        var marks: [(tick: Int, symbol: Symbol)] = []
        for span in spans where span.endTick > span.startTick {
            let end = finalBarTick.map { min(span.endTick, $0) } ?? span.endTick
            marks.append((span.startTick, .pedalDown(startTicks: span.startTick)))
            marks.append((end, .pedalUp(startTicks: end)))
        }
        marks.sort { $0.tick < $1.tick }
        var result: [Symbol] = []
        var index = 0
        for mark in marks {
            while index < symbols.count {
                let symbol = symbols[index]
                if symbol.startTicks < mark.tick {
                    result.append(symbol)
                    index += 1
                    continue
                }
                if symbol.startTicks == mark.tick {
                    if case .bar = symbol { result.append(symbol); index += 1; continue }
                    if case .finalBar = symbol { result.append(symbol); index += 1; continue }
                }
                break
            }
            result.append(mark.symbol)
        }
        result.append(contentsOf: symbols[index...])
        return result
    }

    /// The stem summary the beamer compares: head, dots, flags, whether
    /// the chord carries two stems, and its average staff position.
    struct StemSummary: Equatable {
        var head: Head
        var dots: Int
        var flags: Int
        var twoStems: Bool
        var positions: [Int]
    }

    static func stemSummary(of symbol: Symbol) -> StemSummary? {
        guard case .chord(let chord) = symbol else { return nil }
        guard let primary = chord.stems.first else { return nil }
        let note = chord.notes[primary.noteRange.lowerBound]
        var positions: [Int] = []
        for stem in chord.stems {
            if let first = chord.notes.indices.first(where: { stem.noteRange.contains($0) }) {
                positions.append(chord.notes[first].staffPosition)
            }
            if let last = chord.notes.indices.last(where: { stem.noteRange.contains($0) }) {
                positions.append(chord.notes[last].staffPosition)
            }
        }
        return StemSummary(head: note.head, dots: note.dots, flags: primary.flags,
                           twoStems: chord.stems.count > 1,
                           positions: positions)
    }

    /// The beam groups for one track, in the classic order: sixes (3/4 and
    /// 6/x eighths), triplet threes on the beat, threes in 12/8, fours in
    /// simple meters, pairs on the beat, pairs anywhere.
    public static func beamGroups(for symbols: [Symbol], options: Options) -> [(indices: [Int], up: Bool, flags: Int, dotted: Bool)] {
        let measure = options.measureTicks
        let quarter = ticksPerQuarter
        let chordIndexes = symbols.enumerated().compactMap { i, s -> Int? in
            guard case .chord(let chord) = s, !chord.stems.isEmpty else { return nil }
            if let primary = chord.stems.first, primary.beamGroupId != nil { return nil }
            return i
        }
        var taken = Set<Int>()
        var groups: [(indices: [Int], up: Bool, flags: Int, dotted: Bool)] = []

        func membersAreAdjacent(_ window: [Int]) -> Bool {
            for k in 1..<window.count {
                for s in symbols[(window[k - 1] + 1)..<window[k]] {
                    switch s {
                    case .chord, .blank: continue
                    default: return false
                    }
                }
                if symbols[window[k - 1]].startTicks / measure != symbols[window[k]].startTicks / measure {
                    return false
                }
                if window[k] == window[k - 1] { return false }
            }
            return true
        }

        func canBeam(_ window: [Int], mustStartOnBeat: Bool) -> Bool {
            guard window.count >= 2 else { return false }
            guard let base = stemSummary(of: symbols[window[0]]) else { return false }
            guard let tail = stemSummary(of: symbols[window[window.count - 1]]) else { return false }
            let dotted8to16 = window.count == 2 && base.dots == 1 && base.flags == 1
                && tail.dots == 0 && tail.flags == 2 && membersAreAdjacent([window[0], window[1]])
            if base.head == .whole || base.head == .half { return false }
            if base.flags == 0 { return false }
            if base.dots > 0 && !dotted8to16 { return false }
            if base.flags != tail.flags && !dotted8to16 { return false }
            let firstMeasure = symbols[window[0]].startTicks / measure
            for index in window {
                guard case .chord = symbols[index] else { return false }
                guard let summary = stemSummary(of: symbols[index]) else { return false }
                if taken.contains(index) { return false }
                if symbols[index].startTicks / measure != firstMeasure { return false }
                if summary.head == .whole || summary.head == .half { return false }
                if summary.flags != base.flags, !(dotted8to16 && index == window[window.count - 1]) { return false }
                if summary.dots > 0, !((index == window[0] && dotted8to16) || summary.dots == 0) { return false }
            }
            let firstStart = symbols[window[0]].startTicks
            let tolerance = quarter / 6
            switch window.count {
            case 6:
                guard base.flags == 1,
                      (options.numerator == 3 && options.denominator == 4)
                      || (options.numerator == 6 && options.denominator == 8)
                      || (options.numerator == 6 && options.denominator == 4) else { return false }
                if options.numerator == 6 && options.denominator == 4, firstStart % (quarter * 3) > tolerance {
                    return false
                }
            case 4:
                if options.numerator == 3 && options.denominator == 8 { return false }
                let simpleMeter = options.numerator == 2 || options.numerator == 4 || options.numerator == 8
                if !simpleMeter && base.flags != 2 { return false }
                let beat = base.flags == 1 ? quarter * 2 : quarter
                if firstStart % beat > tolerance { return false }
            case 3:
                let triplet = base.flags == 2 && base.dots == 0
                let twelveEight = base.flags == 1 && options.numerator == 12 && options.denominator == 8
                guard triplet || twelveEight else { return false }
                let beat = twelveEight ? quarter / 2 * 3 : quarter
                if firstStart % beat > tolerance { return false }
            default:
                if mustStartOnBeat, firstStart % quarter > tolerance { return false }
            }
            return true
        }

        func sweep(_ count: Int, onBeat: Bool) {
            var i = 0
            while i < chordIndexes.count {
                guard i + count <= chordIndexes.count else { break }
                let window = Array(chordIndexes[i..<(i + count)])
                if membersAreAdjacent(window), canBeam(window, mustStartOnBeat: onBeat) {
                    var up = true
                    var decided = false
                    for index in window {
                        if let summary = stemSummary(of: symbols[index]), summary.twoStems {
                            // A two-stem chord fixes the beam to its lower
                            // (down) stem.
                            up = false
                            decided = true
                            break
                        }
                    }
                    if !decided {
                        let positions = window.compactMap { stemSummary(of: symbols[$0])?.positions }.flatMap { $0 }
                        up = stemsUp(positions: positions)
                    }
                    for index in window { taken.insert(index) }
                    let base = stemSummary(of: symbols[window[0]])
                    let tail = stemSummary(of: symbols[window[window.count - 1]])
                    let flags = base?.flags ?? 1
                    let dotted = window.count == 2 && base?.dots == 1 && base?.flags == 1
                        && tail?.dots == 0 && tail?.flags == 2
                    groups.append((window, up, flags, dotted))
                    i += count
                } else {
                    i += 1
                }
            }
        }

        let sixMeter = (options.numerator == 3 && options.denominator == 4)
            || (options.numerator == 6 && options.denominator == 8)
            || (options.numerator == 6 && options.denominator == 4)
        if sixMeter { sweep(6, onBeat: true) }
        sweep(3, onBeat: true)
        sweep(4, onBeat: true)
        sweep(2, onBeat: true)
        sweep(2, onBeat: false)
        return groups
    }

    /// Apply beam groups: member chord stems in the beaming stem lose their
    /// flags and carry the group's global id. In two-stem chords the stem
    /// matching the group's direction beams; the other keeps its flags.
    public static func applyBeams(to symbols: inout [Symbol],
                                  groups: [(indices: [Int], up: Bool, flags: Int, dotted: Bool)],
                                  idOffset: Int) {
        for (groupId, group) in groups.enumerated() {
            for index in group.indices {
                guard case .chord(let chord) = symbols[index] else { continue }
                if chord.stems.isEmpty { continue }
                var stemIndex = 0
                if chord.stems.count > 1 {
                    // The lower stem points down, the upper up; match the beam.
                    stemIndex = group.up ? chord.stems.count - 1 : 0
                }
                symbols[index] = .chord(chord.retagging(
                    stemIndex: stemIndex, up: group.up, flags: 0, groupId: idOffset + groupId
                ))
            }
        }
    }
}
