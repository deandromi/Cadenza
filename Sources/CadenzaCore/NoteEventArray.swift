public extension Array where Element == NoteEvent {
    /// Sorts by onset and assigns shared-onset groups. Chain rule applies:
    /// notes within the tolerance of the previous note join its group.
    func assignOnsetGroups() -> [NoteEvent] {
        CadenzaCore.assignOnsetGroups(self)
    }
}

/// One strike, seen once.
///
/// The streaming merge can hand back the same key twice: a re-decode of a
/// window that overlaps the one that already reported the note, or a
/// re-strike that replaced a live note and left its stub behind. A piano key
/// cannot strike twice inside 60 ms — a trill at 16 Hz is already beyond
/// playing — so two notes of one pitch that close together are one note, and
/// the longer interval is the one that was really heard.
public enum SingleStrikes {
    /// A key cannot be struck again this soon after itself.
    public static let window = 0.06

    public static func merge(_ notes: [NoteEvent]) -> [NoteEvent] {
        var kept: [NoteEvent] = []
        for note in notes.sorted(by: { $0.onset < $1.onset }) {
            if let index = kept.lastIndex(where: { $0.pitch == note.pitch }),
               note.onset - kept[index].onset < window {
                // one strike: keep the interval that reaches furthest
                let end = max(kept[index].offset, note.offset)
                kept[index].duration = end - kept[index].onset
                kept[index].velocity = max(kept[index].velocity, note.velocity)
                continue
            }
            kept.append(note)
        }
        return kept
    }
}

/// A key cannot be struck while it is still down.
///
/// A pedal-held note is extended to the moment the pedal lifts, and that is
/// right for the sound: the string keeps ringing. It is wrong for the key.
/// When the same pitch is played again underneath it, the model has reported
/// a note that outlives its own re-strike — the second attack is proof the
/// key came up. Left alone, that pair prints as a chain of ties across bars,
/// overlays itself in the exported MIDI and makes the same pitch look like
/// two voices, so the note ends where the next strike begins.
///
/// This is the physical rule of the instrument, not a heuristic: the only
/// question it asks is "was this key played again", and the answer is the
/// next onset of the same pitch.
public enum RestruckKeys {
    /// The shortest interval a strike may be left with, in seconds: shorter
    /// than this and the note is inaudible, so a strike that supersedes a note
    /// almost at once leaves a stub rather than nothing.
    public static let floor = 0.02

    public static func clip(_ notes: [NoteEvent]) -> [NoteEvent] {
        var kept: [NoteEvent] = []
        // pitch -> index in `kept` of its most recent strike
        var last: [Int: Int] = [:]
        for note in notes.sorted(by: { ($0.onset, $0.pitch) < ($1.onset, $1.pitch) }) {
            var note = note
            if let index = last[note.pitch] {
                let held = kept[index]
                let room = note.onset - held.onset
                if held.duration > room {
                    kept[index].duration = max(floor, room)
                }
            }
            last[note.pitch] = kept.count
            kept.append(note)
        }
        return kept
    }
}
