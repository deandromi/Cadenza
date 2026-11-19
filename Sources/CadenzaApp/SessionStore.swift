import CadenzaCore
import Foundation

/// One preserved session: the MIDI the pipeline produced, plus the facts
/// the panel lists it by.
struct SessionRecord: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let startedAt: Date
    let durationSeconds: Double
    let noteCount: Int

    var midiFileName: String { id.uuidString + ".mid" }

    /// The one-line label the panel shows: when it was, how long, how big.
    var label: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        let duration = sessionTimeString(durationSeconds)
        return "\(formatter.string(from: startedAt)) · \(duration) · \(noteCount) notes"
    }
}

/// The sessions archive: every finished session with at least one note
/// lands here as a MIDI file plus a record in the index.
@MainActor
final class SessionStore {
    private(set) var sessions: [SessionRecord] = []
    private let directory: URL

    init(directory: URL? = nil) {
        let base = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Cadenza/Sessions", isDirectory: true)
        self.directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        loadIndex()
    }

    /// Persists a finished session and returns what the panel lists it by.
    @discardableResult
    func saveSession(notes: [NoteEvent], startedAt: Date, durationSeconds: Double) -> SessionRecord? {
        guard !notes.isEmpty else { return nil }
        let record = SessionRecord(
            id: UUID(),
            startedAt: startedAt,
            durationSeconds: max(durationSeconds, notes.map { $0.offset }.max() ?? 0),
            noteCount: notes.count
        )
        do {
            try MidiFileWriter.write(notes, to: directory.appendingPathComponent(record.midiFileName))
            sessions.insert(record, at: 0)
            try JSONEncoder().encode(sessions).write(
                to: directory.appendingPathComponent("sessions.json"),
                options: .atomic
            )
            return record
        } catch {
            return nil
        }
    }

    /// The session's notes, read back from its MIDI file.
    func notes(for record: SessionRecord) -> [NoteEvent]? {
        let url = directory.appendingPathComponent(record.midiFileName)
        guard let file = try? MidiReader.read(url: url) else { return nil }
        return file.notes
    }

    private func loadIndex() {
        let index = directory.appendingPathComponent("sessions.json")
        guard let data = try? Data(contentsOf: index),
              let records = try? JSONDecoder().decode([SessionRecord].self, from: data) else { return }
        sessions = records.sorted { $0.startedAt > $1.startedAt }
    }
}
