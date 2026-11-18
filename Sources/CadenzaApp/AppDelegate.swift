import AppKit

/// App shell: chord sheet content with a floating glass toolbar.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var isListening = false
    private var listeningButton: NSButton?
    private var glassBar: NSGlassEffectView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let size = NSSize(width: 780, height: 540)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cadenza"
        window.minSize = size
        window.contentView = makeContent(size: size)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        self.window = window
    }

    private func makeContent(size: NSSize) -> NSView {
        let root = GradientBackgroundView(frame: NSRect(origin: .zero, size: size))
        root.autoresizingMask = [.width, .height]

        let placeholder = NSTextField(labelWithString: "Nothing played yet")
        placeholder.font = .systemFont(ofSize: 28, weight: .light)
        placeholder.textColor = .secondaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])

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
        let listeningButton = NSButton(title: "Start listening", target: self, action: #selector(toggleListening))
        listeningButton.bezelStyle = .rounded
        self.listeningButton = listeningButton

        let exportButton = NSButton(title: "Export MIDI", target: nil, action: nil)
        exportButton.bezelStyle = .rounded

        let stack = NSStackView(views: [listeningButton, exportButton])
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)

        let glass = NSGlassEffectView()
        glass.cornerRadius = 26
        glass.style = .regular
        if #available(macOS 27.0, *) {
            glass.effectIsInteractive = true
        }
        glass.contentView = stack
        self.glassBar = glass
        return glass
    }

    @objc private func toggleListening() {
        isListening.toggle()
        listeningButton?.title = isListening ? "Stop listening" : "Start listening"
        glassBar?.tintColor = isListening ? NSColor.systemRed.withAlphaComponent(0.2) : nil
    }
}

/// Backdrop the glass lenses float over.
final class GradientBackgroundView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        guard let layer,
              window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        else {
            return
        }
        let gradient = CAGradientLayer()
        gradient.frame = bounds
        gradient.colors = [
            NSColor.quaternarySystemFill.cgColor,
            NSColor.windowBackgroundColor.cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        layer.addSublayer(gradient)
        autoresizingMask = [.width, .height]
    }
}
