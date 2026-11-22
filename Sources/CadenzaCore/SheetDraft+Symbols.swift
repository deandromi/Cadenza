import Foundation

/// Chord symbols over the staves, the position helpers (ledgers, stem
/// direction) and the rests that fill the gaps.
extension SheetDraft {
    // MARK: chord symbols

    /// Group a hand's notes into chords: one per shared start, with heads,
    /// dots, accidentals, staff positions, ledger lines and stems.
    public static func makeChords(from notes: [RunningNote], fifths: Int, clefs: [Clef], measureTicks: Int) -> [Chord] {
        var result: [Chord] = []
        var i = 0
        while i < notes.count {
            let start = notes[i].start
            var group: [RunningNote] = []
            while i < notes.count, notes[i].start == start {
                group.append(notes[i])
                i += 1
            }
            result.append(makeChord(group, fifths: fifths, clefs: clefs, measureTicks: measureTicks))
        }
        return result
    }

    private static func makeChord(_ group: [RunningNote], fifths: Int, clefs: [Clef], measureTicks: Int) -> Chord {
        let start = group[0].start
        let end = group.map { $0.start + $0.duration }.max() ?? start
        let clef = Self.clef(at: start, clefs: clefs, measureTicks: measureTicks)
        let values = group.map { noteValue($0.duration) }
        var notes: [NoteGlyph] = []
        for (note, value) in zip(group, values) {
            let position = clef.position(ofPitch: note.pitch)
            notes.append(NoteGlyph(
                pitch: note.pitch,
                staffPosition: position,
                head: value.head,
                dots: value.dots,
                accidental: accidental(pitchClass: note.pitch, fifths: fifths),
                ledgers: ledgers(forPosition: position)
            ))
        }
        var stems: [Stem] = []
        if let change = values.firstIndex(where: { $0 != values[0] }) {
            // Mixed durations: lower notes stem down, the tail stems up.
            if values[0].head != .whole {
                stems.append(Stem(noteRange: 0..<change, up: false, flags: values[0].flags, beamGroupId: nil))
            }
            if values[change].head != .whole {
                stems.append(Stem(noteRange: change..<group.count, up: true, flags: values[change].flags, beamGroupId: nil))
            }
        } else if values[0].head != .whole {
            stems.append(Stem(noteRange: 0..<group.count,
                             up: stemsUp(positions: notes.map(\.staffPosition)),
                             flags: values[0].flags,
                             beamGroupId: nil))
        }
        return Chord(startTicks: start, endTicks: end, notes: notes, stems: stems)
    }

    /// Ledger lines a staff position needs: even positions from -2 down to
    /// the note below the staff, 10 up to the note above, outermost first.
    public static func ledgers(forPosition position: Int) -> [Int] {
        var result: [Int] = []
        if position < 0 {
            var p = -2
            while p >= position { result.append(p); p -= 2 }
        } else if position > 8 {
            var p = 10
            while p <= position { result.append(p); p += 2 }
            result.reverse()
        }
        return result
    }

    /// The classic stem direction: the chord's average on or below the
    /// middle line stems up, above it stems down.
    public static func stemsUp(positions: [Int]) -> Bool {
        guard !positions.isEmpty else { return true }
        return positions.map { 4 - $0 }.reduce(0, +) >= 0
    }

    // MARK: rests

    /// The rest symbols that fill a gap, by the classic buckets: whole,
    /// half, quarter and eighth gaps take one rest; dotted gaps split into
    /// plain plus a shorter one (dotted half = half + quarter); gaps that
    /// bucket to sixteenth or smaller draw nothing.
    /// The rest a length draws, when that length is exactly a plain value.
    static func restKind(for length: Int) -> RestKind? {
        switch length {
        case ticksPerQuarter: return .quarter
        case ticksPerQuarter / 2: return .eighth
        case ticksPerQuarter / 4: return .sixteenth
        case ticksPerQuarter / 8: return .thirtysecond
        case 2 * ticksPerQuarter: return .half
        case 4 * ticksPerQuarter: return .whole
        default: return nil
        }
    }

    /// Fills a stretch of time with rests that add up to it exactly. Rests
    /// respect the beat where they can — a hole that opens mid-beat is filled
    /// to the next beat first, so a bar reads as beats instead of a stutter —
    /// but a rest never runs past the gap it fills: the old thresholds handed
    /// a 600-tick hole a quarter plus an eighth, which is 720 and landed on
    /// the next column.
    public static func rests(start: Int, end: Int) -> [Symbol] {
        var result: [Symbol] = []
        var cursor = start
        var left = end - start
        let rungs: [(length: Int, kind: RestKind)] = [
            (4 * ticksPerQuarter, .whole),
            (2 * ticksPerQuarter, .half),
            (ticksPerQuarter, .quarter),
            (ticksPerQuarter / 2, .eighth),
            (ticksPerQuarter / 4, .sixteenth),
            (ticksPerQuarter / 8, .thirtysecond),
        ]
        while left > 0 {
            let toBeat = ticksPerQuarter - (cursor % ticksPerQuarter)
            if toBeat < ticksPerQuarter, toBeat <= left, let kind = restKind(for: toBeat) {
                result.append(.rest(startTicks: cursor, kind: kind))
                cursor += toBeat
                left -= toBeat
                continue
            }
            guard let rung = rungs.first(where: { $0.length <= left }) else {
                // less than a thirty-second left: nothing a musician would draw
                break
            }
            result.append(.rest(startTicks: cursor, kind: rung.kind))
            cursor += rung.length
            left -= rung.length
        }
        return result
    }

    // MARK: symbol list

    /// A hand's symbol list: bars at the measure grid, chords in order,
    /// rests in gaps (clipped at bars), and clef changes just before the
    /// measure that flips. The closing final bar ends the piece.
    public static func symbols(from chords: [Chord], clefs: [Clef], options: Options, lastStart: Int) -> [Symbol] {
        var result: [Symbol] = []
        let measureTicks = options.measureTicks
        var measureTime = 0
        var chordIndex = 0
        var previousEnd = 0
        var previousClef = Self.clef(at: 0, clefs: clefs, measureTicks: measureTicks)
        while chordIndex < chords.count {
            let chord = chords[chordIndex]
            if measureTime <= chord.startTicks {
                let clefHere = Self.clef(at: measureTime, clefs: clefs, measureTicks: measureTicks)
                if clefHere != previousClef {
                    result.append(.clefChange(clefHere, startTicks: measureTime))
                }
                previousClef = clefHere
                result.append(contentsOf: rests(start: previousEnd, end: measureTime))
                result.append(.bar(startTicks: measureTime))
                previousEnd = max(previousEnd, measureTime)
                measureTime += measureTicks
            } else {
                result.append(contentsOf: rests(start: previousEnd, end: chord.startTicks))
                result.append(.chord(chord))
                previousEnd = max(previousEnd, chord.endTicks)
                previousClef = Self.clef(at: chord.startTicks, clefs: clefs, measureTicks: measureTicks)
                chordIndex += 1
            }
        }
        while measureTime <= lastStart {
            result.append(.bar(startTicks: measureTime))
            measureTime += measureTicks
        }
        result.append(.finalBar(startTicks: measureTime))
        return result
    }
}
