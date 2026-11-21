import AppKit
import CadenzaCore
import Combine
import UniformTypeIdentifiers

/// App shell: the paper practice screen fills the window, its panel lens
/// carrying the transport, the engine and the MIDI publisher wired beneath.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
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
    private static let retroWindow: TimeInterval = 60
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
    private var playbackTask: Task<Void, Never>?
    private var playingRecord: SessionRecord?
    private var playbackCount = 0
    private var playbackPaused = false
    /// where a paused playback resumes: the next note's index and the onset
    /// of the last note already sent
    private var playbackCursor = 0
    /// The playing session's notes, read once: the scrub hand polls the
    /// transport every second and re-parsing a MIDI file that often is work
    /// nobody asked for.
    private var playbackNotesCache: [NoteEvent] = []
    private var playbackNotesCacheID: UUID?
    private var playbackPreviousOnset = 0.0
    /// A-B loop over the playing session, with the practice rate
    private var loopEnabled = false
    private var loopA: Double?
    private var loopB: Double?
    private var playbackRate = 1.0
    /// play-along: the session being played while the engine listens
    private var playAlongRecord: SessionRecord?
    /// the note count the play-along started with (the score reads only
    /// what was played during the run)
    private var playAlongStartNoteCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // the practice screen is a paper world: it renders in light mode,
        // the way the approved drafts read (the theme keeps its dark
        // palette for the day the app follows the system again)
        NSApplication.shared.appearance = NSAppearance(named: .aqua)

        // the notation font for the sheet music section
        MusicFont.register()

        publisher.setup()
        installMainMenu()
        installShortcuts()
        engine.onNoteEvent = { [weak self] event, kind in
            guard let self else { return }
            switch kind {
            case .struck:
                self.rememberRecent(event)
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
        // the delegate owns this window; AppKit must not release it on close
        window.isReleasedWhenClosed = false
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
            playingSession: { [weak self] in self?.playingRecord },
            togglePlayPause: { [weak self] in self?.togglePlayPause() },
            stopPlayback: { [weak self] in
                self?.stopPlayback()
                self?.refreshSessions()
            },
            playbackPaused: { [weak self] in self?.playbackPaused ?? false },
            renameSession: { [weak self] record, name in
                guard let self else { return }
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                let renamed = self.store.rename(record, to: name)
                self.refreshSessions()
                if let renamed {
                    self.screen?.setStatus("Renamed to \"\(renamed.name ?? name)\"", error: false)
                } else {
                    self.screen?.setStatus("Couldn't rename that session", error: true)
                }
            },
            deleteSession: { [weak self] record in
                guard let self else { return }
                if self.playingRecord?.id == record.id { self.stopPlayback() }
                self.store.delete(record)
                self.refreshSessions()
                self.screen?.setStatus("Deleted session", error: false)
            },
            copySessionMIDI: { [weak self] record in self?.copySessionMIDI(record) },
            openSessionSheet: { [weak self] record in self?.openSessionSheet(record) },
            playAlong: { [weak self] record in self?.togglePlayAlong(of: record) },
            exportSessionMIDI: { [weak self] record in self?.exportSession(record, choice: .midi) },
            exportSessionAudio: { [weak self] record in self?.exportSession(record, choice: .audio) },
            exportSessionBoth: { [weak self] record in self?.exportSession(record, choice: .both) },
            sessionHasAudio: { [weak self] record in self?.store.sessions.first(where: { $0.id == record.id })?.hasAudio ?? false },
            importMIDI: { [weak self] in self?.importMIDI() },
            describeSession: { [weak self] record in
                guard let self, let notes = self.store.notes(for: record) else { return nil }
                return TakeAnalysis.describe(notes: notes)
            },
            showStatus: { [weak self] text, isError in
                self?.screen?.setStatus(text, error: isError)
            },
            playbackProgress: { [weak self] in self?.playbackProgress() ?? 0 },
            scrubPlayback: { [weak self] fraction in self?.scrubPlayback(to: fraction) },
            keepLastMinute: { [weak self] in self?.keepLastMinute() },
            canKeepLastMinute: { [weak self] in
                guard let self else { return false }
                return self.recentNotes.contains { Date().timeIntervalSince($0.at) <= Self.retroWindow }
            },
            toggleMetronome: { [weak self] in self?.toggleMetronome() },
            metronomeActive: { [weak self] in self?.metronome.isRunning ?? false },
            metronomeTempo: { [weak self] in self?.metronome.bpm ?? 96 },
            setLoopPoint: { [weak self] isA in self?.setLoopPoint(isA) },
            toggleLoop: { [weak self] in self?.toggleLoop() },
            loopActive: { [weak self] in self?.loopEnabled ?? false },
            setPlaybackRate: { [weak self] rate in self?.playbackRate = rate }
        )
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
                                    action: #selector(menuKeepLastMinute), keyEquivalent: "k")
        keepMinute.keyEquivalentModifierMask = [.command, .shift]
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

    /// Space toggles play and pause while the practice window is frontmost.
    /// Everything else is a menu key equivalent, so it also works while a
    /// section card has focus. Typing in a text field keeps its keys.
    private func installShortcuts() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            guard event.keyCode == 49,
                  event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
            else { return event }
            // a field editor is typing: space is a character, not transport
            if let responder = self.window?.firstResponder,
               responder is NSTextView || responder is NSTextField { return event }
            guard NSApplication.shared.modalWindow == nil else { return event }
            self.togglePlayPause()
            return nil
        }
    }

    // MARK: menu actions

    @objc private func menuNewSession() { toggleListening() }
    @objc private func menuPlayPause() { togglePlayPause() }
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
            item.title = engine.isRunning ? "Stop session" : "New session"
        }
        if item.action == #selector(menuPlayPause) {
            return playingRecord != nil || !store.sessions.isEmpty || !engine.notes.isEmpty
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

    /// The session archive: every kept session, in the one window, on frozen
    /// glass. Its door belongs to the panel, its rows to the store.
    private func openSessions() {
        guard let screen else { return }
        let archive = SessionsOverlayView(transport: makeTransport(),
                                          sessions: store.sessions,
                                          playing: playingRecord)
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
    private func copySessionMIDI(_ record: SessionRecord) {
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
    private func exportSession(_ record: SessionRecord, choice: ExportChoice) {
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
    private func importMIDI() {
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
    private func openSessionSheet(_ record: SessionRecord) {
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

    // MARK: loop and rate

    /// Marks the loop's start (true) or end (false) at the playing moment.
    private func setLoopPoint(_ isA: Bool) {
        guard playingRecord != nil else { return }
        let moment = currentPlaybackMoment()
        if isA {
            loopA = moment
            screen?.setStatus("Loop start at \(sessionTimeString(moment))", error: false)
        } else {
            loopB = moment
            if let a = loopA, moment > a {
                screen?.setStatus("Loop \(sessionTimeString(a)) – \(sessionTimeString(moment)), press Loop to repeat it", error: false)
            } else {
                screen?.setStatus("Loop end at \(sessionTimeString(moment)), set a start before it", error: false)
            }
        }
        refreshSessions()
    }

    /// The playing moment: the onset of the last note already sent.
    private func currentPlaybackMoment() -> Double {
        let notes = sortedPlaybackNotes() ?? []
        let index = min(max(0, playbackCursor - 1), max(0, notes.count - 1))
        return notes.isEmpty ? 0 : notes[index].onset
    }

    /// Where the playing take sits, 0 to 1, for the panel's scrub hand.
    private func playbackProgress() -> Double {
        guard let record = playingRecord, let notes = cachedPlaybackNotes(for: record), !notes.isEmpty else {
            return 0
        }
        let total = max(0.5, notes.map(\.offset).max() ?? 0.5)
        return min(1, max(0, currentPlaybackMoment() / total))
    }

    /// The time machine: jump to a point in the take and keep playing from
    /// there, with the keybed and the endless measure following. Scrubbing
    /// only moves the transport; nothing is exported from a scrub.
    private func scrubPlayback(to fraction: Double) {
        guard let record = playingRecord, let notes = cachedPlaybackNotes(for: record), !notes.isEmpty else { return }
        let total = max(0.5, notes.map(\.offset).max() ?? 0.5)
        let target = min(max(0, fraction), 1) * total
        var index = notes.firstIndex(where: { $0.onset >= target }) ?? (notes.count - 1)
        index = min(notes.count - 1, max(0, index))
        playbackTask?.cancel()
        playbackTask = nil
        publisher.panic()
        piano.silence()
        playbackCursor = index
        playbackPreviousOnset = max(0, target - 0.05)
        playbackCount = 0
        guard !playbackPaused else {
            screen?.syncTransport()
            return
        }
        startPlayback(from: record, cursor: index, previousOnset: playbackPreviousOnset)
    }

    /// The playing take's notes, sorted by onset, read once per session.
    private func cachedPlaybackNotes(for record: SessionRecord) -> [NoteEvent]? {
        if playbackNotesCacheID == record.id { return playbackNotesCache }
        guard let notes = store.notes(for: record) else { return nil }
        playbackNotesCache = notes.sorted { $0.onset < $1.onset }
        playbackNotesCacheID = record.id
        return playbackNotesCache
    }

    private func toggleLoop() {
        guard let a = loopA, let b = loopB, b > a else {
            present(error: "Set loop points A and B first, B after A")
            return
        }
        loopEnabled.toggle()
        screen?.setStatus(loopEnabled ? "Loop on, \(Int(playbackRate * 100))% speed" : "Loop off", error: false)
        refreshSessions()
    }

    /// The archive lands on the panel after every change, with whoever is
    /// playing carrying the stamp.
    private func refreshSessions() {
        screen?.setSessions(store.sessions, playing: playingRecord)
        archiveOverlay?.update(sessions: store.sessions, playing: playingRecord)
    }

    // MARK: retroactive capture

    /// Adds a struck note to the rolling minute and drops what fell out of
    /// it. One array of small values, pruned on every strike, so the buffer
    /// cannot grow past the window.
    private func rememberRecent(_ note: NoteEvent) {
        let now = Date()
        recentNotes.append((note, now))
        if recentNotes.count > 4096 {
            recentNotes.removeFirst(recentNotes.count - 4096)
        }
        recentNotes.removeAll { now.timeIntervalSince($0.at) > Self.retroWindow + 10 }
    }

    /// Keeps the last minute of playing as its own session without touching
    /// the one that is running: you play something worth keeping, press the
    /// button, and carry on.
    private func keepLastMinute() {
        let now = Date()
        let window = recentNotes.filter { now.timeIntervalSince($0.at) <= Self.retroWindow }
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
        if let record = store.saveSession(notes: notes, startedAt: began,
                                          durationSeconds: span, audio: nil,
                                          keepAudio: false) {
            refreshSessions()
            let described = TakeAnalysis.describe(notes: notes)
            screen?.setStatus(described.map { "Kept the last minute · \($0.summary)" }
                              ?? "Kept the last minute as \(record.label)", error: false)
        } else {
            present(error: "Couldn't keep that minute")
        }
    }

    // MARK: metronome

    /// The practice click: on while you play, off when you press it again.
    /// Reading the settings at every start means a tempo changed in Settings
    /// applies to the next click, not the next launch.
    private func toggleMetronome() {
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
    private func toggleListening() {
        if engine.isRunning || countingIn {
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
        } else {
            stopPlayback()
            guard let assets = Self.locateAssets() else {
                present(error: "Model files not found next to the app")
                return
            }
            let begin = { [weak self] in
                guard let self else { return }
                self.engine.start(tensorsDir: assets.tensors, modelURL: assets.model)
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

    // MARK: session playback

    /// Engraves the session's notes to sheet.pdf in its folder. A failing
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
                try SheetPDF.write(notes: notes, to: url)
                self.store.markHasPDF(record)
                print(String(format: "[pdf] engraved in %.0f ms", Date().timeIntervalSince(began) * 1000))
            } catch {
                print("[pdf] \(error.localizedDescription)")
            }
        }
    }

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
        guard store.notes(for: record) != nil else {
            present(error: "Couldn't read the session file")
            return
        }
        playingRecord = record
        playbackNotesCacheID = nil
        playbackPaused = false
        playbackCursor = 0
        playbackPreviousOnset = 0
        playbackCount = 0
        refreshSessions()
        startPlayback(from: record, cursor: 0, previousOnset: 0)
    }

    /// Play-along: the session plays through the keys while the engine
    /// listens, so the player performs against their own or an imported
    /// take. When the playback ends (first runs are unscored), the played
    /// notes score against the reference's onsets.
    private func togglePlayAlong(of record: SessionRecord) {
        if playAlongRecord?.id == record.id {
            stopPlayback()
            refreshSessions()
            return
        }
        guard !engine.isRunning else {
            present(error: "Stop listening before playing along")
            return
        }
        stopPlayback()
        guard store.notes(for: record) != nil else {
            present(error: "Couldn't read the session file")
            return
        }
        guard let assets = Self.locateAssets() else {
            present(error: "Model files not found next to the app")
            return
        }
        playAlongRecord = record
        playAlongStartNoteCount = engine.notes.count
        screen?.panelPlayAlong(true)
        engine.start(tensorsDir: assets.tensors, modelURL: assets.model)
        sessionStartedAt = Date()
        screen?.sessionStarted()
        screen?.syncTransport()
        sheetController?.reset()
        startPlayback(from: record, cursor: 0, previousOnset: 0)
        present(error: engine.lastError)
    }

    /// Scores a finished play-along: every note the player struck matches
    /// the nearest same-pitch reference note within 150 ms; the fit is the
    /// match rate, the timing the mean of the struck-too-late amounts.
    private func scorePlayAlong() {
        let played = Array(engine.notes.dropFirst(min(playAlongStartNoteCount, engine.notes.count)))
        guard playAlongRecord != nil, !played.isEmpty else {
            screen?.setStatus("Play-along ended without any played notes", error: false)
            return
        }
        guard let reference = playAlongRecord.flatMap({ store.notes(for: $0) }) else {
            screen?.setStatus("Couldn't reread the reference notes", error: true)
            return
        }
        var used = Set<Int>()
        var matched = 0
        var deltas: [Double] = []
        for note in played.sorted(by: { $0.onset < $1.onset }) {
            var best = -1
            var bestDelta = 0.15
            for (index, ref) in reference.enumerated() where !used.contains(index) && ref.pitch == note.pitch {
                let delta = note.onset - ref.onset
                if abs(delta) <= abs(bestDelta) || best == -1 {
                    if abs(delta) <= 0.15 {
                        bestDelta = delta
                        best = index
                    }
                }
            }
            if best >= 0 {
                used.insert(best)
                matched += 1
                deltas.append(bestDelta)
            }
        }
        let fit = Double(matched) / Double(played.count)
        var line = String(format: "Fit %.0f%% (%d of %d notes)", fit * 100, matched, played.count)
        if !deltas.isEmpty {
            let meanAll = deltas.reduce(0, +) / Double(deltas.count)
            line += String(format: ", %.0f ms %@ average", abs(meanAll) * 1000, meanAll >= 0 ? "late" : "early")
        }
        screen?.setStatus(line, error: false)
    }

    /// The transport button under the timer: with a session playing it
    /// pauses, when paused it resumes from the cursor, and with nothing
    /// playing it starts the newest session in the archive.
    private func togglePlayPause() {
        if let record = playingRecord {
            if playbackPaused {
                playbackPaused = false
                startPlayback(from: record, cursor: playbackCursor, previousOnset: playbackPreviousOnset)
            } else {
                playbackTask?.cancel()
                playbackTask = nil
                playbackPaused = true
                // hanging notes would drone on in other apps: release all
                publisher.panic()
                piano.silence()
                screen?.sessionStopped()
            }
        } else if let newest = store.sessions.first {
            togglePlayback(of: newest)
            return
        }
        refreshSessions()
    }

    /// The sorted notes of a session, for the loop's moment bookkeeping.
    private func sortedPlaybackNotes() -> [NoteEvent]? {
        guard let record = playingRecord, let notes = store.notes(for: record) else { return nil }
        return notes.sorted(by: { $0.onset < $1.onset })
    }

    /// The playback loop, resumable: `cursor` is the next note to send and
    /// `previousOnset` the onset of the note before it, so a paused session
    /// continues exactly where it stopped. With an A-B loop on, reaching B
    /// restarts from A, and the waits stretch by the practice rate.
    private func startPlayback(from record: SessionRecord, cursor: Int, previousOnset: Double) {
        guard let notes = store.notes(for: record) else {
            stopPlayback()
            refreshSessions()
            return
        }
        let sorted = notes.sorted(by: { $0.onset < $1.onset })
        let rate = max(0.25, min(2.0, playbackRate))
        // the instrument loads its samples before the first note, never
        // inside one: a start that hitches reads as a broken transport
        piano.prepare()
        let looping = loopEnabled, loopA = loopA, loopB = loopB
        screen?.sessionStopped()
        playbackTask = Task { [weak self] in
            var previous = previousOnset
            var index = cursor
            while index < sorted.count {
                let note = sorted[index]
                if looping, let b = loopB, let a = loopA, note.onset >= b {
                    // the loop's end: restart from the first note at or
                    // after A, keeping the loop's own lead-in silence
                    if let start = sorted.firstIndex(where: { $0.onset >= a }) {
                        index = start
                        previous = max(0, sorted[index].onset - 0.4)
                        continue
                    }
                }
                let wait = max(0, note.onset - previous) / rate
                previous = note.onset
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }
                self?.playbackCursor = index + 1
                self?.playbackPreviousOnset = previous
                self?.playbackCount += 1
                self?.publisher.noteStruck(note)
                self?.piano.noteOn(pitch: note.pitch, velocity: note.velocity)
                self?.screen?.noteStruck(note)
                self?.screen?.setNoteCount(self?.playbackCount ?? 0)
                let held = note
                let heldFor = max(held.duration, 0.05) / rate
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(heldFor * 1_000_000_000))
                    // a release belongs to the run that struck it: when the
                    // outer task was cancelled (pause or stop), let it go
                    guard self?.playbackTask?.isCancelled == false else { return }
                    self?.publisher.noteReleased(held)
                    self?.piano.noteOff(pitch: held.pitch)
                    self?.screen?.noteReleased(held)
                }
                index += 1
            }
            // let the last note ring, then hand the keys back
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.playbackFinished()
        }
    }

    /// A playback ran to its end: stop the machinery; a play-along scores
    /// itself before the keys come back.
    private func playbackFinished() {
        if playAlongRecord != nil {
            scorePlayAlong()
        }
        stopPlayback()
        refreshSessions()
    }

    private func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        playbackPaused = false
        if playingRecord != nil {
            publisher.panic()
        }
        piano.park()
        playingRecord = nil
        playbackNotesCacheID = nil
        playbackNotesCache = []
        // loop points belong to the stopped playback; the next one starts clean
        loopA = nil
        loopB = nil
        loopEnabled = false
        // a play-along takes its listening down with it
        if playAlongRecord != nil {
            playAlongRecord = nil
            screen?.panelPlayAlong(false)
            if engine.isRunning {
                engine.stop()
                publisher.panic()
                screen?.sessionStopped()
                screen?.syncTransport()
                sheetController?.sessionEnded()
                sessionStartedAt = nil
            }
        }
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
