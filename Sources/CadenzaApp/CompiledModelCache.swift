import CoreML
import Foundation

/// One compiled copy of the backbone, kept where it can be reused.
///
/// `MLModel.compileModel(at:)` writes a fresh `TranskunBackbone_<uuid>.mlmodelc`
/// into the system temp folder on every call and nothing ever removes it. The
/// app builds two decoders at launch, so each start left two copies behind; a
/// few hundred launches filled the disk with 22 GB of identical models.
///
/// Compiling once into the app's own cache, keyed by the package's own
/// modification date, leaves exactly one copy. The sweep afterwards removes
/// the leftovers earlier versions of the app wrote.
enum CompiledModelCache {
    private static let folderName = "CompiledModels"

    /// The compiled model for this package, compiling it once if needed.
    static func prepare(_ package: URL) throws -> URL {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: package.path)[.modificationDate] as? Date)
            .map { Int($0.timeIntervalSince1970) } ?? 0
        let name = package.deletingPathExtension().lastPathComponent
        let folder = cacheFolder.appendingPathComponent("\(name)-\(stamp).mlmodelc", isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) {
            sweepTemporaryCopies()
            return folder
        }

        let fresh = try MLModel.compileModel(at: package)
        try? FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        // One compiled copy per model, not one per version: an app update
        // must not leave the previous build's copy behind.
        prune(name: name, keeping: folder)
        try? FileManager.default.removeItem(at: folder)
        do {
            try FileManager.default.moveItem(at: fresh, to: folder)
        } catch {
            // a cache on another volume cannot be moved onto; copy instead
            try FileManager.default.copyItem(at: fresh, to: folder)
            try? FileManager.default.removeItem(at: fresh)
        }
        sweepTemporaryCopies(keeping: folder)
        return folder
    }

    /// Removes every compiled copy of this model except the one in use.
    private static func prune(name: String, keeping kept: URL) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: cacheFolder,
                                                             includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("\(name)-")
            && entry.standardizedFileURL != kept.standardizedFileURL {
            try? manager.removeItem(at: entry)
        }
    }

    private static var cacheFolder: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("dev.cadenza.Cadenza/\(folderName)", isDirectory: true)
    }

    /// Removes the compiled copies CoreML dropped in the temp folder. They are
    /// ours by name, they hold no state, and reopening the app recompiles one
    /// into the cache in a few seconds.
    private static func sweepTemporaryCopies(keeping kept: URL? = nil) {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory
        guard let entries = try? manager.contentsOfDirectory(at: temporary,
                                                             includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("TranskunBackbone_")
            && entry.pathExtension == "mlmodelc" && entry.standardizedFileURL != kept?.standardizedFileURL {
            try? manager.removeItem(at: entry)
        }
    }
}
