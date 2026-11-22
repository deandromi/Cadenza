import Foundation

/// Everything the app writes outside a session folder, kept small.
///
/// The app writes two things it never asks the player about: a console log it
/// appends to on every launch, and a scratch recording it streams while a
/// session runs. Both are meant to be disposable, so both are cleaned up here
/// rather than left to grow with every start.
enum StorageHygiene {
    /// The log the GUI appends to, so diagnostics can be read however the app
    /// was launched. It is truncated once it passes this size: the log is for
    /// the last run, not for the last year.
    static let logPath = "/tmp/cadenza_gui.log"
    static let logLimit = 1 << 20  // 1 MB

    /// A log file older than one run is not worth keeping, but a log being
    /// written right now is: the size check happens before the app opens it.
    static func rotateLogIfNeeded() {
        let manager = FileManager.default
        guard let size = (try? manager.attributesOfItem(atPath: logPath)[.size] as? NSNumber)?.intValue,
              size > logLimit else { return }
        try? manager.removeItem(atPath: logPath)
    }

    /// Scratch files a previous run left behind when it quit mid-session: the
    /// capture file is rewritten by the next session, but one abandoned
    /// months ago is dead weight. Nothing here is a session; those live in the
    /// session directory and are the player's to keep.
    static func sweepScratch(olderThan age: TimeInterval = 7 * 24 * 3600) {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory
        guard let entries = try? manager.contentsOfDirectory(at: temporary,
                                                             includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for entry in entries where entry.lastPathComponent.hasPrefix("Cadenza") {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if modified < cutoff { try? manager.removeItem(at: entry) }
        }
    }
}
