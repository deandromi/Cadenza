import AppKit
import CadenzaCore
import Combine
import UniformTypeIdentifiers

/// App shell: the chord sheet fills the window and a floating glass toolbar
/// carries the controls.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var sheetView: ChordSheetView?
    private var startButton: NSButton?
    private var statusLabel: NSTextField?
    private var glassBar: NSGlassEffectView?

    private let publisher = MIDIPublisher()
    private let engine = TranscriptionEngine()
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        publisher.setup()
        engine.onNoteEvent = { [weak self] event, kind in
            guard let self else { return }
            switch kind {
            case .struck:
                self.publisher.noteStruck(event)
            case .extended:
                break
            case .released:
                self.publisher.noteReleased(event)
            }
        }

        let size = NSSize(width: 780, height: 560)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cadenza"
        window.minSize = NSSize(width: 560, height: 380)
        window.contentView = makeContent(size: size)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        self.window = window

        engine.$sheet
            .receive(on: RunLoop.main)
            .sink { [weak self] sheet in
                self?.sheetView?.update(sheet: sheet, current: self?.engine.currentChord)
            }
            .store(in: &cancellables)

        engine.$lastError
            .receive(on: RunLoop.main)
            .sink { [weak self] error in
                self?.refreshStatus(error: error)
            }
            .store(in: &cancellables)

        engine.$noteCount
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshStatus(error: self?.engine.lastError)
            }
            .store(in: &cancellables)
        refreshStatus(error: nil)
    }

    private func makeContent(size: NSSize) -> NSView {
        let root = GradientBackgroundView(frame: NSRect(origin: .zero, size: size))
        root.autoresizingMask = [.width, .height]

        let sheet = ChordSheetView(frame: root.bounds)
        root.addSubview(sheet)
        NSLayoutConstraint.activate([
            sheet.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sheet.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sheet.topAnchor.constraint(equalTo: root.topAnchor),
            sheet.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        sheetView = sheet

        let bar = makeGlassBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
        ])

        return root
    }

    private func makeGlassBar() -> NSGlassEffectView {
        let startButton = NSButton(title: "Start listening", target: self, action: #selector(toggleListening))
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = " "
        self.startButton = startButton

        let exportButton = NSButton(title: "Export MIDI", target: self, action: #selector(exportMIDI))
        exportButton.bezelStyle = .rounded

        let status = NSTextField(labelWithString: assetsStatusPlaceholder)
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel = status

        let stack = NSStackView(views: [startButton, exportButton, status])
        stack.orientation = .horizontal
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)

        let glass = NSGlassEffectView()
        glass.cornerRadius = 26
        glass.style = .regular
        if #available(macOS 27.0, *) {
            glass.effectIsInteractive = true
        }
        glass.contentView = stack
        glassBar = glass
        return glass
    }

    private var assetsStatusPlaceholder: String { "Ready" }

    private func refreshStatus(error: String?) {
        guard let statusLabel else { return }
        if let error, !error.isEmpty {
            statusLabel.stringValue = error
            statusLabel.textColor = .systemRed
            glassBar?.tintColor = NSColor.systemRed.withAlphaComponent(0.18)
        } else if engine.isRunning {
            statusLabel.stringValue = "Listening, \(engine.noteCount) notes so far"
            statusLabel.textColor = .secondaryLabelColor
            glassBar?.tintColor = NSColor.systemGreen.withAlphaComponent(0.12)
        } else {
            statusLabel.stringValue = "Ready"
            statusLabel.textColor = .secondaryLabelColor
            glassBar?.tintColor = nil
        }
    }

    @objc private func toggleListening() {
        if engine.isRunning {
            engine.stop()
            publisher.panic()
            startButton?.title = "Start listening"
        } else {
            guard let assets = Self.locateAssets() else {
                refreshStatus(error: "Model files not found next to the app")
                return
            }
            engine.start(tensorsDir: assets.tensors, modelURL: assets.model)
            startButton?.title = "Stop listening"
        }
        refreshStatus(error: engine.lastError)
    }

    @objc private func exportMIDI() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.midi]
        panel.nameFieldStringValue = "Cadenza session"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try MidiFileWriter.write(self.engine.notes, to: url)
                self.statusLabel?.stringValue = "Saved \(url.lastPathComponent)"
            } catch {
                self.refreshStatus(error: error.localizedDescription)
            }
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

/// Backdrop the glass lenses float over.
final class GradientBackgroundView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        autoresizingMask = [.width, .height]
        guard let layer else { return }
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        let dark = window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let gradient = CAGradientLayer()
        gradient.frame = bounds
        gradient.colors = dark
            ? [NSColor.quaternarySystemFill.cgColor, NSColor.windowBackgroundColor.cgColor]
            : [NSColor.controlBackgroundColor.cgColor, NSColor.windowBackgroundColor.cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        layer.addSublayer(gradient)
    }
}
