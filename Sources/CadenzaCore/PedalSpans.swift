import Foundation

/// The sustain pedal as a score reads it.
///
/// A file records the pedal as a stream of controller changes, and a player
/// who re-presses the pedal while the strings still ring writes a release and
/// a press a few milliseconds apart. Musically that is one pedal, held. This
/// is the one place that decides where one pedal ends and the next begins, so
/// the sheet prints one "Ped." per pedal rather than a thicket of them.
public enum PedalSpans {
    /// A release and a press closer together than this are the same pedal.
    public static let touchingGap: Double = 0.05

    /// Merge spans that overlap or touch. The result is sorted by start and
    /// every span is at least as long as the ones it swallowed.
    public static func merged(_ spans: [(start: Double, end: Double)],
                              gap: Double = touchingGap) -> [(start: Double, end: Double)] {
        let ordered = spans.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var merged: [(start: Double, end: Double)] = []
        for span in ordered {
            if let last = merged.last, span.start <= last.end + gap {
                merged[merged.count - 1].end = max(last.end, span.end)
            } else {
                merged.append(span)
            }
        }
        return merged
    }
}
