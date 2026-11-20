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
