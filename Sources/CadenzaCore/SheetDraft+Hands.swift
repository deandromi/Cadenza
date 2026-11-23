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
    /// A chord is one grip, so the staff is decided for the grip and not note
    /// by note. The old rule read every note's distance to *both* staves and
    /// split at the widest gap with no readable side — which put a bass note
    /// of G2 on the treble staff, six ledger lines under it, because the note
    /// above it happened to sit an octave higher. That is the ink that makes a
    /// transcription look invented: a hand's chord torn in two and the low
    /// half hung off the wrong staff.
    ///
    /// Two rules decide it, and they are the ones an edition follows:
    ///
    /// 1. A grip inside an octave is one hand's shape. It prints whole, on the
    ///    staff its centre asks for (middle C is the hinge), the way a right
    ///    hand's chord with its thumb below the treble staff is still the right
    ///    hand's.
    /// 2. A wider grip is both hands. It divides at middle C: everything from
    ///    C4 up is the upper staff, everything below is the lower one.
    ///
    /// The indices come back, not the pitches: a chord may strike one pitch
    /// twice and each note still goes its own way.
    public static func divideGrip(_ pitches: [Int]) -> (top: [Int], bottom: [Int]) {
        guard !pitches.isEmpty else { return ([], []) }
        let order = pitches.indices.sorted { pitches[$0] < pitches[$1] }
        let sorted = order.map { pitches[$0] }
        guard let low = sorted.first, let high = sorted.last else { return ([], []) }
        // 1. one hand's shape: the staff its centre asks for
        if high - low <= 12 {
            let mean = Double(sorted.reduce(0, +)) / Double(sorted.count)
            return mean >= Double(middleC) ? (Array(pitches.indices), [])
                                           : ([], Array(pitches.indices))
        }
        // 2. both hands: the seam is middle C, never a gap picked by shape
        if let first = sorted.firstIndex(where: { $0 >= middleC }) {
            return (Array(order[first...]), Array(order[..<first]))
        }
        return ([], Array(pitches.indices))
    }

    /// The pitch the staves are divided at: middle C.
    public static let middleC = 60

    /// The widest jump between neighbouring pitches, and where it sits.
    static func widestGap(in sorted: [Int]) -> (at: Int, span: Int)? {
        var best: (at: Int, span: Int)?
        for index in 1..<sorted.count {
            let span = sorted[index] - sorted[index - 1]
            if best == nil || span > best!.span { best = (index, span) }
        }
        return best
    }

}
