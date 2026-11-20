import AppKit
import CadenzaCore

/// Top-right glass pill opening the menu of the app's sections. Sheet music
/// is live; the rest stay disabled until those sections exist.
final class MenuLens: NSView {
    private let menuButton = NSButton(title: "Menu", target: nil, action: nil)
    private var pill: NSStackView?
    private var backdrop: NSView?
    private let menuItems = ["Sheet music", "Sessions", "Statistics", "Refresh MIDI port", "Settings"]
    private let onSheetMusic: (() -> Void)?
    private let onStatistics: (() -> Void)?
    private let onRefreshMIDI: (() -> Void)?
    private let onSettings: (() -> Void)?

    init(onSheetMusic: (() -> Void)? = nil, onStatistics: (() -> Void)? = nil,
         onRefreshMIDI: (() -> Void)? = nil, onSettings: (() -> Void)? = nil) {
        self.onSheetMusic = onSheetMusic
        self.onStatistics = onStatistics
        self.onRefreshMIDI = onRefreshMIDI
        self.onSettings = onSettings
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        menuButton.isBordered = false
        menuButton.font = .systemFont(ofSize: 13, weight: .medium)
        menuButton.contentTintColor = PaperTheme.ink
        menuButton.target = self
        menuButton.action = #selector(openMenu)
        // views never mutate before super.init on this OS build: doing so
        // orphans them from the live layout engine
        let newPill = padForLens(menuButton, horizontal: 18, vertical: 12)
        let newBackdrop = makeGlassBackdrop(cornerRadius: 20, interactive: true)
        // on this OS build, pinning a view never auto-disables its
        // autoresizing mask: do it by hand or the view stays at zero
        newPill.translatesAutoresizingMaskIntoConstraints = false
        newBackdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(newBackdrop)
        addSubview(newPill)
        pill = newPill
        backdrop = newBackdrop
        if let pill, let backdrop {
            NSLayoutConstraint.activate([
                backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
                backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
                backdrop.topAnchor.constraint(equalTo: topAnchor),
                backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
                pill.leadingAnchor.constraint(equalTo: leadingAnchor),
                pill.trailingAnchor.constraint(equalTo: trailingAnchor),
                pill.topAnchor.constraint(equalTo: topAnchor),
                pill.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        pill?.fittingSize ?? fittingSize
    }

    @objc private func openMenu() {
        let menu = NSMenu()
        for title in menuItems {
            let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            if title == "Sheet music" {
                item.isEnabled = onSheetMusic != nil
                item.target = self
                item.action = #selector(sheetMusicTapped)
            } else if title == "Statistics" {
                item.isEnabled = onStatistics != nil
                item.target = self
                item.action = #selector(statisticsTapped)
            } else if title == "Refresh MIDI port" {
                // a page that enumerated its MIDI devices when it loaded only
                // notices the port when it comes back: this republishes it,
                // which the browser reports as a device state change
                item.isEnabled = onRefreshMIDI != nil
                item.target = self
                item.action = #selector(refreshMIDITapped)
            } else if title == "Settings" {
                item.isEnabled = onSettings != nil
                item.target = self
                item.action = #selector(settingsTapped)
            } else {
                // items stay disabled: the sections are future work, the
                // menu shows where they will live
                item.isEnabled = false
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: menuButton.bounds.minY - 8), in: menuButton)
    }

    @objc private func sheetMusicTapped() {
        onSheetMusic?()
    }

    @objc private func statisticsTapped() {
        onStatistics?()
    }

    @objc private func refreshMIDITapped() {
        onRefreshMIDI?()
    }

    @objc private func settingsTapped() {
        onSettings?()
    }
}
