import AppKit
import CadenzaCore
import Foundation

/// Turns the score into a page with the bundled LilyPond.
///
/// This is the only place the app runs another program. It is worth it: the
/// notation is typeset by the engraver publishers use, not drawn by us, and
/// the difference is visible at a glance — stem lengths, beam slopes, spacing
/// between systems and how a page breaks are all decisions LilyPond makes.
///
/// The engraver sits in the app's own Resources (see Tools/bundle_lilypond.sh),
/// so it works on a Mac that never installed anything. When it is missing —
/// a debug build from a checkout that has not staged it — `isAvailable` is
/// false and the caller falls back to the engraver Cadenza draws itself.
enum LilyPondEngraver {

    /// Where the staged engraver lives: inside the bundle when the app was
    /// assembled, next to the build products when it was run from a checkout.
    static var wrapperURL: URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("engraver/run.sh"))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/engraver/run.sh"))
        // A checkout's build products: the executable sits in .build/<config>/
        // and the engraver in build/engraver. Walking up finds it without
        // baking this machine's paths into the app.
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0..<5 {
            candidates.append(directory.appendingPathComponent("build/engraver/run.sh"))
            directory = directory.deletingLastPathComponent()
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/engraver/run.sh"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var isAvailable: Bool { wrapperURL != nil }

    /// The version string to show in settings, read from the staged files
    /// rather than by running the engraver: a menu does not wait on a process.
    static var versionText: String? {
        guard let wrapper = wrapperURL else { return nil }
        let share = wrapper.deletingLastPathComponent().appendingPathComponent("share/lilypond")
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: share.path),
              let version = versions.sorted().first else { return nil }
        return "LilyPond \(version)"
    }

    enum EngravingError: LocalizedError {
        case notStaged
        case failed(status: Int32, message: String)
        case nothingWritten

        var errorDescription: String? {
            switch self {
            case .notStaged:
                return "The bundled engraver is missing from this build"
            case let .failed(status, message):
                let detail = message.isEmpty ? "no message" : message
                return "LilyPond stopped with status \(status): \(detail)"
            case .nothingWritten:
                return "LilyPond finished without writing a page"
            }
        }
    }

    /// Engraves an already-cut score: the eval and the sheet panel engrave
    /// once and keep the score they measured.
    static func write(score: Score, metadata: LilyPondScore.Metadata = LilyPondScore.Metadata(),
                      to destination: URL) throws {
        guard let wrapper = wrapperURL else { throw EngravingError.notStaged }
        try write(source: LilyPondScore.text(score, metadata: metadata),
                  wrapper: wrapper, to: destination)
    }

    /// The framing a take argues for, so the session MIDI, the printed page
    /// and the panel all speak of the same tempo, meter and key.
    static func framing(notes: [NoteEvent], options: SheetDraft.Options) -> ScoreFraming {
        ScoreFraming(beatsPerMinute: options.bpm,
                     timeSignature: TimeSignature(beatsPerMeasure: options.numerator,
                                                  beatUnit: options.denominator),
                     key: Engraver.inferKey(notes))
    }

    /// Engraves one score to a PDF at `destination`.
    static func write(notes: [NoteEvent], options: SheetDraft.Options,
                      title: String, composer: String?,
                      pedals: [(start: Double, end: Double)] = [],
                      to destination: URL) throws {
        guard let wrapper = wrapperURL else { throw EngravingError.notStaged }
        guard let score = Engraver.engrave(notes: notes,
                                           framing: framing(notes: notes, options: options),
                                           pedals: pedals) else {
            throw EngravingError.nothingWritten
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        var metadata = LilyPondScore.Metadata(title: title, composer: composer)
        metadata.tagline = version.map { "engraved by LilyPond for Cadenza \($0)" }
        try write(source: LilyPondScore.text(score, metadata: metadata),
                  wrapper: wrapper, to: destination)
    }

    /// The process itself: a scratch directory, the .ly file, and the PDF the
    /// cairo backend writes. Ghostscript is not used — the bundled libraries
    /// produce PDF directly, which is also what keeps the bundle at 42 MB.
    static func write(source: String, wrapper: URL, to destination: URL) throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadenza-engrave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let lyric = scratch.appendingPathComponent("score.ly")
        try source.write(to: lyric, atomically: true, encoding: .utf8)
        let base = scratch.appendingPathComponent("score")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [wrapper.path, "-dbackend=cairo", "-o", base.path, lyric.path]
        // LilyPond writes a font cache under HOME and temporary .ps files under
        // TMPDIR; both point into the scratch directory so nothing is left on
        // the machine and nothing needs the user's home to be writable.
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = scratch.path
        environment["TMPDIR"] = scratch.path
        environment["LANG"] = "en_US.UTF-8"
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        // Draining before waiting keeps a chatty engraver from filling the pipe
        // and blocking forever on a run that would otherwise finish.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw EngravingError.failed(status: process.terminationStatus,
                                        message: tail(of: output, lines: 4))
        }
        let produced = scratch.appendingPathComponent("score.pdf")
        guard FileManager.default.fileExists(atPath: produced.path) else {
            throw EngravingError.nothingWritten
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: produced, to: destination)
    }

    private static func tail(of text: String, lines count: Int) -> String {
        let all = text.split(separator: "\n").map(String.init)
        return all.suffix(count).joined(separator: " · ")
    }
}
