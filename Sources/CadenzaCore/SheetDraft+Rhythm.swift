import Foundation

/// Quantization: seconds to ticks at the drafted tempo, chords collapsed onto
/// one onset, durations rounded onto the readable grid.
extension SheetDraft {
    // MARK: quantization

    /// Ticks for a time in seconds at the given tempo.
    public static func ticks(seconds: Double, options: Options) -> Int {
        Int((seconds * Double(ticksPerQuarter) * options.bpm / 60).rounded())
    }

    /// Ticks for a duration in milliseconds at the given tempo.
    public static func ticks(ms: Double, options: Options) -> Int {
        Int((Double(ticksPerQuarter) * options.bpm * ms / 60_000).rounded())
    }

    /// Chordify: onsets within the combine interval collapse onto the
    /// chain's earliest start. Chains extend greedily, like the classic
    /// fold, so a strummed chord still reads as one chord.
    public static func chordify(_ notes: [RunningNote], options: Options) -> [RunningNote] {
        var result = notes.sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) }
        let interval = ticks(ms: options.combineMillis, options: options)
        guard interval > 0, !result.isEmpty else { return result }
        var i = 0
        while i < result.count {
            let anchor = result[i].start
            while i + 1 < result.count, result[i + 1].start - anchor <= interval {
                result[i + 1].start = anchor
                i += 1
            }
            i += 1
        }
        return result
    }

    /// Round durations: each note stretches to just before the next onset,
    /// capped by the largest quarter-grid divisor that fits; the last chord
    /// keeps its sounded duration, and run pairs (adjacent equal onsets)
    /// stay intact so beams can form.
    public static func roundDurations(_ notes: [RunningNote]) -> [RunningNote] {
        var result = notes
        let quarter = ticksPerQuarter
        var previousNote: RunningNote?
        for i in 0..<result.count {
            guard i + 1 < result.count else { break }
            let note = result[i]
            var nextStart = result[i + 1].start
            var j = i + 1
            while j < result.count, result[j].start == note.start {
                nextStart = j + 1 < result.count ? result[j + 1].start : result[j].start
                j += 1
            }
            let maximum = nextStart > note.start ? nextStart - note.start : 0
            var dur = 0
            if quarter <= maximum { dur = quarter }
            else if quarter / 2 <= maximum { dur = quarter / 2 }
            else if quarter / 3 <= maximum { dur = quarter / 3 }
            else if quarter / 4 <= maximum { dur = quarter / 4 }
            if dur < note.duration { dur = note.duration }
            if let previous = previousNote,
               previous.start + previous.duration == note.start,
               previous.duration == note.duration {
                dur = note.duration
            }
            result[i].duration = dur
            if result[i + 1].start != note.start {
                previousNote = result[i]
            }
        }
        return result
    }
}
