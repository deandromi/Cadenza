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
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // the practice screen is a paper world: it renders in light mode,
        // the way the approved drafts read (the theme keeps its dark
        // palette for the day the app follows the system again)
        NSApplication.shared.appearance = NSAppearance(named: .aqua)

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

        engine.$sheet
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.screen?.setChord(self?.engine.currentChord?.symbol)
            }
            .store(in: &cancellables)

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

        let screen = PracticeScreenView(transport: makeTransport())
        root.addSubview(screen)
        NSLayoutConstraint.activate([
            screen.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            screen.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            screen.topAnchor.constraint(equalTo: root.topAnchor),
            screen.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        self.screen = screen
        return root
    }

    /// The panel's actions, carried up to the shell. Weak captures keep the
    /// screen's subtree from closing a cycle back onto the shell.
    private func makeTransport() -> PanelTransport {
        PanelTransport(
            isListening: { [weak self] in self?.engine.isRunning ?? false },
            toggleListening: { [weak self] in self?.toggleListening() },
            exportEnabled: { [weak self] in !(self?.engine.notes.isEmpty ?? true) },
            export: { [weak self] in self?.exportMIDI() }
        )
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
        } else {
            guard let assets = Self.locateAssets() else {
                present(error: "Model files not found next to the app")
                return
            }
            engine.start(tensorsDir: assets.tensors, modelURL: assets.model)
            screen?.sessionStarted()
            screen?.syncTransport()
        }
        present(error: engine.lastError)
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

    private func present(error: String?) {
        if let error, !error.isEmpty {
            screen?.setStatus(error, error: true)
        } else {
            screen?.setStatus("", error: false)
        }
    }

    /// Finds the model assets by walking up from the executable (release app
    /// bundle) or the working directory (swift run).
    nonisolated static func locateAssets() -> (tensors: URL, model: URL)? {
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
                let fileManager = FileManager.default
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
