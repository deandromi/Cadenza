import AppKit

/// UserDefaults keys for the settings window.
enum SettingsKeys {
    static let sessionDirectoryPath = "sessionDirectory"
    static let keepAudioKey = "keepRecordedAudio"

    static var sessionDirectory: URL? {
        guard let path = UserDefaults.standard.string(forKey: sessionDirectoryPath) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var keepRecordedAudio: Bool {
        // default: keep audio, unless the user opted out before
        UserDefaults.standard.object(forKey: keepAudioKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: keepAudioKey)
    }
}

/// The settings section: a small paper window with a glass control for the
/// session directory and the keep-recorded-audio preference.
@MainActor
final class SettingsController: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let directoryLabel = makeInkLabel(
        SettingsKeys.sessionDirectory?.path ?? SessionStore.defaultDirectory.path,
        font: .systemFont(ofSize: 12, weight: .regular),
        color: PaperTheme.secondaryInk
    )
    private let keepAudioCheckbox = NSButton(checkboxWithTitle: "Keep recorded audio", target: nil, action: nil)
    /// Called after the session directory changed so the app shell can point
    /// the session store at the new folder.
    var onSessionDirectoryChanged: ((URL) -> Void)?

    func show(relativeTo parent: NSWindow?) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let size = NSSize(width: 420, height: 210)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentView = makeContent(size: size)
        if let parent {
            let frame = window.frame
            window.setFrameOrigin(NSPoint(
                x: parent.frame.midX - frame.width / 2,
                y: parent.frame.midY - frame.height / 2
            ))
        }
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    private func makeContent(size: NSSize) -> NSView {
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.autoresizingMask = [.width, .height]
        let paper = PaperView()
        paper.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(paper)

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 16
        rows.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)
        rows.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(rows)

        func caption(_ text: String) -> NSView {
            makeInkLabel(text, font: .systemFont(ofSize: 11, weight: .medium), color: PaperTheme.secondaryInk)
        }

        let directoryRow = NSStackView()
        directoryRow.orientation = .vertical
        directoryRow.alignment = .leading
        directoryRow.spacing = 6
        directoryLabel.translatesAutoresizingMaskIntoConstraints = false
        directoryLabel.lineBreakMode = .byTruncatingMiddle
        directoryLabel.maximumNumberOfLines = 1
        let chooseButton = NSButton(title: "Choose…", target: self, action: #selector(chooseDirectory))
        chooseButton.isBordered = false
        chooseButton.font = .systemFont(ofSize: 13, weight: .medium)
        chooseButton.contentTintColor = PaperTheme.ink
        let choosePill = padForLens(chooseButton, horizontal: 16, vertical: 9)
        choosePill.translatesAutoresizingMaskIntoConstraints = false
        let chooseBackdrop = makeGlassBackdrop(cornerRadius: 16, interactive: true)
        chooseBackdrop.translatesAutoresizingMaskIntoConstraints = false
        choosePill.addSubview(chooseBackdrop)
        choosePill.addSubview(chooseButton)
        NSLayoutConstraint.activate([
            chooseBackdrop.leadingAnchor.constraint(equalTo: choosePill.leadingAnchor),
            chooseBackdrop.trailingAnchor.constraint(equalTo: choosePill.trailingAnchor),
            chooseBackdrop.topAnchor.constraint(equalTo: choosePill.topAnchor),
            chooseBackdrop.bottomAnchor.constraint(equalTo: choosePill.bottomAnchor),
            chooseButton.leadingAnchor.constraint(equalTo: choosePill.leadingAnchor),
            chooseButton.trailingAnchor.constraint(equalTo: choosePill.trailingAnchor),
            chooseButton.topAnchor.constraint(equalTo: choosePill.topAnchor),
            chooseButton.bottomAnchor.constraint(equalTo: choosePill.bottomAnchor),
        ])
        directoryRow.addArrangedSubview(caption("Session directory"))
        directoryRow.addArrangedSubview(directoryLabel)
        directoryRow.addArrangedSubview(choosePill)

        keepAudioCheckbox.isBordered = false
        keepAudioCheckbox.font = .systemFont(ofSize: 13, weight: .regular)
        keepAudioCheckbox.contentTintColor = PaperTheme.ink
        keepAudioCheckbox.target = self
        keepAudioCheckbox.action = #selector(toggleKeepAudio)
        keepAudioCheckbox.state = SettingsKeys.keepRecordedAudio ? .on : .off

        rows.addArrangedSubview(directoryRow)
        rows.addArrangedSubview(keepAudioCheckbox)

        NSLayoutConstraint.activate([
            paper.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            paper.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            paper.topAnchor.constraint(equalTo: root.topAnchor),
            paper.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            rows.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            rows.topAnchor.constraint(equalTo: root.topAnchor),
        ])
        return root
    }

    @objc private func chooseDirectory() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = SettingsKeys.sessionDirectory ?? SessionStore.defaultDirectory
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            UserDefaults.standard.set(url.path, forKey: SettingsKeys.sessionDirectoryPath)
            directoryLabel.stringValue = url.path
            onSessionDirectoryChanged?(url)
        }
    }

    @objc private func toggleKeepAudio() {
        UserDefaults.standard.set(keepAudioCheckbox.state == .on, forKey: SettingsKeys.keepAudioKey)
    }
}
