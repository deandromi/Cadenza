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
    /// Whether the session folder carries its engraved sheet.pdf.
    var hasPDF: Bool = false
    /// File names inside the folder. Defaulted so indexes written before a
    /// rename still decode; a renamed session carries its own name here.
    var midiFile: String? = nil
    var audioFile: String? = nil
    var pdfFile: String? = nil

    var midiFileName: String { midiFile ?? "session.mid" }
    var audioFileName: String { audioFile ?? "audio.wav" }
    var pdfFileName: String { pdfFile ?? "sheet.pdf" }

    /// The one-line label the panel shows: the name if given, else when it
    /// was, how long, how big.
    var label: String {
        if let name, !name.isEmpty { return name }
        let duration = sessionTimeString(durationSeconds)
        return "\(SessionStamp.panel.string(from: startedAt)) · \(duration) · \(noteCount) notes"
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

/// A wav file written as the audio arrives: the 44-byte header goes down
/// up front and its two size fields are patched on close, so a session of
/// any length costs no RAM.
extension WavWriter {
    final class Sink {
        let url: URL
        private let handle: FileHandle
        private(set) var frames = 0
        private var closed = false

        init?(url: URL, rate: Double) {
            self.url = url
            FileManager.default.createFile(atPath: url.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
            self.handle = handle
            handle.write(Self.header(rate: rate, dataCount: 0))
        }

        /// Appends one chunk of raw mono samples as 16-bit PCM.
        func append(_ samples: [Float]) {
            guard !closed, !samples.isEmpty else { return }
            var pcm = Data(capacity: samples.count * 2)
            for sample in samples {
                let clamped = max(-1.0, min(1.0, Double(sample)))
                var value = Int16(clamped * 32767).littleEndian
                pcm.append(Data(bytes: &value, count: 2))
            }
            handle.write(pcm)
            frames += samples.count
        }

        /// Patches the RIFF and data sizes with the real byte counts and
        /// closes the file.
        func close() {
            guard !closed else { return }
            closed = true
            var size = UInt32(36 + (frames * 2)).littleEndian
            var count = UInt32(frames * 2).littleEndian
            handle.seek(toFileOffset: 4)
            handle.write(Data(bytes: &size, count: 4))
            handle.seek(toFileOffset: 40)
            handle.write(Data(bytes: &count, count: 4))
            try? handle.close()
        }

        /// Best-effort abandonment used when a session is thrown away.
        func closeAndDelete() {
            close()
            try? FileManager.default.removeItem(at: url)
        }

        private static func header(rate: Double, dataCount: UInt32) -> Data {
            var header = Data()
            func u32(_ v: UInt32) { var x = v.littleEndian; header.append(Data(bytes: &x, count: 4)) }
            func u16(_ v: UInt16) { var x = v.littleEndian; header.append(Data(bytes: &x, count: 2)) }
            header.append(Data("RIFF".utf8)); u32(36 + dataCount); header.append(Data("WAVE".utf8))
            header.append(Data("fmt ".utf8)); u32(16); u16(1); u16(1)
            u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
            header.append(Data("data".utf8)); u32(dataCount)
            return header
        }
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
                     audio: (url: URL, rate: Double)? = nil, keepAudio: Bool = true) -> SessionRecord? {
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
            if keepAudio, let audio, FileManager.default.fileExists(atPath: audio.url.path) {
                try FileManager.default.moveItem(at: audio.url, to: folder.appendingPathComponent(record.audioFileName))
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

    /// Names a session for good. The name is the session's identity on disk:
    /// the folder under the session directory and the MIDI, WAV and sheet PDF
    /// inside it all take it, so what the panel lists is what a Finder window
    /// shows. An empty name keeps everything as it is.
    @discardableResult
    func rename(_ record: SessionRecord, to rawName: String) -> SessionRecord? {
        guard let index = sessions.firstIndex(where: { $0.id == record.id }) else { return nil }
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let name = Self.fileSafeName(trimmed)
        guard !name.isEmpty else { return nil }
        var updated = sessions[index]
        let manager = FileManager.default

        if let folderName = updated.folderName {
            let oldFolder = directory.appendingPathComponent(folderName, isDirectory: true)
            var folder = oldFolder
            if name != folderName {
                let target = uniqueFolder(named: name, excluding: folderName)
                try? manager.moveItem(at: oldFolder, to: target)
                folder = target
                updated.folderName = target.lastPathComponent
            }
            // the files inside follow the folder's name
            let base = folder.lastPathComponent
            let files: [(keyPath: WritableKeyPath<SessionRecord, String?>, current: String, suffix: String)] = [
                (\.midiFile, updated.midiFileName, ".mid"),
                (\.audioFile, updated.audioFileName, ".wav"),
                (\.pdfFile, updated.pdfFileName, ".pdf"),
            ]
            for file in files {
                let source = folder.appendingPathComponent(file.current)
                guard manager.fileExists(atPath: source.path) else { continue }
                let targetName = base + file.suffix
                if file.current != targetName {
                    try? manager.moveItem(at: source, to: folder.appendingPathComponent(targetName))
                }
                updated[keyPath: file.keyPath] = targetName
            }
        } else {
            // a legacy flat .mid next to the index
            let source = directory.appendingPathComponent(record.id.uuidString + ".mid")
            let target = uniqueFolder(named: name, excluding: nil) // folder helper, file below
            let flat = directory.appendingPathComponent(name + ".mid")
            if manager.fileExists(atPath: source.path), !manager.fileExists(atPath: flat.path) {
                try? manager.moveItem(at: source, to: flat)
            }
            updated.midiFile = flat.lastPathComponent
            _ = target
        }

        updated.name = name
        sessions[index] = updated
        try? JSONEncoder().encode(sessions).write(to: indexURL, options: .atomic)
        return updated
    }

    /// Removes a session completely: its folder (MIDI, WAV, sheet PDF) or its
    /// legacy flat file, and its row in the index.
    @discardableResult
    func delete(_ record: SessionRecord) -> Bool {
        let manager = FileManager.default
        if let folderName = record.folderName {
            let folder = directory.appendingPathComponent(folderName, isDirectory: true)
            try? manager.removeItem(at: folder)
        } else {
            try? manager.removeItem(at: midiURL(for: record))
            try? manager.removeItem(at: audioURL(for: record))
        }
        sessions.removeAll { $0.id == record.id }
        try? JSONEncoder().encode(sessions).write(to: indexURL, options: .atomic)
        return true
    }

    /// A folder name that is safe on disk and free to use: path separators and
    /// colons stripped, leading dots avoided, and a number added when the name
    /// is already taken by another session.
    private func uniqueFolder(named name: String, excluding current: String?) -> URL {
        let existing = Set(sessions.compactMap { $0.folderName })
        var candidate = name
        var n = 2
        while (existing.contains(candidate) && candidate != current)
            || FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path)
                && candidate != current {
            candidate = "\(name) \(n)"
            n += 1
        }
        return directory.appendingPathComponent(candidate, isDirectory: true)
    }

    /// The name as a file name: separators, colons and control characters
    /// removed, runs of spaces collapsed, length capped.
    static func fileSafeName(_ name: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters)
        let cleaned = name.components(separatedBy: banned).joined(separator: " ")
            .split(separator: " ").joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return String(cleaned.prefix(60))
    }

    /// Marks a session's sheet as engraved once its PDF landed.
    func markHasPDF(_ record: SessionRecord) {
        guard let index = sessions.firstIndex(where: { $0.id == record.id }) else { return }
        sessions[index].hasPDF = true
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

/// The app's date stamps, built once. A DateFormatter is expensive to make and
/// cheap to use, so the panel rows and the statistics window share these
/// instead of minting one per label; `string(from:)` is safe to call from any
/// thread, which is the only thing that ever happens to them.
enum SessionStamp {
    nonisolated(unsafe) static let panel: DateFormatter = make("d MMM HH:mm")
    nonisolated(unsafe) static let day: DateFormatter = make("EEE d MMM")

    private static func make(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter
    }
}
