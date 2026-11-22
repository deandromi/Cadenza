import Foundation

/// Quantization: seconds to ticks at the drafted tempo, and the grid a take's
/// attacks are written on.
extension SheetDraft {
    // MARK: seconds to ticks

    /// Ticks for a time in seconds at the given tempo.
    public static func ticks(seconds: Double, options: Options) -> Int {
        Int((seconds * Double(ticksPerQuarter) * options.bpm / 60).rounded())
    }

    /// Ticks for a duration in milliseconds at the given tempo.
    public static func ticks(ms: Double, options: Options) -> Int {
        Int((Double(ticksPerQuarter) * options.bpm * ms / 60_000).rounded())
    }

    // MARK: the grid

    /// The grid a performance's attacks are written on.
    ///
    /// MuseScore's MIDI import quantizes onsets to an eighth by default and to
    /// a sixteenth at the finest, because a grid finer than a sixteenth writes
    /// the player's hand as music. The same limit applies here, and which of
    /// the two grids a take gets is decided from the take itself: a file's
    /// ticks are its notation, so if fewer than one attack in fifty sits off
    /// the eighth grid, the sixteenths are jitter and the eighth grid is the
    /// notation. A performance's seconds drift with the tempo, so a take
    /// without a tempo map keeps the sixteenth grid and only nudges an attack
    /// onto the eighth when it is already most of the way there.
    public struct Quantizer: Sendable, Equatable {
        /// The grid step in ticks: 240 (an eighth) or 120 (a sixteenth).
        public let grid: Int
        /// True when the grid was chosen from a file's own ticks.
        public let metrical: Bool

        public init(onsets: [Int], options: Options, metrical: Bool) {
            let quarter = ticksPerQuarter
            let eighth = quarter / 2
            let sixteenth = quarter / 4
            var grid = sixteenth
            if metrical, !onsets.isEmpty {
                let tolerance = eighth / 8
                let onEighth = onsets.filter { tick in
                    let residual = tick % eighth
                    return min(residual, eighth - residual) <= tolerance
                }.count
                if Double(onEighth) >= 0.98 * Double(onsets.count) {
                    grid = eighth
                }
            }
            self.grid = grid
            self.metrical = metrical
        }

        /// An onset on the grid.
        public func quantize(_ tick: Int) -> Int {
            let snapped = ((tick + grid / 2) / grid) * grid
            guard !metrical else { return snapped }
            // a performance: an attack already inside an eighth's tolerance of
            // the pulse belongs to the pulse, the way the hand heard it
            let pulse = ticksPerQuarter / 2
            let nearest = ((snapped + pulse / 2) / pulse) * pulse
            return abs(nearest - snapped) <= ticksPerQuarter / 8 ? nearest : snapped
        }
    }
}
