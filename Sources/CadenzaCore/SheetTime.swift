import Foundation

/// An imported file's own clock.
///
/// A MIDI file does not store notation in seconds: it stores ticks, and a
/// tempo map that turns those ticks into playing time. Reading it as seconds
/// and back at one nominal tempo throws the notation away wherever the
/// performance speeds up or slows down — the bars then drift off the page and
/// every value comes out wrong. MuseScore imports ticks, and so does this
/// sheet: this type is what makes the ticks available again, scaled onto the
/// engraver's 480-per-quarter grid.
extension SheetDraft {
    public struct TimeMap: Sendable, Equatable {
        public struct Segment: Sendable, Equatable {
            /// First source tick of the segment.
            public let tick: Int
            /// Seconds from the start of the file at that tick.
            public let seconds: Double
            /// Seconds one source tick lasts inside the segment.
            public let secondsPerTick: Double
        }

        /// The file's own ticks per quarter note.
        public let ticksPerQuarter: Int
        /// Tempo segments, ascending by tick; the first one starts at tick 0.
        public let segments: [Segment]

        public init(ticksPerQuarter: Int, tempoChanges: [(tick: Int, bpm: Double)]) {
            let ppq = max(1, ticksPerQuarter)
            self.ticksPerQuarter = ppq
            let changes = tempoChanges
                .filter { $0.bpm > 0 }
                .sorted { $0.tick < $1.tick }
            var segments: [Segment] = []
            var seconds = 0.0
            // A file that declares no tempo plays at the MIDI default, 120.
            var lastTick = 0
            var lastBpm = 120.0
            for change in changes {
                let tick = max(lastTick, change.tick)
                seconds += Double(tick - lastTick) * (60.0 / lastBpm) / Double(ppq)
                if let current = segments.last, current.tick == tick {
                    // two tempos on one tick: the later one wins, the segment
                    // start is already right
                    segments[segments.count - 1] = Segment(tick: tick, seconds: current.seconds,
                                                           secondsPerTick: 60.0 / change.bpm / Double(ppq))
                } else {
                    segments.append(Segment(tick: tick, seconds: seconds,
                                            secondsPerTick: 60.0 / change.bpm / Double(ppq)))
                }
                lastTick = tick
                lastBpm = change.bpm
            }
            if segments.isEmpty {
                segments = [Segment(tick: 0, seconds: 0, secondsPerTick: 60.0 / 120.0 / Double(ppq))]
            } else if segments[0].tick > 0 {
                seconds = Double(segments[0].tick) * (60.0 / 120.0) / Double(ppq)
                segments.insert(Segment(tick: 0, seconds: 0,
                                        secondsPerTick: 60.0 / 120.0 / Double(ppq)), at: 0)
            }
            self.segments = segments
        }

        /// Seconds from the start of the file at a source tick.
        public func seconds(at tick: Int) -> Double {
            let segment = segment(at: tick)
            return segment.seconds + Double(tick - segment.tick) * segment.secondsPerTick
        }

        /// The source tick at a number of seconds from the start.
        public func tick(at seconds: Double) -> Int {
            var chosen = segments[0]
            for segment in segments where segment.seconds <= seconds { chosen = segment }
            let ticks = Double(chosen.tick) + (seconds - chosen.seconds) / chosen.secondsPerTick
            return Int(ticks.rounded())
        }

        /// The tick on the engraver's own grid: 480 per quarter, whatever the
        /// file used.
        public func engraverTick(seconds: Double) -> Int {
            let scaled = Double(tick(at: seconds)) * Double(SheetDraft.ticksPerQuarter) / Double(ticksPerQuarter)
            return Int(scaled.rounded())
        }

        private func segment(at tick: Int) -> Segment {
            var chosen = segments[0]
            for segment in segments where segment.tick <= tick { chosen = segment }
            return chosen
        }
    }
}

extension MidiFile {
    /// The notation clock of the file, ready for `SheetDraft.draft`.
    public var sheetTimeMap: SheetDraft.TimeMap {
        SheetDraft.TimeMap(ticksPerQuarter: ticksPerQuarter, tempoChanges: tempoChanges)
    }
}
