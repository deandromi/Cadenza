import Foundation

/// One chord of a take, at the moment it was struck.
public struct ChordSheetEntry: Sendable, Equatable {
    public let onset: Double
    public let chord: Chord

    public init(onset: Double, chord: Chord) {
        self.onset = onset
        self.chord = chord
    }
}

/// The chord sheet of a take: the notes grouped by strike, one entry per
/// group that spells a chord, in playing order.
///
/// This lives here, not in the app, because it is inference: it reads only
/// `NoteEvent` values and can be replayed from a recorded MIDI file. The
/// grouping happens once for the whole take, so the cost of reading the sheet
/// is one pass over the notes rather than one pass per chord.
public enum ChordSheet {
    public static func entries(for notes: [NoteEvent]) -> [ChordSheetEntry] {
        let grouped = assignOnsetGroups(notes)
        var byGroup: [Int: [NoteEvent]] = [:]
        for note in grouped {
            byGroup[note.onsetGroup, default: []].append(note)
        }
        return byGroup.keys.sorted().compactMap { group in
            guard let groupNotes = byGroup[group],
                  let chord = Chord.identify(notes: groupNotes, group: group) else { return nil }
            return ChordSheetEntry(onset: groupNotes[0].onset, chord: chord)
        }
    }
}
