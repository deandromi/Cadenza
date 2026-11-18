/// A single transcribed note, the unit every subsystem speaks in.
///
/// Timing is in seconds relative to the start of the performance.
public struct NoteEvent: Sendable, Equatable, Hashable {
    /// MIDI note number, 21 (A0) through 108 (C8).
    public var pitch: Int

    /// MIDI velocity, 1 through 127.
    public var velocity: Int

    /// Seconds since the performance started.
    public var onset: Double

    /// Sounding duration in seconds, sustain pedal included.
    public var duration: Double

    /// Notes whose onsets fall within the grouping tolerance of each other
    /// share a group id, which is what chord inference keys off.
    public var onsetGroup: Int

    public init(pitch: Int, velocity: Int, onset: Double, duration: Double, onsetGroup: Int = 0) {
        self.pitch = pitch
        self.velocity = velocity
        self.onset = onset
        self.duration = duration
        self.onsetGroup = onsetGroup
    }

    public var pitchClass: Int { ((pitch % 12) + 12) % 12 }

    public var offset: Double { onset + duration }
}

/// Grouping tolerance for shared onsets, in seconds. Notes struck within this
/// window of each other are treated as played together.
public let onsetGroupingTolerance: Double = 0.05

/// Assign consecutive onset groups to notes based on `onsetGroupingTolerance`.
/// Input is sorted by onset as a side effect.
public func assignOnsetGroups(_ notes: [NoteEvent]) -> [NoteEvent] {
    let sorted = notes.sorted { $0.onset < $1.onset }
    var result: [NoteEvent] = []
    var group = 0
    var lastOnset = -Double.infinity
    for note in sorted {
        if note.onset - lastOnset > onsetGroupingTolerance {
            group += 1
        }
        var note = note
        note.onsetGroup = group
        result.append(note)
        lastOnset = note.onset
    }
    return result
}
