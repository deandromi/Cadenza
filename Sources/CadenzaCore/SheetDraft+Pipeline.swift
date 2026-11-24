import Foundation

/// The pipeline: notes in, engraved geometry out, with the options a take
/// implies when the player did not choose any.
extension SheetDraft {
    // MARK: the pipeline

    /// Engrave the live note stream into a complete sheet draft. Pedal
    /// spans arrive in ticks ( pedal down to release); they engrave as
    /// Ped./release marks under the bass staff.
    public static func draft(notes: [NoteEvent] /* live stream */, options: Options, pageWidth: Double = 88,
                             pedals: [PedalSpan] = [], originTicks: Int? = nil,
                             timeMap: TimeMap? = nil,
                             declaredFifths: Int? = nil) -> Result {
        SheetEngraver.engrave(notes: notes, options: options, pageWidth: pageWidth,
                              pedals: pedals, originTicks: originTicks, timeMap: timeMap,
                              declaredFifths: declaredFifths)
    }

    /// The options a performance itself argues for: tempo from the pulse of
    /// the played onsets, meter from where the accents fall. A session has no
    /// file header to read, so this is how the sheet picks a 3/4 waltz over a
    /// default 4/4, which no amount of engraving can fix afterwards.
    public static func inferredOptions(notes: [NoteEvent]) -> Options {
        guard notes.count >= 4 else { return Options() }
        let tempo = Engraver.inferTempo(notes)
        let meter = Engraver.inferTimeSignature(notes, tempo: tempo)
        let bass = bassMeterGuess(notes, tempo: tempo)
        let numerator = bass ?? meter.beatsPerMeasure
        return Options(bpm: tempo,
                       numerator: numerator,
                       denominator: meter.beatUnit)
    }

    /// The meter the left hand argues for.
    ///
    /// A waltz bass lands on the downbeat and nowhere else, so the lowest
    /// note of each attack clusters on the bar line of the true meter and
    /// smears under a wrong one. That is a sharper signal than the full
    /// onset histogram, which every meter explains about equally well once
    /// subdivisions are in play. Nil when the bass says nothing.
    public static func bassMeterGuess(_ notes: [NoteEvent], tempo: Double) -> Int? {
        let quarter = 60.0 / tempo
        guard quarter > 0.05 else { return nil }
        // the lowest note of every attack: the bass voice. Attacks are
        // grouped by onset rather than by onsetGroup, because an imported
        // MIDI file carries no group ids.
        var lowest: [Int: (onset: Double, pitch: Int)] = [:]
        for note in notes {
            let slot = Int((note.onset / 0.05).rounded())
            if let current = lowest[slot] {
                if note.pitch < current.pitch {
                    lowest[slot] = (min(current.onset, note.onset), note.pitch)
                }
            } else {
                lowest[slot] = (note.onset, note.pitch)
            }
        }
        let all = lowest.values.sorted { $0.onset < $1.onset }
        // the bass voice proper: the attacks whose lowest note sits in the
        // bottom of the piece's register. Inner chords on the weak beats sit
        // a third or fifth higher and would smear the very barline this
        // measures.
        let floor = all.map(\.pitch).min() ?? 0
        let deep = all.filter { $0.pitch <= floor + 7 }
        let bass = deep.count >= 4 ? deep : all
        guard bass.count >= 12 else { return nil }
        let origin = bass[0].onset
        // Phase concentration of the bass around a bar length: a waltz bass
        // comes back every three beats, and under any other period its
        // phase drifts. Two and four cannot be separated this way — a
        // four-beat barline is also a two-beat barline — so this only ever
        // calls a waltz, and everything else defers to the meter scorer.
        func concentration(beats: Double) -> Double {
            let bar = quarter * beats
            guard bar > 0.1 else { return 0 }
            var x = 0.0
            var y = 0.0
            for note in bass {
                let phase = 2 * Double.pi * (note.onset - origin) / bar
                x += cos(phase)
                y += sin(phase)
            }
            return (x * x + y * y).squareRoot() / Double(bass.count)
        }
        let three = concentration(beats: 3)
        let four = concentration(beats: 4)
        if ProcessInfo.processInfo.environment["CDZ_METER_DEBUG"] != nil {
            print(String(format: "[meter] bass %d notes, three %.2f four %.2f",
                         bass.count, three, four))
        }
        // a waltz has to be tight and clearly tighter than four
        guard three >= 0.30, three >= 2 * four else { return nil }
        return 3
    }

    private static func emptyResult(options: Options) -> Result {
        let top: [Symbol] = [.bar(startTicks: 0), .finalBar(startTicks: options.measureTicks)]
        let bottom: [Symbol] = [.bar(startTicks: 0), .finalBar(startTicks: options.measureTicks)]
        func place(_ list: [Symbol]) -> [Placed] {
            var x = 9.5
            return list.enumerated().map { i, s in
                let p = Placed(x: x, trackIndex: i, symbol: s)
                x += s.width
                return p
            }
        }
        let row = Row(clefTop: .treble, clefBottom: .bass,
                      top: place(top), bottom: place(bottom),
                      firstMeasure: 1, showsFraming: true, width: 88)
        let rowHeight = 4.0 + ScoreLayout.staffGap + 4.0 + 12.0
        return Result(options: options, fifths: 0, topTrack: top, bottomTrack: bottom,
                      rows: [row], beamGroups: [], width: 88, rowHeight: rowHeight,
                      totalHeight: rowHeight + 6.0, rowsPerPage: SheetEngraver.systemsPerPage)
    }
}
