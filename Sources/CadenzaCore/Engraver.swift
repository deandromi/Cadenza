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

    /// Distinct inter-onset clusters of the grouped onsets, each with the
    /// combined velocity of the gaps that fall into it: (period seconds,
    /// weight). Busy passages make subdivision intervals outnumber beat
    /// intervals, so weight, not count, carries the evidence.
    private static func onsetClusters(_ notes: [NoteEvent]) -> [(period: Double, weight: Double)] {
        let grouped = groupedForInference(notes)
        let strikes = grouped
            .reduce(into: [Int: (onset: Double, velocity: Int)]()) { map, note in
                let current = map[note.onsetGroup]
                map[note.onsetGroup] = (
                    onset: min(current?.onset ?? .infinity, note.onset),
                    velocity: max(current?.velocity ?? 0, note.velocity)
                )
            }
            .values
            .sorted { $0.onset < $1.onset }
        guard strikes.count >= 3 else { return [(0.5, 1)] }

        // inter-onset intervals with the louder strike's velocity as
        // weight; pause gaps carry no pulse information
        var gaps: [(interval: Double, weight: Double)] = []
        for pair in zip(strikes, strikes.dropFirst()) {
            let interval = pair.1.onset - pair.0.onset
            if interval >= 0.1 && interval <= 2.0 {
                gaps.append((interval, Double(max(pair.0.velocity, pair.1.velocity))))
            }
        }

        var clusters: [(period: Double, weight: Double)] = []
        for gap in gaps {
            let tolerance = max(0.02, 0.03 * gap.interval)
            if let index = clusters.firstIndex(where: { abs($0.period - gap.interval) < tolerance }) {
                clusters[index].weight += gap.weight
            } else {
                clusters.append((gap.interval, gap.weight))
            }
        }
        return clusters
    }

    /// Candidate tempi in bpm: the onset clusters clamped into a musical
    /// range, ascending. Subdivision and bar-level octaves survive on
    /// purpose so the choices step can offer them.
    public static func tempoCandidates(_ notes: [NoteEvent]) -> [Double] {
        let candidates = onsetClusters(notes)
            .map { min(240, max(40, 60.0 / $0.period)) }
        let unique = Array(NSCountedSet(array: candidates.map { Int($0.rounded()) }).allObjects.compactMap { ($0 as? NSNumber)?.intValue })
            .map { Double($0) }
            .sorted()
        return unique.isEmpty ? [120] : unique
    }

    /// Average tempo in quarter notes per minute: the heaviest onset
    /// cluster whose tempo sits in the range where a tap-along beat lives
    /// (50-190 bpm). Faster clusters are subdivisions of the beat, slower
    /// ones are the bar; if nothing lands in range the heaviest cluster
    /// overall wins, clamped. Ties go to the slower period, because the
    /// beat is what the foot taps, not the hand.
    public static func inferTempo(_ notes: [NoteEvent]) -> Double {
        let clusters = onsetClusters(notes)
        guard !clusters.isEmpty else { return 120 }
        let inRange = clusters.filter {
            let bpm = 60.0 / $0.period
            return bpm >= 50 && bpm <= 190
        }
        let pool = inRange.isEmpty ? clusters : inRange
        let best = pool.max { a, b in
            if a.weight != b.weight { return a.weight < b.weight }
            return a.period < b.period
        }!
        return min(240, max(40, 60.0 / best.period))
    }

    // MARK: key

    /// Krumhansl-Schmuckler: correlate the duration-weighted pitch-class
    /// profile against the major and minor key profiles, with two musical
    /// corrections on top. Out-of-scale sounding time penalizes a key —
    /// a lot of F natural is evidence against G major, whatever the tonic
    /// mass says. And the first and last onset groups add a cadence bias
    /// toward their own pitch classes, so a piece that ends on C reads
    /// C major even when the harmony spent the middle on G7.
    public static func inferKey(_ notes: [NoteEvent]) -> KeySignature {
        scoreKeyCandidates(notes).first ?? KeySignature(tonic: 0, isMinor: false)
    }

    /// Every key with its evidence score, best first: the alternatives the
    /// app's choices step offers next to the inferred one.
    public static func scoreKeyCandidates(_ notes: [NoteEvent]) -> [KeySignature] {
        let majorProfile: [Double] = [
            6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88,
        ]
        let minorProfile: [Double] = [
            6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17,
        ]
        let majorScale = [0, 2, 4, 5, 7, 9, 11]
        let minorScale = [0, 2, 3, 5, 7, 8, 10]

        var histogram = Array(repeating: 0.0, count: 12)
        for note in notes {
            histogram[note.pitchClass] += note.duration + 0.01
        }
        let total = histogram.reduce(0, +)

        // cadence evidence: pitch classes of the first and last onset group
        let grouped = groupedForInference(notes)
        let byGroup = Dictionary(grouping: grouped, by: { $0.onsetGroup }).values
        var struck: [(onset: Double, classes: Set<Int>)] = []
        for group in byGroup {
            let onset = group.map(\.onset).min() ?? 0
            let classes = Set(group.map(\.pitchClass))
            struck.append((onset, classes))
        }
        struck.sort { $0.onset < $1.onset }
        let firstGroup = struck.first?.classes
        let lastGroup = struck.last?.classes

        var ranked: [(key: KeySignature, score: Double)] = []
        for tonic in 0..<12 {
            var bias = 1.0
            if let firstGroup, firstGroup.contains(tonic) { bias *= 1.05 }
            if let lastGroup, lastGroup.contains(tonic) { bias *= 1.15 }
            func scalePenalty(_ steps: [Int]) -> Double {
                var outOfScale = 0.0
                for pc in 0..<12 where !steps.contains((pc - tonic + 12) % 12) {
                    outOfScale += histogram[pc]
                }
                return total > 0 ? exp(-1.5 * outOfScale / total) : 1.0
            }
            let rotated = (0..<12).map { histogram[($0 + tonic) % 12] }
            let major = correlation(rotated, majorProfile) * bias * scalePenalty(majorScale)
            let minor = correlation(rotated, minorProfile) * bias * scalePenalty(minorScale)
            ranked.append((KeySignature(tonic: tonic, isMinor: false), major))
            ranked.append((KeySignature(tonic: tonic, isMinor: true), minor))
        }
        return ranked
            .sorted { $0.score > $1.score }
            .map(\.key)
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
        let scored = scoreMeterCandidates(notes, tempo: tempo)
        return scored.max { $0.score < $1.score }?.signature
            ?? TimeSignature(beatsPerMeasure: 4, beatUnit: 4)
    }

    /// Set true to print per-candidate grid and accent evidence while
    /// scoring meters (used by the midiscore diagnostic).
    nonisolated(unsafe) public static var meterDebug = false

    /// Every candidate meter with its score (grid lift times accent lift
    /// times prior), best first. The app's choices step can show these as
    /// the alternatives the user may override.
    public static func scoreMeterCandidates(
        _ notes: [NoteEvent],
        tempo: Double
    ) -> [(signature: TimeSignature, score: Double)] {
        let strikes = strikesForMeter(notes, tempo: tempo)
        guard strikes.count >= 4 else {
            return meterCandidates.map { ($0.signature, 0) }
        }
        let snap = scoreTicksPerQuarter / 4
        let velocitySum = Double(strikes.map(\.velocity).reduce(0, +))
        let averageVelocity = velocitySum / Double(strikes.count)

        var scored: [(signature: TimeSignature, score: Double)] = []
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
                var beatVelocities: [Double] = []
                var otherVelocities: [Double] = []
                for strike in strikes {
                    let position = ((strike.tick - phase) % measureTicks + measureTicks) % measureTicks
                    observed += positionWeight(position, velocity: Double(strike.velocity))
                    if position == 0 {
                        downbeatVelocities.append(Double(strike.velocity))
                    } else if position % beatTicks == 0 {
                        beatVelocities.append(Double(strike.velocity))
                    } else {
                        otherVelocities.append(Double(strike.velocity))
                    }
                }
                let observedMean = observed / Double(strikes.count)
                let gridLift = baseline > 0 ? observedMean / baseline : 0

                // metrical hierarchy: the downbeat should be louder than
                // the other beats of its own meter; too few hits to say
                // reads as no evidence
                var accentLift = 1.0
                if downbeatVelocities.count >= 3 {
                    let downbeatMean = downbeatVelocities.reduce(0, +) / Double(downbeatVelocities.count)
                    let comparison: [Double] = !beatVelocities.isEmpty ? beatVelocities : otherVelocities
                    if !comparison.isEmpty {
                        let comparisonMean = comparison.reduce(0, +) / Double(comparison.count)
                        if comparisonMean > 0 {
                            accentLift = downbeatMean / comparisonMean
                        }
                    }
                }

                let total = gridLift * accentLift * candidate.prior
                if Self.meterDebug, total > candidateBest {
                    print(String(format: "  meter %d/%d phase %d: grid %.3f accent %.3f total %.3f",
                                 candidate.signature.beatsPerMeasure, candidate.signature.beatUnit,
                                 phase, gridLift, accentLift, total))
                }
                candidateBest = max(candidateBest, total)
                phase += snap
            }
            scored.append((candidate.signature, candidateBest))
        }
        return scored.sorted { $0.score > $1.score }
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
        engraveApplying(notes: notes, chords: chords, framing: nil)
    }

    /// The same engraving with the framing the user chose in the choices
    /// step instead of the inferred one: only the framing differs, the
    /// quantization and measure cutting run identically.
    public static func engrave(
        notes: [NoteEvent],
        chords: [(seconds: Double, symbol: String)] = [],
        framing chosen: ScoreFraming
    ) -> Score? {
        engraveApplying(notes: notes, chords: chords, framing: chosen)
    }

    private static func engraveApplying(
        notes: [NoteEvent],
        chords: [(seconds: Double, symbol: String)],
        framing chosen: ScoreFraming?
    ) -> Score? {
        // the engraver owns its grouping: inference reads onset groups, so
        // a raw note list from any source becomes grouped first
        let grouped = groupedForInference(notes)
        guard let first = grouped.map(\.onset).min() else { return nil }

        let tempo = chosen?.beatsPerMinute ?? inferTempo(grouped)
        let key = chosen?.key ?? inferKey(grouped)
        let timeSignature = chosen?.timeSignature ?? inferTimeSignature(grouped, tempo: tempo)
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

        // every measure index in the span exists, even the empty ones: a
        // two-bar rest still prints as two measures of rests
        let indices = noteGroups.keys.sorted()
        let measures: [ScoreMeasure] = indices.isEmpty ? [] : (indices.first!...indices.last!).map { index in
            ScoreMeasure(
                index: index,
                startTick: index * measureTicks + phase,
                notes: (noteGroups[index] ?? []).sorted { ($0.onsetTick, $0.pitch) < ($1.onsetTick, $1.pitch) }
            )
        }
        let chordSymbols = chords
            .sorted { $0.0 < $1.0 }
            // chord ticks live in the same phase-adjusted space as the
            // measures, or a pickup shifts them out of every measure
            .map { ScoreChordSymbol(onsetTick: adjusted(tick($0.0)), symbol: $0.1) }

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
