import Foundation

/// The engraving pass: chooses the framing a performance needs — tempo,
/// key, meter — on evidence from the note events themselves, then quantizes
/// the performance onto the tick grid and cuts it into measures. Every
/// decision is deterministic and testable from recorded notes alone, with
/// no audio stack, exactly as the roadmap demands.
public enum Engraver {

    /// Inference works on onset groups, never on raw note events: chords
    /// struck together are one strike. Notes that arrive without grouping
    /// (onsetGroup still 0 everywhere, the fresh-mint default) get grouped
    /// here by the shared standard tolerance; notes that carry grouping
    /// from the live pipeline are respected as they are.
    private static func groupedForInference(_ notes: [NoteEvent]) -> [NoteEvent] {
        if !notes.isEmpty, notes.allSatisfy({ $0.onsetGroup == 0 }) {
            return assignOnsetGroups(notes)
        }
        return notes
    }

    // MARK: tempo

    /// Average tempo in quarter notes per minute, from inter-onset
    /// intervals of the grouped onsets. The dominant interval cluster wins
    /// — arpeggios contribute their half and dotted variants, but repeated
    /// beats outnumber them — then the winner is folded into a musical
    /// range so an eighth-note run does not report double tempo.
    public static func inferTempo(_ notes: [NoteEvent]) -> Double {
        let onsets = strokeOnsetTimes(notes)
        guard onsets.count >= 3 else { return 120 }

        // inter-onset intervals, ignoring pause gaps: silence carries no
        // pulse information
        let gaps: [Double] = zip(onsets, onsets.dropFirst())
            .map { $1 - $0 }
            .filter { $0 >= 0.1 && $0 <= 2.0 }
        guard !gaps.isEmpty else { return 120 }

        // the cluster that the most intervals sit within 20 ms of its
        // center is the beat
        var bestCount = 0
        var bestInterval = gaps[0]
        for center in gaps {
            let count = gaps.filter { abs($0 - center) < 0.02 }.count
            if count > bestCount {
                bestCount = count
                bestInterval = center
            }
        }

        // a beat shorter than a 240 BPM sixteenth is really a subdivision
        var beat = bestInterval
        while beat < 0.25 { beat *= 2 }
        while beat > 1.5 { beat /= 2 }
        return min(220, max(40, 60.0 / beat))
    }

    // MARK: key

    /// Krumhansl-Schmuckler: correlate the duration-weighted pitch-class
    /// profile against the major and minor key profiles. The best
    /// correlation wins; a confident C major run reads C major whatever
    /// the first chord was.
    public static func inferKey(_ notes: [NoteEvent]) -> KeySignature {
        let majorProfile: [Double] = [
            6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88,
        ]
        let minorProfile: [Double] = [
            6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17,
        ]

        var histogram = Array(repeating: 0.0, count: 12)
        for note in notes {
            histogram[note.pitchClass] += note.duration + 0.01
        }

        var bestTonic = 0
        var bestMinor = false
        var bestScore = -2.0
        for tonic in 0..<12 {
            let rotated = (0..<12).map { histogram[($0 + tonic) % 12] }
            let major = correlation(rotated, majorProfile)
            let minor = correlation(rotated, minorProfile)
            if major > bestScore {
                bestScore = major
                bestTonic = tonic
                bestMinor = false
            }
            if minor > bestScore {
                bestScore = minor
                bestTonic = tonic
                bestMinor = true
            }
        }
        return KeySignature(tonic: bestTonic, isMinor: bestMinor)
    }

    private static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let count = a.count
        let meanA = a.reduce(0, +) / Double(count)
        let meanB = b.reduce(0, +) / Double(count)
        var numerator = 0.0
        var aa = 0.0
        var bb = 0.0
        for i in 0..<count {
            let da = a[i] - meanA
            let db = b[i] - meanB
            numerator += da * db
            aa += da * da
            bb += db * db
        }
        guard aa > 0, bb > 0 else { return 0 }
        return numerator / (aa.squareRoot() * bb.squareRoot())
    }

    // MARK: meter

    /// The candidates the engraver weighs, with priors: common meters win
    /// ties, compound ones carry honest weight for their repertoire.
    private static let meterCandidates: [(signature: TimeSignature, prior: Double)] = [
        (TimeSignature(beatsPerMeasure: 4, beatUnit: 4), 1.00),
        (TimeSignature(beatsPerMeasure: 3, beatUnit: 4), 0.97),
        (TimeSignature(beatsPerMeasure: 2, beatUnit: 4), 0.94),
        (TimeSignature(beatsPerMeasure: 6, beatUnit: 8), 0.93),
    ]

    /// Inferred time signature. Each candidate's grid is scored by how much
    /// better it explains the stroke placement than chance on its own
    /// grid would, and by whether the loud strokes land on its downbeats —
    /// short meters cannot win by calling every second stroke a downbeat,
    /// and unaccented material leans on the grid alone. Few strokes fall
    /// back to 4/4.
    public static func inferTimeSignature(_ notes: [NoteEvent], tempo: Double) -> TimeSignature {
        let strikes = strikesForMeter(notes, tempo: tempo)
        guard strikes.count >= 4 else {
            return TimeSignature(beatsPerMeasure: 4, beatUnit: 4)
        }
        let snap = scoreTicksPerQuarter / 4
        let velocitySum = Double(strikes.map(\.velocity).reduce(0, +))
        let averageVelocity = velocitySum / Double(strikes.count)

        var best: TimeSignature?
        var bestScore = -1.0
        for candidate in meterCandidates {
            let measureTicks = candidate.signature.ticksPerMeasure
            let beatTicks = candidate.signature.ticksPerBeat
            let positionCount = measureTicks / snap
            guard positionCount > 0 else { continue }

            func positionWeight(_ position: Int, velocity: Double) -> Double {
                let accent = 0.5 + velocity / 254.0
                if position == 0 {
                    return accent
                } else if position % beatTicks == 0 {
                    return 0.55 * accent
                } else if position % snap == 0 {
                    return 0.25 * accent
                } else {
                    return 0.05 * accent
                }
            }

            // baseline: how the same grid would score chance placement
            var baseline = 0.0
            for position in stride(from: 0, to: measureTicks, by: snap) {
                baseline += positionWeight(position, velocity: averageVelocity)
            }
            baseline /= Double(positionCount)

            var candidateBest = -1.0
            var phase = 0
            while phase < measureTicks {
                var observed = 0.0
                var downbeatVelocities: [Double] = []
                var otherVelocities: [Double] = []
                for strike in strikes {
                    let position = ((strike.tick - phase) % measureTicks + measureTicks) % measureTicks
                    observed += positionWeight(position, velocity: Double(strike.velocity))
                    if position == 0 {
                        downbeatVelocities.append(Double(strike.velocity))
                    } else {
                        otherVelocities.append(Double(strike.velocity))
                    }
                }
                let observedMean = observed / Double(strikes.count)
                let gridLift = baseline > 0 ? observedMean / baseline : 0

                // how much louder the candidate's downbeats are than the
                // rest; too few hits to say reads as no evidence
                var accentLift = 1.0
                if downbeatVelocities.count >= 3, !otherVelocities.isEmpty {
                    let downbeatMean = downbeatVelocities.reduce(0, +) / Double(downbeatVelocities.count)
                    let otherMean = otherVelocities.reduce(0, +) / Double(otherVelocities.count)
                    if otherMean > 0 {
                        accentLift = downbeatMean / otherMean
                    }
                }

                let total = gridLift * accentLift * candidate.prior
                candidateBest = max(candidateBest, total)
                phase += snap
            }
            if candidateBest > bestScore {
                bestScore = candidateBest
                best = candidate.signature
            }
        }
        return best ?? TimeSignature(beatsPerMeasure: 4, beatUnit: 4)
    }

    /// Onset strikes with velocity, on the tick grid at the given tempo:
    /// the raw material meter and measure cutting share.
    private static func strikesForMeter(_ notes: [NoteEvent], tempo: Double) -> [(tick: Int, velocity: Int)] {
        let quarterSeconds = 60.0 / tempo
        guard quarterSeconds > 0 else { return [] }
        let grouped = groupedForInference(notes)
        let strikes = Dictionary(grouping: grouped, by: { $0.onsetGroup }).values.compactMap { group -> (tick: Int, velocity: Int)? in
            guard let first = group.min(by: { $0.onset < $1.onset }) else { return nil }
            let velocity = group.map(\.velocity).max() ?? first.velocity
            return (tick: Int((first.onset / quarterSeconds * Double(scoreTicksPerQuarter)).rounded()), velocity: velocity)
        }
        return strikes.sorted { $0.tick < $1.tick }
    }

    // MARK: engraving

    /// Note values a duration may take, sixteenth to breve, in ticks.
    private static let writableDurations: [Int] = [
        120, 180, 240, 360, 480, 720, 960, 1440, 1920, 2880, 3840,
    ]

    /// Engraves a performance into a score with all framing applied.
    /// Chords arrive as (seconds, symbol) pairs from the app's chord sheet.
    /// Returns nil when there is nothing to engrave.
    public static func engrave(
        notes: [NoteEvent],
        chords: [(seconds: Double, symbol: String)] = []
    ) -> Score? {
        // the engraver owns its grouping: inference reads onset groups, so
        // a raw note list from any source becomes grouped first
        let grouped = groupedForInference(notes)
        guard let first = grouped.map(\.onset).min() else { return nil }

        let tempo = inferTempo(grouped)
        let key = inferKey(grouped)
        let timeSignature = inferTimeSignature(grouped, tempo: tempo)
        let quarterSeconds = 60.0 / tempo

        // raw ticks relative to the first note, snapped to the sixteenth
        // grid: quantization tolerance is one thirty-second, beyond that
        // the onset rounds to its nearest sixteenth anyway
        let snap = scoreTicksPerQuarter / 4
        func tick(_ seconds: Double) -> Int {
            let raw = (seconds - first) / quarterSeconds * Double(scoreTicksPerQuarter)
            return Int((raw / Double(snap)).rounded()) * snap
        }
        func durationTicks(_ note: NoteEvent) -> Int {
            let raw = (note.offset - note.onset) / quarterSeconds * Double(scoreTicksPerQuarter)
            var bestTicks = snap
            var bestGap = Double.greatestFiniteMagnitude
            for candidate in Self.writableDurations {
                let gap = abs(Double(candidate) - raw)
                if gap < bestGap {
                    bestGap = gap
                    bestTicks = candidate
                }
            }
            return bestTicks
        }

        // pitch, onset and duration first: a repeated pitch releases before
        // it is restruck, so each duration clamps to the next onset of the
        // same pitch, before it becomes an immutable score note
        var pending: [(pitch: Int, onset: Int, duration: Int, velocity: Int)] = grouped
            .map { note in
                (pitch: note.pitch, onset: tick(note.onset),
                 duration: max(snap, durationTicks(note)), velocity: note.velocity)
            }
            .sorted { ($0.onset, $0.pitch) < ($1.onset, $1.pitch) }

        var byPitchStart: [Int: [Int]] = [:]
        for (index, note) in pending.enumerated() {
            byPitchStart[note.pitch, default: []].append(index)
        }
        for (_, indices) in byPitchStart {
            for i in 0..<(indices.count - 1) {
                let current = indices[i]
                let next = indices[i + 1]
                let room = pending[next].onset - pending[current].onset
                if room < pending[current].duration {
                    pending[current].duration = max(snap, room)
                }
            }
        }

        let scored = pending.map {
            ScoreNote(pitch: $0.pitch, onsetTick: $0.onset, durationTicks: $0.duration, velocity: $0.velocity)
        }

        // align measure one's downbeat with the strongest beat phase, then
        // everything after phase zero is measure space; notes before the
        // first downbeat are a pickup inside measure zero
        var phase = bestPhase(grouped, timeSignature: timeSignature, tempo: tempo)
        phase = max(0, min(phase, timeSignature.ticksPerMeasure - snap))
        let measureTicks = timeSignature.ticksPerMeasure
        if scored.contains(where: { $0.onsetTick < phase }) {
            phase -= measureTicks
        }

        func adjusted(_ t: Int) -> Int { t - phase }

        var noteGroups: [Int: [ScoreNote]] = [:]
        for note in scored {
            let measure = adjusted(note.onsetTick) / measureTicks
            noteGroups[measure, default: []].append(ScoreNote(
                pitch: note.pitch,
                onsetTick: note.onsetTick,
                durationTicks: note.durationTicks,
                velocity: note.velocity
            ))
        }

        let measures = noteGroups.keys.sorted().map { index in
            ScoreMeasure(
                index: index,
                startTick: index * measureTicks + phase,
                notes: noteGroups[index]!.sorted { ($0.onsetTick, $0.pitch) < ($1.onsetTick, $1.pitch) }
            )
        }
        let chordSymbols = chords
            .sorted { $0.0 < $1.0 }
            .map { ScoreChordSymbol(onsetTick: tick($0.0), symbol: $0.1) }

        return Score(
            framing: ScoreFraming(
                beatsPerMinute: tempo,
                timeSignature: timeSignature,
                key: key
            ),
            measures: measures,
            chords: chordSymbols
        )
    }

    /// The phase offset, in ticks, of the downbeat the onsets vote for.
    private static func bestPhase(
        _ notes: [NoteEvent],
        timeSignature: TimeSignature,
        tempo: Double
    ) -> Int {
        let strikes = strikesForMeter(notes, tempo: tempo)
        let measureTicks = timeSignature.ticksPerMeasure
        guard !strikes.isEmpty, measureTicks > 0 else { return 0 }
        var bestPhase = 0
        var bestScore = -1.0
        var phase = 0
        let step = scoreTicksPerQuarter / 4
        while phase < measureTicks {
            var weightSum = 0.0
            for strike in strikes {
                let position = ((strike.tick - phase) % measureTicks + measureTicks) % measureTicks
                weightSum += position == 0 ? 1.0 : 0.0
            }
            if weightSum > bestScore {
                bestScore = weightSum
                bestPhase = phase
            }
            phase += step
        }
        return bestPhase
    }

    /// Unique stroke onset times in seconds, one per onset group, sorted;
    /// chords struck together count once.
    private static func strokeOnsetTimes(_ notes: [NoteEvent]) -> [Double] {
        groupedForInference(notes)
            .reduce(into: [Int: Double]()) { map, note in
                map[note.onsetGroup] = min(map[note.onsetGroup] ?? .infinity, note.onset)
            }
            .values
            .sorted()
    }
}
