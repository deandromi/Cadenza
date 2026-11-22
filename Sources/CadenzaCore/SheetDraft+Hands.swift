import Foundation

/// The single stream split into two hands by register, and the clef each
/// measure asks for.
extension SheetDraft {
    // MARK: hand split

    /// Split the quantized stream into two hand tracks. For each note, the
    /// cascade picks the hand:
    /// - more than an octave from the exact-start extremes: nearer hand;
    /// - else more than an octave from the overlapping extremes: nearer;
    /// - else the exact-start extremes span an octave: nearer extreme;
    /// - else the overlapping extremes span an octave: nearer;
    /// - else follow the last octave-spanning extremes.
    public static func splitHands(_ notes: [RunningNote], measureTicks: Int) -> (top: [RunningNote], bottom: [RunningNote]) {
        var top: [RunningNote] = []
        var bottom: [RunningNote] = []
        guard !notes.isEmpty else { return ([], []) }
        var previousHigh = 76
        var previousLow = 45
        var startIndex = 0
        for note in notes {
            while startIndex < notes.count,
                   notes[startIndex].start + notes[startIndex].duration < note.start {
                startIndex += 1
            }
            let overlapping = extremesOverlap(notes, from: startIndex,
                                               measureTicks: measureTicks, note: note)
            let exact = extremesExact(notes, from: startIndex,
                                      start: note.start, fallback: note.pitch)
            let pitch = note.pitch
            if exact.high - pitch > 12 || pitch - exact.low > 12 {
                if exact.high - pitch <= pitch - exact.low { top.append(note) } else { bottom.append(note) }
            } else if overlapping.high - pitch > 12 || pitch - overlapping.low > 12 {
                if overlapping.high - pitch <= pitch - overlapping.low { top.append(note) } else { bottom.append(note) }
            } else if exact.high - exact.low > 12 {
                if exact.high - pitch <= pitch - exact.low { top.append(note) } else { bottom.append(note) }
            } else if overlapping.high - overlapping.low > 12 {
                if overlapping.high - pitch <= pitch - overlapping.low { top.append(note) } else { bottom.append(note) }
            } else {
                if previousHigh - pitch <= pitch - previousLow { top.append(note) } else { bottom.append(note) }
            }
            if overlapping.high - overlapping.low > 12 {
                previousHigh = overlapping.high
                previousLow = overlapping.low
            }
        }
        return (top, bottom)
    }

    /// The highest and lowest pitch overlapping the note's lifetime, with
    /// the window cut one measure past the note's start.
    static func extremesOverlap(_ notes: [RunningNote], from startIndex: Int,
                                measureTicks: Int, note: RunningNote) -> (high: Int, low: Int) {
        var high = note.pitch
        var low = note.pitch
        let end = min(note.start + note.duration, note.start + measureTicks)
        var i = startIndex
        while i < notes.count, notes[i].start < end {
            let other = notes[i]
            if other.start + other.duration >= note.start, note.start - other.start < measureTicks {
                high = max(high, other.pitch)
                low = min(low, other.pitch)
            }
            i += 1
        }
        return (high, low)
    }

    /// The highest and lowest pitch starting exactly at the given time.
    static func extremesExact(_ notes: [RunningNote], from startIndex: Int,
                              start: Int, fallback: Int) -> (high: Int, low: Int) {
        var i = startIndex
        while i < notes.count, notes[i].start < start { i += 1 }
        var high = fallback
        var low = fallback
        while i < notes.count, notes[i].start == start {
            high = max(high, notes[i].pitch)
            low = min(low, notes[i].pitch)
            i += 1
        }
        return (high, low)
    }

    // MARK: clefs per measure

    /// The clef each measure draws: F4 and above heads treble, G3 and below
    /// heads bass, the in-between keeps the track's dominant clef, and an
    /// empty measure keeps the previous clef.
    public static func measureClefs(notes: [RunningNote], measureTicks: Int) -> [Clef] {
        let average = notes.isEmpty ? 60 : notes.map(\.pitch).reduce(0, +) / notes.count
        let main: Clef = average >= 60 ? .treble : .bass
        var result: [Clef] = []
        var clef = main
        var nextMeasure = measureTicks
        var index = 0
        while index < notes.count {
            var sum = 0
            var count = 0
            while index < notes.count, notes[index].start < nextMeasure {
                sum += notes[index].pitch
                count += 1
                index += 1
            }
            if count > 0 {
                let average = sum / count
                if average >= 65 { clef = .treble }
                else if average <= 55 { clef = .bass }
                else { clef = main }
            }
            result.append(clef)
            nextMeasure += measureTicks
        }
        if result.isEmpty { result.append(main) }
        return result
    }

    /// The clef active at a tick from a measure-clef list.
    public static func clef(at start: Int, clefs: [Clef], measureTicks: Int) -> Clef {
        guard !clefs.isEmpty else { return .treble }
        return clefs[max(0, min(start / measureTicks, clefs.count - 1))]
    }

    /// One struck chord, divided between the staves.
    ///
    /// A chord is one grip. Slicing it note by note at middle C prints half of
    /// an ordinary C major triad on each staff and hangs the rest on ledger
    /// lines, which is what makes a transcription look invented. So the unit
    /// here is the whole grip: it goes to the staff its own centre asks for,
    /// and only a grip that clearly spans two hands — a bass note under a
    /// melody note, a tenth or more apart with a real gap between them — is
    /// divided, and then at the gap the hands left.
    ///
    /// The indices come back, not the pitches: a chord may strike one pitch
    /// twice and each note still goes its own way.
    public static func divideGrip(_ pitches: [Int]) -> (top: [Int], bottom: [Int]) {
        guard !pitches.isEmpty else { return ([], []) }
        let order = pitches.indices.sorted { pitches[$0] < pitches[$1] }
        let sorted = order.map { pitches[$0] }
        if sorted.count > 1, let low = sorted.first, let high = sorted.last,
           high - low >= 19, let gap = widestGap(in: sorted), gap.span >= 7 {
            return (Array(order[gap.at...]), Array(order[..<gap.at]))
        }
        // The middle line is the line: a grip whose centre sits at or above
        // middle C is the right hand's, the way a pianist reads it.
        let mean = Double(sorted.reduce(0, +)) / Double(sorted.count)
        return mean >= 60 ? (Array(pitches.indices), []) : ([], Array(pitches.indices))
    }

    /// The widest jump between neighbouring pitches, and where it sits.
    private static func widestGap(in sorted: [Int]) -> (at: Int, span: Int)? {
        var best: (at: Int, span: Int)?
        for index in 1..<sorted.count {
            let span = sorted[index] - sorted[index - 1]
            if span > (best?.span ?? 0) { best = (index, span) }
        }
        return best
    }
}
