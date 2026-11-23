import AppKit
import CadenzaCore
import Combine
import UniformTypeIdentifiers

/// App shell: the paper practice screen fills the window, its panel lens
/// carrying the transport, the engine and the MIDI publisher wired beneath.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, PracticeShell {
    private var window: NSWindow?
    private var screen: PracticeScreenView?

    private let publisher = MIDIPublisher()
    private let engine = TranscriptionEngine()
    /// the session piano: playback sounds inside Cadenza instead of only
    /// leaving the app over the virtual MIDI source
    private let piano = PianoSampler()
    private let metronome = Metronome()
    /// Bumped whenever a session starts or stops, so a count-in that is
    /// still running when the user presses Stop starts nothing.
    private var countInToken = 0
    /// The rolling minute: every note the engine strikes, with when it
    /// arrived, so the best thing you played can be kept after the fact.
    private var recentNotes: [(note: NoteEvent, at: Date)] = []
    /// true while the app is listening for the rolling minute with no take
    /// running: capture on, wav off, nothing published
    private var ambient = false
    /// true between pressing New session with a click and the first note.
    private var countingIn = false
    private let store = SessionStore(directory: SettingsKeys.sessionDirectory)
    private var sheetController: SheetMusicController?
    /// the sheet section opened from an archived session's row
    private var archiveSheetController: SheetMusicController?
    private var settingsController: SettingsController?
    private var statsController: StatsController?
    /// the archive on screen, told when the store moves under it
    private weak var archiveOverlay: SessionsOverlayView?
    private var cancellables: Set<AnyCancellable> = []
    private var sessionStartedAt: Date?
    /// Playback, loops, scrubbing and play-along live in their own
    /// coordinator; this delegate keeps the window, the menu and the wiring.
    private lazy var playback = PlaybackCoordinator(store: store, publisher: publisher,
                                                    piano: piano, engine: engine)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // the practice screen is a paper world: it renders in light mode,
        // the way the approved drafts read (the theme keeps its dark
        // palette for the day the app follows the system again)
        NSApplication.shared.appearance = NSAppearance(named: .aqua)

        // the notation font for the sheet music section
        MusicFont.register()
        // a scratch recording an interrupted run left behind, and nothing else
        StorageHygiene.sweepScratch()

        publisher.setup()
        installMainMenu()
        installShortcuts()
        engine.onNoteEvent = { [weak self] event, kind in
            guard let self else { return }
            switch kind {
            case .struck:
                self.rememberRecent(event)
                // a session is what plays out as MIDI; listening to the room
                // in the background must never look like playing to another
                // app, so publishing is tied to the take, not to capture
                if self.sessionStartedAt != nil { self.publisher.noteStruck(event) }
                self.screen?.noteStruck(event)
            case .extended:
                break
            case .released:
                if self.sessionStartedAt != nil { self.publisher.noteReleased(event) }
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
        // the paper is the window: no title bar skin over it and no
        // separator line, just the traffic lights floating on the room. The
        // window's own background is the paper's top wash, so the strip above
        // the content reads as the same sheet.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = PaperTheme.parchment
        // the delegate owns this window; AppKit must not release it on close
        window.isReleasedWhenClosed = false
        window.contentView = makeContent(size: size)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        self.window = window
        // the rolling minute has to exist before the player asks for it
        startAmbientIfEnabled()

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
            shell: self,
            onSessions: { [weak self] in self?.openSessions() },
            onSheetMusic: { [weak self] in self?.openSheetMusic() },
            onStatistics: { [weak self] in self?.openStats() },
            onRefreshMIDI: { [weak self] in self?.republishMIDIPort() },
            onSettings: { [weak self] in self?.openSettings() }
        )
        root.addSubview(screen)
        NSLayoutConstraint.activate([
            screen.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            screen.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            screen.topAnchor.constraint(equalTo: root.topAnchor),
            screen.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        self.screen = screen
        wire(playback: playback, to: screen)
        refreshSessions()
        return root
    }

    /// The playback coordinator renders into the same paper screen, on the
    /// same clock, and reports through the same status line: the shell lends
    /// it those, it does not hand it the shell.
    private func wire(playback: PlaybackCoordinator, to screen: PracticeScreenView) {
        playback.view = screen
        playback.refresh = { [weak self] in self?.refreshSessions() }
        playback.presentError = { [weak self] text in self?.present(error: text) }
        playback.locateAssets = { Self.locateAssets() }
        playback.playAlongBegan = { [weak self] in
            self?.sessionStartedAt = Date()
            self?.sheetController?.reset()
        }
        playback.playAlongEnded = { [weak self] in
            self?.sheetController?.sessionEnded()
            self?.sessionStartedAt = nil
        }
        playback.ambientCapture = { [weak self] in self?.ambient ?? false }
        playback.stopAmbientCapture = { [weak self] in
            guard let self, self.ambient else { return }
            self.engine.stop()
            self.engine.discardRecording()
            self.ambient = false
            self.screen?.syncTransport()
        }
        playback.resumeAmbientCapture = { [weak self] in self?.startAmbientIfEnabled() }
    }

    // MARK: menu and shortcuts

    /// The app's menu bar. Until now the app had none, which is why no
    /// command shortcut could reach an action: a key equivalent has to live
    /// on a menu item for AppKit to route it, and the menu also gives the
    /// app its standard Quit, Hide and Settings doors.
    func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: "Cadenza")
        appItem.submenu = appMenu
        let about = NSMenuItem(title: "About Cadenza",
                               action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                               keyEquivalent: "")
        about.target = NSApplication.shared
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(menuSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        let hide = NSMenuItem(title: "Hide Cadenza", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.target = NSApplication.shared
        appMenu.addItem(hide)
        let quit = NSMenuItem(title: "Quit Cadenza", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApplication.shared
        appMenu.addItem(quit)

        let sessionItem = NSMenuItem()
        mainMenu.addItem(sessionItem)
        let sessionMenu = NSMenu(title: "Session")
        sessionItem.submenu = sessionMenu
        let newSession = NSMenuItem(title: "New session",
                                    action: #selector(menuNewSession), keyEquivalent: "n")
        newSession.target = self
        sessionMenu.addItem(newSession)
        let playPause = NSMenuItem(title: "Play or pause",
                                   action: #selector(menuPlayPause), keyEquivalent: "p")
        playPause.target = self
        sessionMenu.addItem(playPause)
        let keepMinute = NSMenuItem(title: "Keep last minute",
                                    action: #selector(menuKeepLastMinute), keyEquivalent: " ")
        keepMinute.keyEquivalentModifierMask = [.option]
        keepMinute.target = self
        sessionMenu.addItem(keepMinute)
        let refresh = NSMenuItem(title: "Refresh MIDI port",
                                 action: #selector(menuRefreshMIDI), keyEquivalent: "r")
        refresh.target = self
        sessionMenu.addItem(refresh)

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        let doors: [(String, Selector, String)] = [
            ("Sessions", #selector(menuSessions), "1"),
            ("Sheet music", #selector(menuSheet), "2"),
            ("Statistics", #selector(menuStats), "3"),
            ("Settings", #selector(menuSettings), "4"),
        ]
        for (title, action, key) in doors {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            viewMenu.addItem(item)
        }

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        let close = NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(close)
        let minimize = NSMenuItem(title: "Minimize",
                                  action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(minimize)

        NSApplication.shared.mainMenu = mainMenu
        NSApplication.shared.windowsMenu = windowMenu
    }

    /// Space starts and stops a session, Option-Space keeps the last
    /// minute. Everything else is a menu key equivalent, so it also works
    /// while a section card has focus. Typing in a text field keeps its keys,
    /// which is where Option-Space would otherwise type a hard space.
    ///
    /// Command-Shift-K stays as the alias that reaches the same action from
    /// any keyboard layout.
    private func installShortcuts() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            // a field editor is typing: space is a character, not transport
            if let responder = self.window?.firstResponder,
               responder is NSTextView || responder is NSTextField { return event }
            guard NSApplication.shared.modalWindow == nil else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if event.keyCode == 49 {
                if modifiers == .option || modifiers == [.option, .shift] {
                    self.keepLastMinute()
                    return nil
                }
                guard modifiers.isEmpty else { return event }
                self.toggleListening()
                return nil
            }
            if modifiers == [.command, .shift],
               event.charactersIgnoringModifiers?.lowercased() == "k" {
                self.keepLastMinute()
                return nil
            }
            return event
        }
    }

    // MARK: menu actions

    @objc private func menuNewSession() { toggleListening() }
    @objc private func menuPlayPause() { playback.togglePlayPause() }
    @objc private func menuKeepLastMinute() { keepLastMinute() }
    @objc private func menuRefreshMIDI() { republishMIDIPort() }
    @objc private func menuSessions() { openSessions() }
    @objc private func menuSheet() { openSheetMusic() }
    @objc private func menuStats() { openStats() }
    @objc private func menuSettings() { openSettings() }

    /// Menu items read the live state: the session door says Stop while a
    /// take runs, and a section that needs a take stays enabled regardless
    /// (its own empty state explains itself).
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(menuNewSession) {
            item.title = sessionStartedAt != nil ? "Stop session" : "New session"
        }
        if item.action == #selector(menuPlayPause) {
            return playback.playing != nil || !store.sessions.isEmpty || !engine.notes.isEmpty
        }
        return true
    }

    // MARK: settings

    private func openStats() {
        if statsController == nil {
            statsController = StatsController()
        }
        guard let content = statsController?.overlayContent(sessions: store.sessions) else { return }
        screen?.presentOverlay(content, size: NSSize(width: 440, height: 300))
    }

    /// The session archive: every kept session, in the one window, on
    /// glass. Its door belongs to the panel, its rows to the store.
    private func openSessions() {
        guard let screen else { return }
        let archive = SessionsOverlayView(shell: self,
                                          sessions: store.sessions,
                                          playing: playback.playing)
        archiveOverlay = archive
        archive.onLeave = { [weak self] in self?.screen?.dismissOverlay() }
        // the card is only as tall as the archive it holds: six takes do not
        // leave half a screen of empty glass under the last row
        let height = min(560, 130 + CGFloat(max(1, store.sessions.count)) * 47 + 20)
        screen.presentOverlay(archive, size: NSSize(width: 620, height: height)) { [weak self] in
            self?.screen?.setStatus("", error: false)
        }
    }

    private func openSettings() {
        if settingsController == nil {
            let controller = SettingsController()
            controller.publishedMIDIPort = { [weak self] in self?.publisher.publishedName }
            controller.onRefreshMIDI = { [weak self] in self?.republishMIDIPort() }
            controller.onRetroSettingChanged = { [weak self] in
                guard let self else { return }
                if SettingsKeys.keepRecentMinute {
                    self.startAmbientIfEnabled()
                } else {
                    self.recentNotes.removeAll()
                    if self.ambient {
                        self.engine.stop()
                        self.engine.discardRecording()
                        self.ambient = false
                    }
                }
                self.screen?.syncTransport()
            }
            controller.onMetronomeSettingsChanged = { [weak self] in
                guard let self, self.metronome.isRunning else { return }
                self.metronome.bpm = SettingsKeys.metronomeBPM
                self.metronome.beatsPerBar = SettingsKeys.metronomeBeats
                self.metronome.start()
                self.screen?.syncTransport()
            }
            controller.onSessionDirectoryChanged = { [weak self] url in
                self?.store.setDirectory(url)
                self?.refreshSessions()
                self?.screen?.setStatus("Sessions now save to \(url.lastPathComponent)", error: false)
            }
            settingsController = controller
        }
        guard let content = settingsController?.overlayContent() else { return }
        screen?.presentOverlay(content, size: NSSize(width: 460, height: 600))
    }

    // MARK: per-session actions

    /// Puts the session's .mid file on the clipboard as a file copy.
    func copySessionMIDI(_ record: SessionRecord) {
        let url = store.midiURL(for: record)
        guard FileManager.default.fileExists(atPath: url.path) else {
            present(error: "Couldn't find the session's MIDI file")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        screen?.setStatus("Copied \(url.lastPathComponent) to the clipboard", error: false)
    }

    /// Saves the session's MIDI file, its audio recording, or both to a
    /// chosen location, per what the export popover offered.
    func exportSession(_ record: SessionRecord, choice: ExportChoice) {
        guard let window else { return }
        if case .both = choice {
            exportBoth(record)
            return
        }
        let audio = choice == .audio
        let source = audio ? store.audioURL(for: record) : store.midiURL(for: record)
        guard FileManager.default.fileExists(atPath: source.path) else {
            present(error: audio ? "This session kept no audio recording" : "Couldn't find the session's MIDI file")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [audio ? .wav : .midi]
        panel.nameFieldStringValue = source.lastPathComponent
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                try FileManager.default.copyItem(at: source, to: url)
                self.screen?.setStatus("Saved \(url.lastPathComponent)", error: false)
            } catch {
                self.present(error: error.localizedDescription)
            }
        }
    }

    /// Both files at once: one folder choice, then MIDI and audio copy in
    /// under the session's name.
    private func exportBoth(_ record: SessionRecord) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export here"
        panel.message = "Choose where both files go"
        panel.beginSheetModal(for: window!) { response in
            guard response == .OK, let folder = panel.url else { return }
            let base = (record.name?.isEmpty == false ? record.name! : record.folderName ?? "Cadenza session")
            do {
                var saved = 0
                let midi = self.store.midiURL(for: record)
                if FileManager.default.fileExists(atPath: midi.path) {
                    let target = folder.appendingPathComponent("\(base).mid")
                    if FileManager.default.fileExists(atPath: target.path) {
                        try FileManager.default.removeItem(at: target)
                    }
                    try FileManager.default.copyItem(at: midi, to: target)
                    saved += 1
                }
                let audio = self.store.audioURL(for: record)
                if FileManager.default.fileExists(atPath: audio.path) {
                    let target = folder.appendingPathComponent("\(base).wav")
                    if FileManager.default.fileExists(atPath: target.path) {
                        try FileManager.default.removeItem(at: target)
                    }
                    try FileManager.default.copyItem(at: audio, to: target)
                    saved += 1
                }
                self.screen?.setStatus(saved == 2 ? "Saved \(base).mid and \(base).wav" : "Saved \(saved) file(s) to \(folder.lastPathComponent)", error: false)
            } catch {
                self.present(error: error.localizedDescription)
            }
        }
    }

    /// Imports a MIDI file as a session: it lands in the archive ready to
    /// play, engrave or practice against.
    func importMIDI() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.midi]
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.beginSheetModal(for: window.unsafelyUnwrapped) { response in
            guard response == .OK, let url = panel.url else { return }
            let name = url.deletingPathExtension().lastPathComponent
            if let record = self.store.importSession(from: url, name: name) {
                self.refreshSessions()
                self.screen?.setStatus("Imported \(name) (\(record.noteCount) notes)", error: false)
            } else {
                self.present(error: "Couldn't read \(url.lastPathComponent) — no notes in it")
            }
        }
    }

    /// Opens the sheet section on a stored session, pedal spans included.
    func openSessionSheet(_ record: SessionRecord) {
        guard let notes = store.notes(for: record) else {
            present(error: "Couldn't read the session file")
            return
        }
        let controller = SheetMusicController(
            notes: notes,
            pedals: store.pedalSpans(for: record))
        archiveSheetController = controller
        presentSheet(controller)
    }

    /// Puts a sheet in the card, live: the engraver redrafts while notes land.
    private func presentSheet(_ controller: SheetMusicController) {
        let content = controller.overlayContent()
        controller.onClose = { [weak self] in
            self?.screen?.dismissOverlay()
            self?.sheetController?.overlayDismissed()
            self?.sheetController = nil
        }
        screen?.presentOverlay(content, size: NSSize(width: 980, height: 700)) { [weak controller] in
            controller?.overlayDismissed()
        }
    }

    /// The archive lands on the panel after every change, with whoever is
    /// playing carrying the stamp.
    private func refreshSessions() {
        screen?.setSessions(store.sessions, playing: playback.playing)
        archiveOverlay?.update(sessions: store.sessions, playing: playback.playing)
    }

    // MARK: retroactive capture

    /// Adds a struck note to the rolling minute and drops what fell out of
    /// it. One array of small values, pruned on every strike, so the buffer
    /// cannot grow past the window.
    private func rememberRecent(_ note: NoteEvent) {
        guard SettingsKeys.keepRecentMinute else { return }
        let now = Date()
        recentNotes.append((note, now))
        if recentNotes.count > 4096 {
            recentNotes.removeFirst(recentNotes.count - 4096)
        }
        recentNotes.removeAll { now.timeIntervalSince($0.at) > SettingsKeys.retroWindow + 10 }
    }

    /// Keeps the last minute of playing as its own session without touching
    /// the one that is running: you play something worth keeping, press the
    /// button, and carry on.
    func keepLastMinute() {
        let now = Date()
        let window = recentNotes.filter { now.timeIntervalSince($0.at) <= SettingsKeys.retroWindow }
        guard window.count >= 2 else {
            present(error: "Nothing played in the last minute yet")
            return
        }
        let first = window.map(\.note.onset).min() ?? 0
        let notes = window.map { entry -> NoteEvent in
            var note = entry.note
            note.onset = max(0, entry.note.onset - first)
            return note
        }
        let span = notes.map(\.offset).max() ?? 0
        let began = Date().addingTimeInterval(-span)
        let audio = keptMinuteAudio(from: first, length: span)
        if let record = store.saveSession(notes: notes, startedAt: began,
                                          durationSeconds: span, audio: audio,
                                          keepAudio: SettingsKeys.keepRecordedAudio) {
            refreshSessions()
            let described = TakeAnalysis.describe(notes: notes)
            screen?.setStatus(described.map { "Kept the last minute · \($0.summary)" }
                              ?? "Kept the last minute as \(record.label)", error: false)
        } else {
            present(error: "Couldn't keep that minute")
        }
    }

    /// The raw audio of a kept minute, cut to the same span as the notes
    /// that were kept and written where the store can move it into the
    /// session folder. nil when audio is switched off, or when capture has
    /// not been running long enough to cover the notes.
    private func keptMinuteAudio(from first: Double, length: Double) -> (url: URL, rate: Double)? {
        guard SettingsKeys.keepRecordedAudio,
              let captured = engine.retroAudio(seconds: SettingsKeys.retroWindow + 2),
              captured.rate > 0 else { return nil }
        let start = max(0, Int(((first - captured.startSeconds) * captured.rate).rounded()))
        let end = min(captured.samples.count,
                      Int(((first + length - captured.startSeconds) * captured.rate).rounded()))
        guard end > start + 1 else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Cadenza kept minute.wav")
        do {
            try WavWriter.write(Array(captured.samples[start..<end]), rate: captured.rate, to: url)
            return (url, captured.rate)
        } catch {
            print("[keep] audio: \(error.localizedDescription)")
            return nil
        }
    }

    /// With the rolling minute on, the app listens from launch: the minute
    /// has to exist before the player asks for it. Ambient capture writes no
    /// wav and publishes no MIDI; it is the app hearing the room, and a
    /// silent room costs no decode at all.
    private func startAmbientIfEnabled() {
        guard SettingsKeys.keepRecentMinute, !engine.isRunning, !countingIn,
              sessionStartedAt == nil else { return }
        guard let assets = Self.locateAssets() else { return }
        engine.start(tensorsDir: assets.tensors, modelURL: assets.model, recordSession: false)
        ambient = true
        screen?.syncTransport()
        print("[ambient] listening for the last minute")
    }

    // MARK: metronome

    /// The practice click: on while you play, off when you press it again.
    /// Reading the settings at every start means a tempo changed in Settings
    /// applies to the next click, not the next launch.
    /// Sets the click's tempo from the home screen's popover: stored, applied
    /// to a running click immediately, and shown on the button.
    func setMetronomeTempo(_ bpm: Double) {
        let clamped = min(240, max(30, bpm.rounded()))
        UserDefaults.standard.set(clamped, forKey: SettingsKeys.metronomeBPMKey)
        metronome.bpm = clamped
        if metronome.isRunning { metronome.start() }
        screen?.syncTransport()
    }

    func toggleMetronome() {
        metronome.bpm = SettingsKeys.metronomeBPM
        metronome.beatsPerBar = SettingsKeys.metronomeBeats
        metronome.toggle()
        screen?.syncTransport()
        screen?.setStatus(metronome.isRunning
                          ? "Click on · \(Int(metronome.bpm)) bpm"
                          : "Click off", error: false)
    }

    // MARK: transport actions

    /// One action: it starts the session that listens, plays out as MIDI,
    /// and is what export hands over, and it stops that session again.
    func toggleListening() {
        if sessionStartedAt != nil || countingIn {
            countingIn = false
            countInToken += 1
            engine.stop()
            publisher.panic()
            metronome.stop()
            screen?.syncTransport()
            screen?.sessionStopped()
            screen?.syncTransport()
            sheetController?.sessionEnded()
            if let startedAt = sessionStartedAt {
                // empty sessions (no notes) are discarded by the store; the
                // previous session moves to the history automatically
                let keepAudio = SettingsKeys.keepRecordedAudio
                let record = store.saveSession(
                    notes: engine.notes,
                    startedAt: startedAt,
                    durationSeconds: Date().timeIntervalSince(startedAt),
                    audio: engine.lastRecording,
                    keepAudio: keepAudio)
                if let record {
                    engraveSessionPDF(record, notes: engine.notes)
                    // the take describes itself the moment it stops: key,
                    // tempo and phrasing come from the notes that were just
                    // played, so the player learns something before opening
                    // anything
                    if let described = TakeAnalysis.describe(notes: engine.notes) {
                        screen?.setStatus(described.summary, error: false)
                    } else {
                        screen?.setStatus(keepAudio ? "Saved session to the archive" : "Saved session (audio discarded)", error: false)
                    }
                } else {
                    // empty session: nothing earned its folder, the streamed
                    // recording goes with it
                    engine.discardRecording()
                }
            }
            sessionStartedAt = nil
            refreshSessions()
            // a finished take goes back to listening, so the next minute is
            // already there when the player wants it
            startAmbientIfEnabled()
        } else {
            playback.stop()
            guard let assets = Self.locateAssets() else {
                present(error: "Model files not found next to the app")
                return
            }
            // ambient capture has no wav and a timeline of its own: a take
            // starts from a clean one rather than inheriting background time
            if ambient {
                engine.stop()
                engine.discardRecording()
                ambient = false
            }
            let begin = { [weak self] in
                guard let self else { return }
                self.engine.start(tensorsDir: assets.tensors, modelURL: assets.model,
                                  recordSession: true)
                self.sessionStartedAt = Date()
                self.screen?.sessionStarted()
                self.screen?.syncTransport()
                self.sheetController?.reset()
                self.present(error: self.engine.lastError)
            }
            // A click that is already running gives the player one bar of
            // count-in before the session takes the first note: the whole
            // reason to have a metronome is to start in time.
            if metronome.isRunning {
                countingIn = true
                countInToken += 1
                let token = countInToken
                screen?.setStatus("Counting in · \(Int(metronome.bpm)) bpm", error: false)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(metronome.barSeconds * 1_000_000_000))
                    guard self.countInToken == token, !self.engine.isRunning else { return }
                    self.countingIn = false
                    begin()
                }
            } else {
                begin()
            }
        }
        present(error: engine.lastError)
    }

    /// Engraves the session's notes to sheet PDF in its folder. A failing
    /// engraving leaves the session intact without it: nothing saved twice.
    private func engraveSessionPDF(_ record: SessionRecord, notes: [NoteEvent]) {
        guard !notes.isEmpty else { return }
        let url = store.folderURL(for: record).appendingPathComponent(record.pdfFileName)
        // Engraving is the slowest thing a stop used to do, and the print
        // pipeline can stall behind the printing services: let the transport
        // answer first, then engrave on the next turn of the run loop.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            let began = Date()
            do {
                try SheetPDF.write(
                    notes: notes,
                    name: record.name ?? record.folderName ?? "Cadenza session",
                    to: url)
                self.store.markHasPDF(record)
                print(String(format: "[pdf] engraved in %.0f ms", Date().timeIntervalSince(began) * 1000))
            } catch {
                print("[pdf] \(error.localizedDescription)")
            }
        }
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
        // a controller that believes it is open while its card is gone used to
        // swallow the tap: the sheet "opened" onto the home screen and nothing
        // changed. Only a card that is actually on screen gets synced.
        if let controller = sheetController, controller.isOpen,
           screen?.overlayPresented == true {
            controller.sync(notes: engine.notes)
            return
        }
        let controller = SheetMusicController(notes: engine.notes)
        sheetController = controller
        presentSheet(controller)
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

    /// Republishes the virtual MIDI port on request: open web apps receive a
    /// device state change and can pick Cadenza up without a reload.
    private func republishMIDIPort() {
        let published = publisher.refresh()
        screen?.setStatus(published ? "MIDI port refreshed" : "Couldn't publish the MIDI port",
                          error: !published)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if engine.isRunning {
            engine.stop()
            publisher.panic()
        }
        piano.silence()
        // take the virtual port down with the app instead of leaving a dead
        // endpoint in every open web page's device list
        publisher.shutdown()
    }
}

// MARK: - the shell the paper surfaces talk to

/// The screen and the archive hold the shell, not a bag of closures: every
/// read is state, every write is an action, and the ones that already have a
/// home here (listening, the click, the archive's exports) are simply exposed.
extension AppDelegate {
    var isListening: Bool { sessionStartedAt != nil }

    var exportEnabled: Bool { !engine.notes.isEmpty }

    func export() { exportMIDI() }

    // MARK: playback

    func playSession(_ record: SessionRecord) { playback.play(record) }

    var playingSession: SessionRecord? { playback.playing }

    func togglePlayPause() { playback.togglePlayPause() }

    func stopPlayback() {
        playback.stop()
        refreshSessions()
    }

    var playbackPaused: Bool { playback.paused }

    var playbackProgress: Double { playback.progress }

    func scrubPlayback(_ fraction: Double) { playback.scrub(to: fraction) }

    func setLoopPoint(isA: Bool) { playback.setLoopPoint(isA: isA) }

    func toggleLoop() { playback.toggleLoop() }

    var loopActive: Bool { playback.loopActive }

    func setPlaybackRate(_ rate: Double) { playback.setRate(rate) }

    // MARK: the archive

    func renameSession(_ record: SessionRecord, to name: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let renamed = store.rename(record, to: name) else {
            screen?.setStatus("Couldn't rename that session", error: true)
            return
        }
        refreshSessions()
        screen?.setStatus("Renamed to \"\(renamed.name ?? name)\"", error: false)
    }

    func deleteSession(_ record: SessionRecord) {
        if playback.playing?.id == record.id { playback.stop() }
        store.delete(record)
        refreshSessions()
        screen?.setStatus("Deleted session", error: false)
    }

    func deleteSessions(_ records: [SessionRecord]) {
        guard !records.isEmpty else { return }
        if let playing = playback.playing, records.contains(where: { $0.id == playing.id }) {
            playback.stop()
        }
        for record in records { store.delete(record) }
        refreshSessions()
        screen?.setStatus(records.count == 1 ? "Deleted session" : "Deleted \(records.count) sessions",
                          error: false)
    }

    func renameSessions(_ records: [SessionRecord], base: String) {
        guard !records.isEmpty else { return }
        var renamed = 0
        for (index, record) in records.enumerated() {
            // one stem, then -1, -2 in the order the archive lists them
            let name = records.count == 1 ? base : "\(base)-\(index + 1)"
            if store.rename(record, to: name) != nil { renamed += 1 }
        }
        refreshSessions()
        screen?.setStatus(renamed == 1 ? "Renamed session" : "Renamed \(renamed) sessions", error: false)
    }

    func playAlong(_ record: SessionRecord) { playback.playAlong(record) }

    func sessionHasAudio(_ record: SessionRecord) -> Bool {
        store.sessions.first { $0.id == record.id }?.hasAudio ?? false
    }

    func describeSession(_ record: SessionRecord) -> TakeDescription? {
        guard let notes = store.notes(for: record) else { return nil }
        return TakeAnalysis.describe(notes: notes)
    }

    // MARK: the click and retroactive capture

    var canKeepLastMinute: Bool {
        recentNotes.contains { Date().timeIntervalSince($0.at) <= SettingsKeys.retroWindow }
    }

    var keepMinuteEnabled: Bool { SettingsKeys.keepRecentMinute }

    var metronomeActive: Bool { metronome.isRunning }

    var metronomeTempo: Double { metronome.bpm }

    // MARK: status

    func showStatus(_ text: String, isError: Bool) { screen?.setStatus(text, error: isError) }
}
