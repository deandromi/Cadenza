import AppKit
import CadenzaCore
import Combine
import UniformTypeIdentifiers

/// App shell: the paper practice screen fills the window, its panel lens
/// carrying the transport, the engine and the MIDI publisher wired beneath.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var screen: PracticeScreenView?

    private let publisher = MIDIPublisher()
    private let engine = TranscriptionEngine()
    private let store = SessionStore()
    private var sheetController: SheetMusicController?
    private var cancellables: Set<AnyCancellable> = []
    private var sessionStartedAt: Date?
    private var playbackTask: Task<Void, Never>?
    private var playingRecord: SessionRecord?
    private var playbackCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // the practice screen is a paper world: it renders in light mode,
        // the way the approved drafts read (the theme keeps its dark
        // palette for the day the app follows the system again)
        NSApplication.shared.appearance = NSAppearance(named: .aqua)

        // the notation font for the sheet music section
        MusicFont.register()

        publisher.setup()
        engine.onNoteEvent = { [weak self] event, kind in
            guard let self else { return }
            switch kind {
            case .struck:
                self.publisher.noteStruck(event)
                self.screen?.noteStruck(event)
            case .extended:
                break
            case .released:
                self.publisher.noteReleased(event)
                self.screen?.noteReleased(event)
            }
            self.sheetController?.sync(notes: self.engine.notes)
        }

        let size = NSSize(width: 1080, height: 720)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cadenza"
        window.minSize = NSSize(width: 900, height: 620)
        window.contentView = makeContent(size: size)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        self.window = window

        engine.$lastError
            .receive(on: RunLoop.main)
            .sink { [weak self] error in
                self?.present(error: error)
            }
            .store(in: &cancellables)

        engine.$noteCount
            .receive(on: RunLoop.main)
            .sink { [weak self] count in
                self?.screen?.setNoteCount(count)
            }
            .store(in: &cancellables)
    }

    private func makeContent(size: NSSize) -> NSView {
        // the window's content is a frame-driven root with autoresizing:
        // a constraint-pinned content view breaks the deeper layout passes
        // on this OS build
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.autoresizingMask = [.width, .height]

        let screen = PracticeScreenView(
            transport: makeTransport(),
            onSheetMusic: { [weak self] in self?.openSheetMusic() }
        )
        root.addSubview(screen)
        NSLayoutConstraint.activate([
            screen.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            screen.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            screen.topAnchor.constraint(equalTo: root.topAnchor),
            screen.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        self.screen = screen
        refreshSessions()
        return root
    }

    /// The panel's actions, carried up to the shell. Weak captures keep the
    /// screen's subtree from closing a cycle back onto the shell.
    private func makeTransport() -> PanelTransport {
        PanelTransport(
            isListening: { [weak self] in self?.engine.isRunning ?? false },
            toggleListening: { [weak self] in self?.toggleListening() },
            exportEnabled: { [weak self] in !(self?.engine.notes.isEmpty ?? true) },
            export: { [weak self] in self?.exportMIDI() },
            playSession: { [weak self] record in self?.togglePlayback(of: record) },
            playingSession: { [weak self] in self?.playingRecord }
        )
    }

    /// The archive lands on the panel after every change, with whoever is
    /// playing carrying the stamp.
    private func refreshSessions() {
        screen?.setSessions(store.sessions, playing: playingRecord)
    }

    // MARK: transport actions

    /// One action: it starts the session that listens, plays out as MIDI,
    /// and is what export hands over, and it stops that session again.
    private func toggleListening() {
        if engine.isRunning {
            engine.stop()
            publisher.panic()
            screen?.sessionStopped()
            screen?.syncTransport()
            sheetController?.sessionEnded()
            if let startedAt = sessionStartedAt {
                let record = store.saveSession(
                    notes: engine.notes,
                    startedAt: startedAt,
                    durationSeconds: Date().timeIntervalSince(startedAt))
                if record != nil {
                    screen?.setStatus("Saved session to the archive", error: false)
                }
            }
            sessionStartedAt = nil
            refreshSessions()
        } else {
            stopPlayback()
            guard let assets = Self.locateAssets() else {
                present(error: "Model files not found next to the app")
                return
            }
            engine.start(tensorsDir: assets.tensors, modelURL: assets.model)
            sessionStartedAt = Date()
            screen?.sessionStarted()
            screen?.syncTransport()
            sheetController?.reset()
        }
        present(error: engine.lastError)
    }

    // MARK: session playback

    /// Plays a preserved session through the live MIDI path, the keybed and
    /// the endless measure dancing along; a second press stops it.
    private func togglePlayback(of record: SessionRecord) {
        if playingRecord?.id == record.id {
            stopPlayback()
            refreshSessions()
            return
        }
        guard !engine.isRunning else {
            present(error: "Stop listening before playing a session")
            return
        }
        stopPlayback()
        guard let notes = store.notes(for: record) else {
            present(error: "Couldn't read the session file")
            return
        }
        playingRecord = record
        refreshSessions()
        playbackCount = 0
        screen?.sessionStopped()
        playbackTask = Task { [weak self] in
            var previous = 0.0
            for note in notes.sorted(by: { $0.onset < $1.onset }) {
                let wait = max(0, note.onset - previous)
                previous = note.onset
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }
                self?.playbackCount += 1
                self?.publisher.noteStruck(note)
                self?.screen?.noteStruck(note)
                self?.screen?.setNoteCount(self?.playbackCount ?? 0)
                let held = note
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(max(held.duration, 0.05) * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self?.publisher.noteReleased(held)
                    self?.screen?.noteReleased(held)
                }
            }
            // let the last note ring, then hand the keys back
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.stopPlayback()
            self?.refreshSessions()
        }
    }

    private func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        if playingRecord != nil {
            publisher.panic()
        }
        playingRecord = nil
        screen?.sessionStopped()
    }

    private func exportMIDI() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.midi]
        panel.nameFieldStringValue = "Cadenza session"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try MidiFileWriter.write(self.engine.notes, to: url)
                self.screen?.setStatus("Saved \(url.lastPathComponent)", error: false)
            } catch {
                self.present(error: error.localizedDescription)
            }
        }
    }

    // MARK: sheet music

    /// Opens the sheet section on the current session: the choices step
    /// frames the performance, then the engraver cuts it into measures.
    private func openSheetMusic() {
        if let controller = sheetController, controller.isOpen {
            controller.show(relativeTo: window)
            controller.sync(notes: engine.notes)
            return
        }
        let controller = SheetMusicController(notes: engine.notes)
        sheetController = controller
        controller.show(relativeTo: window)
    }

    private func present(error: String?) {
        if let error, !error.isEmpty {
            screen?.setStatus(error, error: true)
        } else {
            screen?.setStatus("", error: false)
        }
    }

    /// Finds the model assets: first inside the app bundle's resources, then
    /// by walking up from the executable or the working directory (swift run
    /// from the repo checkout).
    nonisolated static func locateAssets() -> (tensors: URL, model: URL)? {
        let fileManager = FileManager.default
        if let resources = Bundle.main.resourceURL {
            let tensors = resources.appendingPathComponent("Models/tensors", isDirectory: true)
            let model = resources.appendingPathComponent("Models/TranskunBackbone.mlpackage", isDirectory: true)
            if fileManager.fileExists(atPath: tensors.path), fileManager.fileExists(atPath: model.path) {
                return (tensors, model)
            }
        }
        var roots: [URL] = []
        if let executable = Bundle.main.executableURL {
            roots.append(executable.deletingLastPathComponent())
        }
        roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
        for root in roots {
            var dir = root
            for _ in 0..<6 {
                let tensors = dir.appendingPathComponent("Models/tensors", isDirectory: true)
                let model = dir.appendingPathComponent("Models/TranskunBackbone.mlpackage", isDirectory: true)
                if fileManager.fileExists(atPath: tensors.path), fileManager.fileExists(atPath: model.path) {
                    return (tensors, model)
                }
                dir = dir.deletingLastPathComponent()
            }
        }
        return nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        if engine.isRunning {
            engine.stop()
            publisher.panic()
        }
    }
}
