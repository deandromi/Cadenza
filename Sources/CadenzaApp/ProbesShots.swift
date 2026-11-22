import AppKit
import AVFoundation
import CadenzaCore
import UniformTypeIdentifiers
import CoreML
import Foundation
import CoreText

extension SmokeMain {
/// The screenshot probes: they render the real view tree offscreen so layout
/// and the overlay can be inspected without recording the live app.
    static func rootPath(_ relative: String) -> String {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Models/tensors").path) {
                return dir.appendingPathComponent(relative).path
            }
            dir = dir.deletingLastPathComponent()
        }
        return relative
    }

    /// Feeds the tap ring from a recording in tap-sized chunks, the way the
    /// realtime tap delivers. `fed` tracks how many samples have entered.
    static func feed(_ tapState: AudioTapState, from input: [Float], fed: inout Int, upTo sampleIndex: Int) {
        let target = min(sampleIndex, input.count)
        while fed < target {
            let end = min(fed + 8192, target)
            tapState.append(Array(input[fed..<end]))
            fed = end
        }
    }

    /// Renders the endless measure with a spread of synthetic notes,
    /// offscreen: --strip-shot. The strip is otherwise driven by live
    /// engine events, so this is how its engraving gets inspected.
    static func runStripShot() {
        MainActor.assumeIsolated {
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
            MusicFont.register()
            let strip = EndlessStaffView()
            let size = NSSize(width: 900, height: 240)
            strip.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
            // a chord, a melody, an accidental and a ledger test, oldest first
            for (pitch, age) in [(48, 8.6), (55, 8.5), (72, 6.4), (76, 6.3),
                                 (61, 4.4), (66, 4.3), (70, 2.2), (84, 0.9),
                                 (93, 0.9), (30, 0.4)] {
                strip.noteStruck(pitch: pitch, age: age)
            }
            // flush the timer: draw one frame now
            let scale: CGFloat = 2
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            if let ctx = NSGraphicsContext.current {
                PaperTheme.paper.setFill()
                NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh).fill()
                ctx.cgContext.translateBy(x: 0, y: CGFloat(rep.pixelsHigh))
                ctx.cgContext.scaleBy(x: scale, y: -scale)
                strip.draw(NSRect(x: 0, y: 0, width: size.width, height: size.height))
            }
            NSGraphicsContext.restoreGraphicsState()
            if let cg = rep.cgImage,
               let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "/tmp/cadenza_strip.png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, cg, nil)
                CGImageDestinationFinalize(dest)
                print("strip-shot: wrote /tmp/cadenza_strip.png")
            }
        }
    }

    /// Renders the whole practice screen offscreen - paper, panel, keybed
    /// and the endless measure - exactly as the app composes it, seeded with
    /// synthetic notes: --screen-shot. The live screen can only be judged
    /// in the running app, so this is how its composition is inspected.
    /// Captures frames during the panel's unfold morph, to inspect the
    /// animation geometry offscreen: --morph-shot
    static func runMorphShot() {
        MainActor.assumeIsolated {
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
            MusicFont.register()
            let size = NSSize(width: 1080, height: 660)
            let screen = PracticeScreenView(
                shell: PreviewShell(listening: true, exporting: true),
                onSheetMusic: {}
            )
            screen.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
            screen.setSessions([
                SessionRecord(id: UUID(), name: nil, folderName: "Session 1", startedAt: Date().addingTimeInterval(-3600), durationSeconds: 96, noteCount: 214, hasAudio: true),
                SessionRecord(id: UUID(), name: nil, folderName: "Session 2", startedAt: Date().addingTimeInterval(-7200), durationSeconds: 41, noteCount: 88, hasAudio: false),
            ], playing: nil)
            screen.setNoteCount(12)
            screen.sessionStarted()
            screen.syncTransport()
            screen.layoutSubtreeIfNeeded()
            let scale: CGFloat = 1
            func snap(_ name: String) {
                MainActor.assumeIsolated {
                    screen.layoutSubtreeIfNeeded()
                    let rep = NSBitmapImageRep(
                        bitmapDataPlanes: nil,
                        pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    rep.size = size
                    screen.cacheDisplay(in: screen.bounds, to: rep)
                    if let cg = rep.cgImage,
                       let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "/tmp/morph_\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
                        CGImageDestinationAddImage(dest, cg, nil)
                        CGImageDestinationFinalize(dest)
                    }
                    print("morph-shot: \(name)")
                }
            }
            snap("0_start")
            screen.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.12))
            snap("1_mid")
            RunLoop.main.run(until: Date().addingTimeInterval(0.12))
            snap("2_mid2")
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            snap("3_end")
        }
    }

    static func runScreenShot() {
        MainActor.assumeIsolated {
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
            MusicFont.register()
            let size = NSSize(width: 1080, height: 660)
            let screen = PracticeScreenView(
                shell: PreviewShell(listening: true, exporting: true),
                onSheetMusic: {}
            )
            screen.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
            screen.setSessions([
                SessionRecord(id: UUID(), name: nil, folderName: "Session 1", startedAt: Date().addingTimeInterval(-3600), durationSeconds: 96, noteCount: 214, hasAudio: true),
                SessionRecord(id: UUID(), name: nil, folderName: "Session 2", startedAt: Date().addingTimeInterval(-7200), durationSeconds: 41, noteCount: 88, hasAudio: false),
                SessionRecord(id: UUID(), name: nil, folderName: "Session 3", startedAt: Date().addingTimeInterval(-90000), durationSeconds: 154, noteCount: 531, hasAudio: true),
            ], playing: nil)
            screen.layoutSubtreeIfNeeded()
            screen.setNoteCount(12)
            screen.sessionStarted()
            for (pitch, _) in [(48, 8.6), (55, 8.5), (72, 6.4), (76, 6.3),
                                 (61, 4.4), (66, 4.3), (70, 2.2), (84, 0.9),
                                 (93, 0.9), (30, 0.4)] {
                screen.noteStruck(NoteEvent(pitch: pitch, velocity: 80, onset: 0, duration: 0.5))
            }
            screen.noteReleased(NoteEvent(pitch: 66, velocity: 80, onset: 0, duration: 0.5))
            screen.syncTransport()

            let scale: CGFloat = 2
            screen.layoutSubtreeIfNeeded()
            // the view tree renders through cacheDisplay: the official
            // window-less render of a view and its subviews
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = size
            screen.cacheDisplay(in: NSRect(x: 0, y: 0, width: size.width, height: size.height), to: rep)
            if let cg = rep.cgImage,
               let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "/tmp/cadenza_screen.png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, cg, nil)
                CGImageDestinationFinalize(dest)
                print("screen-shot: wrote /tmp/cadenza_screen.png")
            }
        }
    }

    /// Proves the menu bar really carries the section shortcuts: builds the
    /// same menu the app installs and asks it to handle each key equivalent.
    static func runMenuCheck() {
        MainActor.assumeIsolated {
            NSApplication.shared.setActivationPolicy(.regular)
            let delegate = AppDelegate()
            delegate.installMainMenu()
            guard let menu = NSApplication.shared.mainMenu else {
                print("menu-check: no main menu")
                return
            }
            func titlePath() -> String {
                menu.items.compactMap { $0.submenu?.items }
                    .flatMap { $0 }
                    .map { "\($0.title) [\($0.keyEquivalent)]" }
                    .joined(separator: ", ")
            }
            print("menu-check: \(titlePath())")
            for key in ["1", "2", "3", "4"] {
                guard let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [.command],
                    timestamp: 0, windowNumber: 0, context: nil,
                    characters: key, charactersIgnoringModifiers: key, isARepeat: false,
                    keyCode: 0
                ) else { continue }
                let handled = menu.performKeyEquivalent(with: event)
                print("menu-check: command-\(key) handled=\(handled)")
            }
        }
    }

    /// Opens the sheet section exactly the way the home screen does, with a
    /// real session, and reports whether the card survived: the failure this
    /// guards against closes the card the moment it appears.
    /// Prints the description of the newest archived take: proof that the
    /// description path reads a real MIDI off disk. Run with
    /// `--describe-latest`.
    @MainActor
    static func runDescribeLatest() {
        let defaults = UserDefaults.standard.string(forKey: SettingsKeys.sessionDirectoryPath)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let directory = defaults ?? documents.appendingPathComponent("Cadenza", isDirectory: true)
        let store = SessionStore(directory: directory)
        guard let newest = store.sessions.first else {
            print("describe-latest: no sessions in \(directory.path)")
            return
        }
        guard let notes = store.notes(for: newest), let described = TakeAnalysis.describe(notes: notes) else {
            print("describe-latest: no notes for \(newest.label)")
            return
        }
        print("describe-latest: \(newest.label)")
        print("describe-latest: \(described.summary)")
        for line in described.lines {
            print("describe-latest:   \(line.caption) · \(line.value)")
        }
    }

    /// Exercises the archive on disk    /// Exercises the archive on disk: a session is saved, renamed (folder,
    /// MIDI, WAV and sheet PDF follow the name) and deleted, with the index
    /// checked at every step. Run with `--sessions-probe`.
    @MainActor
    static func runSessionsProbe() {
        let root = URL(fileURLWithPath: "/tmp/cadenza-sessions-probe", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = SessionStore(directory: root)
        let notes = [NoteEvent(pitch: 60, velocity: 90, onset: 0, duration: 1)]
        guard let saved = store.saveSession(notes: notes, startedAt: Date(), durationSeconds: 2) else {
            print("sessions-probe: save failed")
            return
        }
        let folder = store.folderURL(for: saved)
        let wav = folder.appendingPathComponent("audio.wav")
        try? WavWriter.write([0.1, 0.2], rate: 44_100, to: wav)
        print("sessions-probe: saved \(folder.lastPathComponent), midi=\(FileManager.default.fileExists(atPath: store.midiURL(for: saved).path))")

        guard let renamed = store.rename(saved, to: "Nocturne in C sharp minor") else {
            print("sessions-probe: rename failed")
            return
        }
        let renamedFolder = store.folderURL(for: renamed)
        let listing = (try? FileManager.default.contentsOfDirectory(atPath: renamedFolder.path))?
            .sorted().joined(separator: ", ") ?? "?"
        print("sessions-probe: renamed folder=\(renamedFolder.lastPathComponent) files=[\(listing)] index=\(store.sessions.count)")
        print("sessions-probe: midi resolves=\(FileManager.default.fileExists(atPath: store.midiURL(for: renamed).path)), audio resolves=\(FileManager.default.fileExists(atPath: store.audioURL(for: renamed).path))")

        store.delete(renamed)
        let gone = !FileManager.default.fileExists(atPath: renamedFolder.path)
        print("sessions-probe: deleted folderGone=\(gone) index=\(store.sessions.count)")
    }

    /// Renders the in-window sections — the archive and the settings card —
    /// into PNGs through the real overlay host, so layout and the overlay
    /// glass can be inspected without a screen recording of the live app.
    static func runOverlayShot() {
        MainActor.assumeIsolated {
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
            MusicFont.register()
            let size = NSSize(width: 1080, height: 660)
            let shell = PreviewShell(listening: true, exporting: true)
            let screen = PracticeScreenView(shell: shell, onSheetMusic: {})
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = screen
            screen.frame = NSRect(origin: .zero, size: size)
            let sessions = [
                SessionRecord(id: UUID(), name: "Chopin, wrong notes", folderName: "Session 1", startedAt: Date().addingTimeInterval(-3600), durationSeconds: 96, noteCount: 214, hasAudio: true),
                SessionRecord(id: UUID(), name: nil, folderName: "Session 2", startedAt: Date().addingTimeInterval(-7200), durationSeconds: 41, noteCount: 88, hasAudio: false),
                SessionRecord(id: UUID(), name: nil, folderName: "Session 3", startedAt: Date().addingTimeInterval(-90000), durationSeconds: 154, noteCount: 531, hasAudio: true),
                SessionRecord(id: UUID(), name: "Late night take", folderName: "Session 4", startedAt: Date().addingTimeInterval(-180000), durationSeconds: 302, noteCount: 811, hasAudio: true),
                SessionRecord(id: UUID(), name: nil, folderName: "Session 5", startedAt: Date().addingTimeInterval(-260000), durationSeconds: 74, noteCount: 190, hasAudio: false),
                SessionRecord(id: UUID(), name: nil, folderName: "Session 6", startedAt: Date().addingTimeInterval(-300000), durationSeconds: 55, noteCount: 120, hasAudio: true),
            ]
            screen.setSessions(sessions, playing: sessions[1])
            screen.layoutSubtreeIfNeeded()

            writeShot(of: screen, size: size, name: "home")
            let archive = SessionsOverlayView(shell: shell,
                                              sessions: sessions,
                                              playing: sessions[1])
            screen.presentOverlay(archive, size: NSSize(width: 620, height: 130 + CGFloat(sessions.count) * 47 + 20))
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            writeShot(of: screen, size: size, name: "sessions")
            screen.dismissOverlay(animated: false)

            let settings = SettingsController().overlayContent()
            screen.presentOverlay(settings, size: NSSize(width: 460, height: 430))
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            writeShot(of: screen, size: size, name: "settings")
            screen.dismissOverlay(animated: false)

            let stats = StatsController().overlayContent(sessions: sessions)
            screen.presentOverlay(stats, size: NSSize(width: 440, height: 300))
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            writeShot(of: screen, size: size, name: "stats")
            screen.dismissOverlay(animated: false)
        }
    }

    /// One offscreen render of a view tree to /tmp, at 2×.
    @MainActor
    static func writeShot(of view: NSView, size: NSSize, name: String) {
        view.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        view.cacheDisplay(in: NSRect(origin: .zero, size: size), to: rep)
        guard let cg = rep.cgImage,
              let dest = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: "/tmp/cadenza_\(name).png") as CFURL,
                UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
        print("overlay-shot: wrote /tmp/cadenza_\(name).png")
    }

    static func readF32(_ url: URL) -> [Float] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }
    }
}
