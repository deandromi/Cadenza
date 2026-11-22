import Foundation

/// The metrical skeleton of a bar: where the beats fall, and which written
/// values may stand where.
///
/// Notation software never prints a value that hides a beat. A note that runs
/// from the first beat of 3/4 to the middle of the second is a quarter tied to
/// an eighth, not a dotted quarter; a note that fills a whole bar of 3/4 is a
/// dotted half, not three tied quarters. This type holds that judgement in one
/// place — for notes and rests alike — so the engraver never grows a second,
/// different set of splitting rules somewhere else.
///
/// The rule, in one sentence: a length is written as one symbol when it is
/// aligned to its own value, or when it starts on a beat and lasts at most two
/// beats (the point past which every engraving manual asks for a tie).
extension SheetDraft {
    public struct Meter: Sendable, Equatable {
        public let numerator: Int
        public let denominator: Int

        public init(numerator: Int, denominator: Int) {
            precondition(numerator > 0, "a meter needs beats")
            precondition([1, 2, 4, 8, 16, 32].contains(denominator),
                         "denominator must be a note value")
            self.numerator = numerator
            self.denominator = denominator
        }

        public init(_ options: Options) {
            self.init(numerator: options.numerator, denominator: options.denominator)
        }

        /// One bar in ticks; the same number `Options.measureTicks` gives.
        public var measureTicks: Int {
            4 * ticksPerQuarter / denominator * numerator
        }

        /// True for the meters that are felt in dotted beats: 6/8, 9/8, 12/8.
        public var isCompound: Bool {
            denominator == 8 && numerator % 3 == 0 && numerator > 3
        }

        /// The beat the meter is *felt* in, in ticks: the denominator's value,
        /// except in compound meters, where a beat is a dotted quarter.
        public var beatTicks: Int {
            isCompound ? 3 * ticksPerQuarter / 2 : 4 * ticksPerQuarter / denominator
        }

        /// Beats in a bar, rounded up so an unusual meter still covers the bar.
        public var beatCount: Int {
            max(1, (measureTicks + beatTicks - 1) / beatTicks)
        }

        /// The values one symbol may carry, longest first, in ticks. The ladder
        /// is the classic one: whole, dotted half, half, dotted quarter,
        /// quarter, dotted eighth, eighth, dotted sixteenth, sixteenth,
        /// thirty-second. `dotted` is false for rests, which carry no dot in
        /// this house style: a dotted gap is filled with plain rests.
        public func values(dotted: Bool = true) -> [Int] {
            let quarter = ticksPerQuarter
            var result = [4 * quarter, 2 * quarter, quarter,
                          quarter / 2, quarter / 4, quarter / 8]
            if dotted {
                result += [3 * quarter, 3 * quarter / 2, 3 * quarter / 4, 3 * quarter / 8]
            }
            return result.sorted(by: >)
        }

        /// The longest value that may stand for `length` ticks starting at
        /// `start` (a position inside the bar), or nil when the span has to be
        /// tied. This is the whole rule in one predicate.
        public func value(at start: Int, length: Int, dotted: Bool = true) -> Int? {
            guard length > 0 else { return nil }
            for value in values(dotted: dotted) where value <= length && fits(value, at: start) {
                return value
            }
            return nil
        }

        /// A value may stand where it is aligned to its own length; on a beat
        /// it may also take up the whole beat, or cover up to two whole beats
        /// (a half note on beat two of 3/4 is written, a dotted quarter from
        /// the same beat is not: it would swallow beat three).
        ///
        /// A note too short to hide a beat — an eighth or anything smaller —
        /// may also stand anywhere the player put it. That is what syncopation
        /// looks like on paper: a pair of eighths written a sixteenth off the
        /// beat is two eighths, not a sixteenth tied to a dotted sixteenth.
        /// Refusing them is how a transcription grows a tie on every note and
        /// reads as a page of scratches.
        func fits(_ value: Int, at start: Int) -> Bool {
            if start % value == 0 { return true }
            if 2 * value <= beatTicks { return true }
            guard start % beatTicks == 0 else { return false }
            if value <= beatTicks { return true }
            return value % beatTicks == 0 && value <= 2 * beatTicks
        }

        /// How a span of time is actually written: one symbol when the rules
        /// allow it, tied pieces when a beat is in the way. The span is cut at
        /// the barline, so the caller can tie the pieces on either side.
        public func split(start: Int, length: Int, dotted: Bool = true) -> [(start: Int, length: Int)] {
            pieces(start: start, length: length, dotted: dotted) { value, at in
                self.fits(value, at: at)
            }
        }

        /// The same split for silence. A rest is the one thing that may never
        /// stand off its own position: a quarter rest a sixteenth late reads
        /// as a hole before it, which is the beat it was meant to fill.
        private func pieces(start: Int, length: Int, dotted: Bool,
                            fits stand: (Int, Int) -> Bool) -> [(start: Int, length: Int)] {
            var result: [(start: Int, length: Int)] = []
            guard length > 0 else { return result }
            let bar = measureTicks
            let local = ((start % bar) + bar) % bar
            var cursor = local
            var left = min(length, bar - local)
            let ladder = values(dotted: dotted)
            let smallest = ladder.last ?? 1
            while left > 0 {
                let chosen = ladder.first { $0 <= left && stand($0, cursor) } ?? min(smallest, left)
                result.append((start: cursor, length: chosen))
                cursor += chosen
                left -= chosen
            }
            return result
        }

        /// The stricter rule, for rests: aligned to its own length, or on a
        /// beat taking up whole beats.
        private func fitsOnBeat(_ value: Int, at start: Int) -> Bool {
            if start % value == 0 { return true }
            guard start % beatTicks == 0 else { return false }
            if value <= beatTicks { return true }
            return value % beatTicks == 0 && value <= 2 * beatTicks
        }

        /// The rests that fill a gap, beat by beat. A rest never carries a dot
        /// and never crosses a barline: the caller fills inside one bar.
        public func rests(start: Int, end: Int) -> [(start: Int, length: Int)] {
            pieces(start: start, length: end - start, dotted: false) { value, at in
                self.fitsOnBeat(value, at: at)
            }
        }

        /// The rest symbol for a length this meter handed out.
        public func restKind(_ length: Int) -> RestKind? {
            switch length {
            case 4 * ticksPerQuarter: return .whole
            case 2 * ticksPerQuarter: return .half
            case ticksPerQuarter: return .quarter
            case ticksPerQuarter / 2: return .eighth
            case ticksPerQuarter / 4: return .sixteenth
            case ticksPerQuarter / 8: return .thirtysecond
            default: return nil
            }
        }
    }
}
