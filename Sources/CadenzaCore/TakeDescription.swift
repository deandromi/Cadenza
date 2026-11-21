import Foundation

/// What a take is, read from its notes alone: key, tempo, harmonic rhythm,
/// phrasing, cadences, texture and register. Deterministic music theory, no
/// model and no audio: the same notes always produce the same description,
/// which is what makes it usable in checks and as the base for the learning
/// section and the take's eventual booklet page.
public struct TakeDescription: Sendable, Equatable {
    /// One captioned line of the description, in the order it reads.
    public struct Line: Sendable, Equatable {
        public let caption: String
        public let value: String
    }

    public let keyName: String
    public let isMinor: Bool
    public let fifths: Int
    public let tempoBPM: Double
    public let noteCount: Int
    public let seconds: Double
    public let lines: [Line]
    /// One sentence a person can read at a glance.
    public let summary: String
}

public enum TakeAnalysis {
    // MARK: public entry

    /// Describes a take, or returns nil when there is nothing to describe.
    /// Notes are grouped by onset internally, so a caller can hand over the
    /// raw stream in any order.
    public static func describe(notes: [NoteEvent]) -> TakeDescription? {
        let played = notes.filter { $0.duration > 0 && $0.pitch >= 21 && $0.pitch <= 108 }
        guard played.count >= 2 else { return nil }
        let sorted = played.sorted { ($0.onset, $0.pitch) < ($1.onset, $1.pitch) }
        let start = sorted.first?.onset ?? 0
        let end = sorted.map(\.offset).max() ?? start
        let seconds = max(0.1, end - start)

        let onsets = clusterOnsets(sorted)
        let key = detectKey(sorted)
        let tempo = detectTempo(onsets: onsets, seconds: seconds)

        var lines: [TakeDescription.Line] = []
        lines.append(.init(caption: "Key", value: key.name))
        lines.append(.init(caption: "Tempo", value: "\(Int(tempo.rounded())) bpm"))

        let harmonic = harmonicRhythm(onsets: onsets, notes: sorted, tempo: tempo)
        if let harmonic {
            lines.append(.init(caption: "Harmony", value: harmonic))
        }

        let phrases = splitPhrases(sorted)
        lines.append(.init(caption: "Phrases", value: phraseSentence(phrases)))

        let cadences = phrases.map { cadence(of: $0, key: key) }
        let closed = cadences.filter { $0 == .tonic }.count
        let open = cadences.filter { $0 == .dominant }.count
        lines.append(.init(caption: "Cadences",
                           value: "\(closed) on the tonic, \(open) on the dominant, \(cadences.count - closed - open) unresolved"))

        let density = Double(sorted.count) / seconds
        let chordNotes = groupedNotes(sorted)
        let simultaneous = chordNotes.isEmpty ? 1.0 : Double(chordNotes.map(\.count).reduce(0, +)) / Double(chordNotes.count)
        var texture = density < 1.2 ? "sparse" : (density < 4 ? "flowing" : "dense")
        if simultaneous >= 2.6 { texture += ", chordal" }
        if chordNotes.count > 4, Double(chordNotes.count) / Double(sorted.count) > 0.25 { texture += ", voiced" }
        lines.append(.init(caption: "Texture", value: String(format: "%@ · %.1f notes a second", texture, density)))

        let low = sorted.map(\.pitch).min() ?? 21
        let high = sorted.map(\.pitch).max() ?? 108
        let bassShare = Double(sorted.filter { $0.pitch < 60 }.count) / Double(sorted.count)
        lines.append(.init(caption: "Register",
                           value: "\(pitchName(low)) to \(pitchName(high)) · \(Int((bassShare * 100).rounded()))% below middle C"))

        let summary = makeSummary(key: key, tempo: tempo, phrases: phrases.count,
                                 texture: texture, seconds: seconds)
        return TakeDescription(keyName: key.name, isMinor: key.isMinor,
                               fifths: key.fifths, tempoBPM: tempo,
                               noteCount: sorted.count, seconds: seconds,
                               lines: lines, summary: summary)
    }

    // MARK: onset clusters

    /// Unique strike moments: notes within 60 ms of each other are one moment,
    /// so a chord counts once and an arpeggio counts as its attacks.
    static func clusterOnsets(_ notes: [NoteEvent]) -> [Double] {
        var moments: [Double] = []
        for note in notes.sorted(by: { $0.onset < $1.onset }) {
            if let last = moments.last, note.onset - last < 0.06 { continue }
            moments.append(note.onset)
        }
        return moments
    }

    /// The notes per strike moment, in time order.
    static func groupedNotes(_ notes: [NoteEvent]) -> [[NoteEvent]] {
        var groups: [[NoteEvent]] = []
        for note in notes.sorted(by: { $0.onset < $1.onset }) {
            if var last = groups.last, let first = last.first, note.onset - first.onset < 0.06 {
                last.append(note)
                groups[groups.count - 1] = last
            } else {
                groups.append([note])
            }
        }
        return groups
    }

    // MARK: key

    /// Krumhansl-Kessler key finding over sounding time, with a tie-break
    /// towards the key that needs fewer accidentals. A performance that
    /// mostly sits on white keys should never be described as five flats
    /// because one chromatic note came past.
    static func detectKey(_ notes: [NoteEvent]) -> (name: String, fifths: Int, isMinor: Bool, tonic: Int, scale: Set<Int>) {
        var weight = [Double](repeating: 0, count: 12)
        for note in notes {
            weight[note.pitchClass] += max(0.05, min(8.0, note.duration))
        }
        let major: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
        let minor: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
        func correlate(profile: [Double], rotatedBy tonic: Int) -> Double {
            var sum = 0.0
            for degree in 0..<12 {
                sum += weight[(tonic + degree) % 12] * profile[degree]
            }
            return sum
        }
        var best: (score: Double, tonic: Int, isMinor: Bool) = (-1, 0, false)
        for tonic in 0..<12 {
            for isMinor in [false, true] {
                let score = correlate(profile: isMinor ? minor : major, rotatedBy: tonic)
                if score > best.score { best = (score, tonic, isMinor) }
            }
        }
        // Near ties are decided by what a reader would write down: the key
        // with fewer accidentals, and a major reading over its relative minor,
        // which is how a take without a strong minor third is normally read.
        // Both differences are inside the estimator's own noise.
        let tolerance = best.score * 0.02
        var chosen = best
        for tonic in 0..<12 {
            for isMinor in [false, true] {
                let score = correlate(profile: isMinor ? minor : major, rotatedBy: tonic)
                guard score >= best.score - tolerance else { continue }
                let accidental = abs(majorFifths(tonic: tonic, isMinor: isMinor))
                let chosenAccidental = abs(majorFifths(tonic: chosen.tonic, isMinor: chosen.isMinor))
                let betterAccidentals = accidental < chosenAccidental
                let sameAccidentalsPreferMajor = accidental == chosenAccidental
                    && chosen.isMinor && !isMinor
                if betterAccidentals || sameAccidentalsPreferMajor {
                    chosen = (score, tonic, isMinor)
                }
            }
        }
        let fifths = majorFifths(tonic: chosen.tonic, isMinor: chosen.isMinor)
        let scale = scalePitchClasses(tonic: chosen.tonic, isMinor: chosen.isMinor)
        let name = "\(keyName(chosen.tonic)) \(chosen.isMinor ? "minor" : "major")"
        return (name, fifths, chosen.isMinor, chosen.tonic, scale)
    }

    static func majorFifths(tonic: Int, isMinor: Bool) -> Int {
        // tonic pitch classes on the circle of fifths: F=-1, C=0, G=1 ...
        let circle = [0: 0, 7: 1, 2: 2, 9: 3, 4: 4, 11: 5, 6: 6, 1: -5, 8: -4, 3: -3, 10: -2, 5: -1]
        let base = circle[tonic] ?? 0
        return isMinor ? base - 3 : base
    }

    static func scalePitchClasses(tonic: Int, isMinor: Bool) -> Set<Int> {
        let steps = isMinor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]
        return Set(steps.map { (tonic + $0) % 12 })
    }

    // MARK: tempo

    /// Tempo from the strike moments: the median gap between attacks is taken
    /// as the pulse and folded into 60-180, because a performer's sixteenth
    /// notes are not the tempo of the piece.
    static func detectTempo(onsets: [Double], seconds: Double) -> Double {
        guard onsets.count >= 3 else { return 72 }
        var gaps: [Double] = []
        for index in 1..<onsets.count {
            let gap = onsets[index] - onsets[index - 1]
            // up to four seconds: a slow chord progression is still a pulse
            if gap > 0.03, gap < 4.0 { gaps.append(gap) }
        }
        guard !gaps.isEmpty else { return 72 }
        gaps.sort()
        let median = gaps[gaps.count / 2]
        var bpm = 60.0 / median
        // fold into the range a performer would call the pulse: 25 bpm of
        // chord changes is a slow piece at 100, not a piece at 25
        while bpm > 160 { bpm /= 2 }
        while bpm < 72 { bpm *= 2 }
        return min(240, max(40, bpm))
    }

    // MARK: harmony

    /// How often the harmony changes: the median gap between strike moments
    /// that sound two notes or more, expressed in beats of the detected tempo.
    static func harmonicRhythm(onsets: [Double], notes: [NoteEvent], tempo: Double) -> String? {
        let chordMoments = groupedNotes(notes).filter { $0.count >= 2 }.map { $0[0].onset }
        guard chordMoments.count >= 3 else { return nil }
        var gaps: [Double] = []
        for index in 1..<chordMoments.count {
            let gap = chordMoments[index] - chordMoments[index - 1]
            if gap > 0.05 { gaps.append(gap) }
        }
        guard !gaps.isEmpty else { return nil }
        gaps.sort()
        let median = gaps[gaps.count / 2]
        let beats = median * tempo / 60
        let description: String
        switch beats {
        case ..<1.4: description = "a chord a beat"
        case ..<2.6: description = "a chord every two beats"
        case ..<4.6: description = "a chord a bar"
        default: description = String(format: "a chord every %.1f beats", beats)
        }
        return "\(description) · \(chordMoments.count) chord changes"
    }

    // MARK: phrases and cadences

    /// Takes split at real silence, not at every short gap: a pause of 0.9 s
    /// or more between one phrase's end and the next attack.
    static func splitPhrases(_ notes: [NoteEvent]) -> [[NoteEvent]] {
        guard !notes.isEmpty else { return [] }
        var phrases: [[NoteEvent]] = []
        var current: [NoteEvent] = []
        var soundingEnd = 0.0
        for note in notes {
            if !current.isEmpty, note.onset - soundingEnd >= 0.9 {
                phrases.append(current)
                current = []
            }
            current.append(note)
            soundingEnd = max(soundingEnd, note.offset)
        }
        if !current.isEmpty { phrases.append(current) }
        return phrases
    }

    enum Cadence: Equatable {
        case tonic
        case dominant
        case other
    }

    static func cadence(of phrase: [NoteEvent], key: (name: String, fifths: Int, isMinor: Bool, tonic: Int, scale: Set<Int>)) -> Cadence {
        guard let last = phrase.max(by: { $0.onset < $1.onset }) else { return .other }
        // every note of the closing moment counts, not just the top one
        let moment = phrase.filter { last.onset - $0.onset < 0.06 }
        let classes = Set(moment.map(\.pitchClass))
        if classes.contains(key.tonic) { return .tonic }
        if classes.contains((key.tonic + 7) % 12) { return .dominant }
        return .other
    }

    static func phraseSentence(_ phrases: [[NoteEvent]]) -> String {
        guard !phrases.isEmpty else { return "none" }
        let lengths = phrases.map { phrase -> Double in
            let start = phrase.map(\.onset).min() ?? 0
            let end = phrase.map(\.offset).max() ?? start
            return end - start
        }
        let average = lengths.reduce(0, +) / Double(lengths.count)
        let shape = lengths.count == 1
            ? "one phrase"
            : "\(lengths.count) phrases, \(String(format: "%.1f", average)) s each"
        return shape
    }

    static func makeSummary(key: (name: String, fifths: Int, isMinor: Bool, tonic: Int, scale: Set<Int>),
                            tempo: Double, phrases: Int, texture: String, seconds: Double) -> String {
        var parts: [String] = []
        parts.append("\(texture.prefix(1).uppercased())\(texture.dropFirst()) playing in \(key.name)")
        parts.append("about \(Int(tempo.rounded())) bpm")
        parts.append(phrases == 1 ? "one phrase" : "\(phrases) phrases")
        parts.append(timeString(seconds))
        return parts.joined(separator: " · ")
    }

    // MARK: names

    static func timeString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func keyName(_ pitchClass: Int) -> String {
        let names = ["C", "C sharp", "D", "E flat", "E", "F", "F sharp", "G", "A flat", "A", "B flat", "B"]
        return names[((pitchClass % 12) + 12) % 12]
    }

    static func pitchName(_ pitch: Int) -> String {
        let names = ["C", "C sharp", "D", "E flat", "E", "F", "F sharp", "G", "A flat", "A", "B flat", "B"]
        let index = ((pitch % 12) + 12) % 12
        let octave = pitch / 12 - 1
        return "\(names[index])\(octave)"
    }
}
