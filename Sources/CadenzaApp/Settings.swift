import AppKit
import CoreAudio

/// UserDefaults keys for the settings window.
enum SettingsKeys {
    static let sessionDirectoryPath = "sessionDirectory"
    static let keepAudioKey = "keepRecordedAudio"
    static let tuningA4Key = "tuningA4"
    static let inputGainKey = "inputGain"
    static let inputDeviceIDKey = "inputDeviceID"

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

    /// The piano's A4 in Hz, 440 by default; the transcription input is
    /// pitch-normalized to this reference.
    static var tuningA4: Double {
        let value = UserDefaults.standard.double(forKey: tuningA4Key)
        return value > 0 ? value : 440.0
    }

    /// Input gain applied to the tap, 1.0 by default.
    static var inputGain: Float {
        let value = UserDefaults.standard.float(forKey: inputGainKey)
        return value > 0 ? value : 1.0
    }

    /// CoreAudio device id of the chosen input; 0 means the system default.
    static var inputDeviceID: UInt32 {
        UInt32(UserDefaults.standard.integer(forKey: inputDeviceIDKey))
    }
}

/// Every CoreAudio device that can feed the engine, for the input picker.
enum InputDevices {
    struct Device {
        let id: UInt32
        let name: String
    }

    static func all() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        var devices: [Device] = []
        for id in ids {
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamAddress, 0, nil, &streamSize) == noErr, streamSize > 0 else { continue }
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var nameSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &nameAddress, 0, nil, &nameSize) == noErr else { continue }
            var name: CFString? = nil
            guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr, let name else { continue }
            let device = Device(id: id, name: name as String)
            if !devices.contains(where: { $0.id == device.id }) {
                devices.append(device)
            }
        }
        return devices
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
    private let devicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var deviceChoices: [InputDevices.Device] = []
    private let gainSlider = NSSlider(value: Double(SettingsKeys.inputGain), minValue: 0.5, maxValue: 4, target: nil, action: nil)
    private let gainCaption = makeInkLabel(
        "Input gain · ×\(String(format: "%.1f", SettingsKeys.inputGain))",
        font: .systemFont(ofSize: 11, weight: .medium), color: PaperTheme.secondaryInk)
    private let tuningField = NSTextField(string: String(Int(SettingsKeys.tuningA4)))
    /// Called after the session directory changed so the app shell can point
    /// the session store at the new folder.
    var onSessionDirectoryChanged: ((URL) -> Void)?

    func show(relativeTo parent: NSWindow?) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let size = NSSize(width: 420, height: 396)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        // the controller owns this window; AppKit releasing it on close
        // as well would leave a dangling reference behind
        window.isReleasedWhenClosed = false
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

        deviceChoices = InputDevices.all()
        devicePopup.addItems(withTitles: ["System default"])
        for device in deviceChoices {
            devicePopup.addItem(withTitle: device.name)
        }
        let storedID = SettingsKeys.inputDeviceID
        if storedID != 0, let index = deviceChoices.firstIndex(where: { $0.id == storedID }) {
            devicePopup.selectItem(at: index + 1)
        }
        devicePopup.font = .systemFont(ofSize: 13, weight: .regular)
        devicePopup.target = self
        devicePopup.action = #selector(deviceChosen)

        gainSlider.target = self
        gainSlider.action = #selector(gainChanged)
        gainSlider.translatesAutoresizingMaskIntoConstraints = false
        gainSlider.widthAnchor.constraint(equalToConstant: 240).isActive = true

        tuningField.font = .systemFont(ofSize: 13, weight: .regular)
        tuningField.target = self
        tuningField.action = #selector(tuningCommitted)
        tuningField.widthAnchor.constraint(equalToConstant: 64).isActive = true

        func settingRow(_ caption: NSView, _ control: NSView, accessory: NSView? = nil) -> NSStackView {
            let row = NSStackView(views: [caption, control])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 12
            if let accessory {
                row.addArrangedSubview(accessory)
                row.setCustomSpacing(2, after: caption)
            }
            return row
        }

        let deviceRow = settingRow(caption("Input device"), devicePopup)
        let tuningRow = settingRow(caption("Tuning A4, Hz"), tuningField)
        let tuningNote = makeInkLabel(
            "The standard 440 matches most pianos",
            font: .systemFont(ofSize: 11, weight: .regular), color: PaperTheme.secondaryInk)
        let gainRow = settingRow(caption("Gain"), gainSlider, accessory: gainCaption)

        rows.addArrangedSubview(directoryRow)
        rows.addArrangedSubview(keepAudioCheckbox)
        rows.addArrangedSubview(deviceRow)
        rows.addArrangedSubview(gainRow)
        rows.addArrangedSubview(tuningRow)
        rows.addArrangedSubview(tuningNote)

        // the build's version, straight from the bundle so it can never
        // drift from the release it shipped in
        let versionText = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let versionLabel = makeInkLabel(
            "Cadenza \(versionText)",
            font: .systemFont(ofSize: 11, weight: .regular),
            color: PaperTheme.secondaryInk)
        rows.addArrangedSubview(versionLabel)

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

    /// The engine reads the stored device when capture starts; nothing needs
    /// restarting here.
    @objc private func deviceChosen() {
        let index = devicePopup.indexOfSelectedItem
        let id = index >= 1 && index - 1 < deviceChoices.count
            ? deviceChoices[index - 1].id
            : 0
        UserDefaults.standard.set(Int(id), forKey: SettingsKeys.inputDeviceIDKey)
    }

    @objc private func gainChanged() {
        let value = gainSlider.floatValue
        UserDefaults.standard.set(value, forKey: SettingsKeys.inputGainKey)
        gainCaption.stringValue = "Input gain · ×\(String(format: "%.1f", value))"
    }

    /// Tuning is clamped to a sane range; an unusable value falls back to
    /// 440 Hz without removing the user's text.
    @objc private func tuningCommitted() {
        let value = tuningField.doubleValue
        if value >= 380, value <= 520 {
            UserDefaults.standard.set(value, forKey: SettingsKeys.tuningA4Key)
        } else {
            UserDefaults.standard.set(440.0, forKey: SettingsKeys.tuningA4Key)
        }
    }
}
