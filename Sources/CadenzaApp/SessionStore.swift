import CadenzaCore
import Foundation

/// One preserved session: the MIDI the pipeline produced, the optional audio
/// recording, plus the facts the panel lists it by. Sessions live in their
/// own folder under the session directory: `Session N/session.mid`,
/// `Session N/audio.wav`.
struct SessionRecord: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    /// User-given name; the panel falls back to the date/duration label.
    /// Defaulted so indexes written by older versions still decode.
    var name: String? = nil
    /// The session's folder under the session directory, e.g. "Session 3".
    /// Legacy records (flat .mid next to the index) have nil.
    var folderName: String? = nil
    let startedAt: Date
    let durationSeconds: Double
    let noteCount: Int
    /// Whether an audio.wav sits in the session folder.
    var hasAudio: Bool = false

    var midiFileName: String { "session.mid" }
    var audioFileName: String { "audio.wav" }

    /// The one-line label the panel shows: the name if given, else when it
    /// was, how long, how big.
    var label: String {
        if let name, !name.isEmpty { return name }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        let duration = sessionTimeString(durationSeconds)
        return "\(formatter.string(from: startedAt)) · \(duration) · \(noteCount) notes"
    }
}

/// Writes raw f32 mono samples as a 16-bit PCM WAV file.
enum WavWriter {
    static func write(_ samples: [Float], rate: Double, to url: URL) throws {
        let dataCount = UInt32(samples.count * 2)
        var header = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; header.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; header.append(Data(bytes: &x, count: 2)) }
        header.append(Data("RIFF".utf8)); u32(36 + dataCount); header.append(Data("WAVE".utf8))
        header.append(Data("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        header.append(Data("data".utf8)); u32(dataCount)
        var body = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, Double(sample)))
            var pcm = Int16(clamped * 32767).littleEndian
            body.append(Data(bytes: &pcm, count: 2))
        }
        try (header + body).write(to: url)
    }
}

/// The sessions archive: every finished session with at least one note
/// lands in its own folder under the session directory as a MIDI file
/// (plus a WAV recording when audio keeping is on), indexed in
/// `sessions.json` at the directory's root.
@MainActor
final class SessionStore {
    private(set) var sessions: [SessionRecord] = []
    private(set) var directory: URL

    static let defaultDirectory: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Cadenza/Sessions", isDirectory: true)
    }()

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        loadIndex()
    }

    /// Moves the archive to another directory (the settings' session
    /// directory) and reloads the index from there.
    func setDirectory(_ url: URL) {
        directory = url
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        loadIndex()
    }

    private var indexURL: URL { directory.appendingPathComponent("sessions.json") }

    /// The folder a session record lives in.
    func folderURL(for record: SessionRecord) -> URL {
        if let folderName = record.folderName {
            return directory.appendingPathComponent(folderName, isDirectory: true)
        }
        return directory
    }

    func midiURL(for record: SessionRecord) -> URL {
        folderURL(for: record).appendingPathComponent(
            record.folderName == nil ? record.id.uuidString + ".mid" : record.midiFileName)
    }

    func audioURL(for record: SessionRecord) -> URL {
        folderURL(for: record).appendingPathComponent(record.audioFileName)
    }

    /// Persists a finished session in a fresh "Session N" folder and returns
    /// what the panel lists it by. Sessions with no notes are discarded.
    @discardableResult
    func saveSession(notes: [NoteEvent], startedAt: Date, durationSeconds: Double,
                     audio: (samples: [Float], rate: Double)? = nil, keepAudio: Bool = true) -> SessionRecord? {
        guard !notes.isEmpty else { return nil }
        let folderName = nextFolderName()
        let folder = directory.appendingPathComponent(folderName, isDirectory: true)
        var record = SessionRecord(
            id: UUID(),
            startedAt: startedAt,
            durationSeconds: max(durationSeconds, notes.map { $0.offset }.max() ?? 0),
            noteCount: notes.count
        )
        record.folderName = folderName
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try MidiFileWriter.write(notes, to: folder.appendingPathComponent(record.midiFileName))
            if keepAudio, let audio {
                try WavWriter.write(audio.samples, rate: audio.rate, to: folder.appendingPathComponent(record.audioFileName))
                record.hasAudio = true
            }
            sessions.insert(record, at: 0)
            try JSONEncoder().encode(sessions).write(to: indexURL, options: .atomic)
            return record
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
    }

    /// Renames a session; the name shows in the panel instead of the
    /// date/duration label.
    func rename(_ record: SessionRecord, to name: String) {
        guard let index = sessions.firstIndex(where: { $0.id == record.id }) else { return }
        sessions[index].name = name.isEmpty ? nil : name
        try? JSONEncoder().encode(sessions).write(to: indexURL, options: .atomic)
    }

    /// Imports a MIDI file as a session: the file is copied into a fresh
    /// "Session N" folder and the archive lists it under the file's name.
    /// Returns the new record, or nil when the file holds no notes.
    @discardableResult
    func importSession(from url: URL, name: String) -> SessionRecord? {
        guard let file = try? MidiReader.read(url: url), !file.notes.isEmpty else { return nil }
        let folderName = nextFolderName()
        let folder = directory.appendingPathComponent(folderName, isDirectory: true)
        var record = SessionRecord(
            id: UUID(),
            startedAt: Date(),
            durationSeconds: file.notes.map { $0.offset }.max() ?? 0,
            noteCount: file.notes.count
        )
        record.folderName = folderName
        record.name = name
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(record.midiFileName))
            sessions.insert(record, at: 0)
            try JSONEncoder().encode(sessions).write(to: indexURL, options: .atomic)
            return record
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
    }

    /// The session's sustain-pedal spans in seconds, read back from its
    /// MIDI file; empty when the file carries no pedal.
    func pedalSpans(for record: SessionRecord) -> [(start: Double, end: Double)] {
        guard let file = try? MidiReader.read(url: midiURL(for: record)) else { return [] }
        return file.sustainPedals
    }

    /// The session's notes, read back from its MIDI file.
    func notes(for record: SessionRecord) -> [NoteEvent]? {
        guard let file = try? MidiReader.read(url: midiURL(for: record)) else { return nil }
        return file.notes
    }

    /// The next free "Session N" folder name.
    private func nextFolderName() -> String {
        let existing = Set(sessions.compactMap { $0.folderName })
        var n = 1
        while existing.contains("Session \(n)") { n += 1 }
        // also respect folders on disk not yet in the index
        let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        while onDisk.contains("Session \(n)") { n += 1 }
        return "Session \(n)"
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let records = try? JSONDecoder().decode([SessionRecord].self, from: data) else {
            sessions = []
            return
        }
        sessions = records.sorted { $0.startedAt > $1.startedAt }
    }
}
