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
    public static func rests(start: Int, end: Int) -> [Symbol] {
        let gap = end - start
        guard gap > 0 else { return [] }
        let whole = 4 * ticksPerQuarter
        let q = ticksPerQuarter
        if gap >= 28 * whole / 32 { return [.rest(startTicks: start, kind: .whole)] }
        if gap >= 20 * whole / 32 {
            return [.rest(startTicks: start, kind: .half),
                    .rest(startTicks: start + 2 * q, kind: .quarter)]
        }
        if gap >= 14 * whole / 32 { return [.rest(startTicks: start, kind: .half)] }
        if gap >= 10 * whole / 32 {
            return [.rest(startTicks: start, kind: .quarter),
                    .rest(startTicks: start + q, kind: .eighth)]
        }
        if gap >= 7 * whole / 32 { return [.rest(startTicks: start, kind: .quarter)] }
        if gap >= 5 * whole / 32 {
            return [.rest(startTicks: start, kind: .eighth),
                    .rest(startTicks: start + q / 2, kind: .sixteenth)]
        }
        if gap >= 6 * whole / 64 { return [.rest(startTicks: start, kind: .eighth)] }
        return []
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
