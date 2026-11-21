import AppKit
import CadenzaCore
import Foundation

/// Everything the transport does with a preserved take: play it, pause it,
/// stop it, loop a passage, slow it down, scrub through it, and play along
/// with it. It owns the playback state that used to live in `AppDelegate` as
/// fifteen loose properties, so the app delegate can go back to being the
/// window, the menu and the wiring.
///
/// Nothing here knows about overlays, drawers or the archive; the owner hands
/// it the store and the instruments, and gets told when something happened
/// through four small hooks.
@MainActor
final class PlaybackCoordinator {
    private let store: SessionStore
    private let publisher: MIDIPublisher
    private let piano: PianoSampler
    private let engine: TranscriptionEngine

    /// The one view playback writes to, held weakly: the app delegate owns it.
    weak var view: PracticeScreenView?

    /// The archive changed, an error has to be shown, model assets are
    /// needed, and a play-along starts or stops the listening session.
    var refresh: () -> Void = {}
    var presentError: (String?) -> Void = { _ in }
    var locateAssets: () -> (tensors: URL, model: URL)? = { nil }
    var playAlongBegan: () -> Void = {}
    var playAlongEnded: () -> Void = {}

    private var task: Task<Void, Never>?
    private(set) var playing: SessionRecord?
    private(set) var paused = false
    private var sentNotes = 0
    private var cursor = 0
    private var previousOnset = 0.0
    /// The playing take's notes, read once: the scrub hand polls the
    /// transport every second and re-parsing a MIDI file that often is work
    /// nobody asked for.
    private var notesCache: [NoteEvent] = []
    private var notesCacheID: UUID?
    private var loopEnabled = false
    private var loopA: Double?
    private var loopB: Double?
    private var rate = 1.0
    private var playAlong: SessionRecord?
    private var playAlongStartNoteCount = 0

    init(store: SessionStore, publisher: MIDIPublisher, piano: PianoSampler, engine: TranscriptionEngine) {
        self.store = store
        self.publisher = publisher
        self.piano = piano
        self.engine = engine
    }

    // MARK: state the UI asks for

    var loopActive: Bool { loopEnabled }
    var playbackRate: Double { rate }

    /// Where the playing take sits, 0 to 1, for the panel's scrub hand.
    var progress: Double {
        guard let record = playing, let notes = cachedNotes(for: record), !notes.isEmpty else { return 0 }
        let total = max(0.5, notes.map(\.offset).max() ?? 0.5)
        return min(1, max(0, moment / total))
    }

    /// The playing moment: the onset of the last note already sent.
    private var moment: Double {
        guard let notes = sortedNotes(), !notes.isEmpty else { return 0 }
        let index = min(max(0, cursor - 1), notes.count - 1)
        return notes[index].onset
    }

    // MARK: session playback

    /// Plays a take, or stops it when it is the one playing.
    func play(_ record: SessionRecord) {
        if playing?.id == record.id {
            stop()
            refresh()
            return
        }
        guard !engine.isRunning else {
            presentError("Stop listening before playing a session")
            return
        }
        stop()
        guard store.notes(for: record) != nil else {
            presentError("Couldn't read the session file")
            return
        }
        playing = record
        notesCacheID = nil
        paused = false
        cursor = 0
        previousOnset = 0
        sentNotes = 0
        refresh()
        start(from: record, cursor: 0, previousOnset: 0)
    }

    /// Play-along: the session plays through the keys while the engine
    /// listens, so the player performs against their own or an imported take.
    func playAlong(_ record: SessionRecord) {
        if playAlong?.id == record.id {
            stop()
            refresh()
            return
        }
        guard !engine.isRunning else {
            presentError("Stop listening before playing along")
            return
        }
        stop()
        guard store.notes(for: record) != nil else {
            presentError("Couldn't read the session file")
            return
        }
        guard let assets = locateAssets() else {
            presentError("Model files not found next to the app")
            return
        }
        playAlong = record
        playAlongStartNoteCount = engine.notes.count
        view?.panelPlayAlong(true)
        engine.start(tensorsDir: assets.tensors, modelURL: assets.model)
        playAlongBegan()
        view?.sessionStarted()
        view?.syncTransport()
        start(from: record, cursor: 0, previousOnset: 0)
        presentError(engine.lastError)
    }

    /// The transport button under the timer: with a session playing it
    /// pauses, when paused it resumes from the cursor, and with nothing
    /// playing it starts the newest session in the archive.
    func togglePlayPause() {
        if let record = playing {
            if paused {
                paused = false
                start(from: record, cursor: cursor, previousOnset: previousOnset)
            } else {
                task?.cancel()
                task = nil
                paused = true
                // hanging notes would drone on in other apps: release all
                publisher.panic()
                piano.silence()
                view?.sessionStopped()
            }
        } else if let newest = store.sessions.first {
            play(newest)
            return
        }
        refresh()
    }

    /// Stops playback outright: pause, play-along or a running take.
    func stop() {
        task?.cancel()
        task = nil
        paused = false
        if playing != nil {
            publisher.panic()
        }
        piano.park()
        playing = nil
        notesCacheID = nil
        notesCache = []
        // loop points belong to the stopped playback; the next one starts clean
        loopA = nil
        loopB = nil
        loopEnabled = false
        // a play-along takes its listening down with it
        if playAlong != nil {
            playAlong = nil
            view?.panelPlayAlong(false)
            if engine.isRunning {
                engine.stop()
                publisher.panic()
                view?.sessionStopped()
                view?.syncTransport()
                playAlongEnded()
            }
        }
        view?.sessionStopped()
    }

    // MARK: loop, rate and scrubbing

    /// Marks the loop's start (true) or end (false) at the playing moment.
    func setLoopPoint(isA: Bool) {
        guard playing != nil else { return }
        let here = moment
        if isA {
            loopA = here
            view?.setStatus("Loop start at \(sessionTimeString(here))", error: false)
        } else {
            loopB = here
            if let a = loopA, here > a {
                view?.setStatus("Loop \(sessionTimeString(a)) – \(sessionTimeString(here)), press Loop to repeat it", error: false)
            } else {
                view?.setStatus("Loop end at \(sessionTimeString(here)), set a start before it", error: false)
            }
        }
        refresh()
    }

    func toggleLoop() {
        guard let a = loopA, let b = loopB, b > a else {
            presentError("Set loop points A and B first, B after A")
            return
        }
        loopEnabled.toggle()
        view?.setStatus(loopEnabled ? "Loop on, \(Int(rate * 100))% speed" : "Loop off", error: false)
        refresh()
    }

    func setRate(_ newRate: Double) {
        rate = newRate
    }

    /// The time machine: jump to a point in the take and keep playing from
    /// there, with the keybed and the endless measure following. Scrubbing
    /// only moves the transport; nothing is exported from a scrub.
    func scrub(to fraction: Double) {
        guard let record = playing, let notes = cachedNotes(for: record), !notes.isEmpty else { return }
        let total = max(0.5, notes.map(\.offset).max() ?? 0.5)
        let target = min(max(0, fraction), 1) * total
        var index = notes.firstIndex(where: { $0.onset >= target }) ?? (notes.count - 1)
        index = min(notes.count - 1, max(0, index))
        task?.cancel()
        task = nil
        publisher.panic()
        piano.silence()
        cursor = index
        previousOnset = max(0, target - 0.05)
        sentNotes = 0
        guard !paused else {
            view?.syncTransport()
            return
        }
        start(from: record, cursor: index, previousOnset: previousOnset)
    }

    // MARK: the loop itself

    /// The playback loop, resumable: `cursor` is the next note to send and
    /// `previousOnset` the onset of the note before it, so a paused session
    /// continues exactly where it stopped. With an A-B loop on, reaching B
    /// restarts from A, and the waits stretch by the practice rate.
    private func start(from record: SessionRecord, cursor: Int, previousOnset: Double) {
        guard let notes = store.notes(for: record) else {
            stop()
            refresh()
            return
        }
        let sorted = notes.sorted { $0.onset < $1.onset }
        let speed = max(0.25, min(2.0, rate))
        // the instrument loads its samples before the first note, never
        // inside one: a start that hitches reads as a broken transport
        piano.prepare()
        let looping = loopEnabled, loopA = loopA, loopB = loopB
        view?.sessionStopped()
        task = Task { [weak self] in
            var previous = previousOnset
            var index = cursor
            while index < sorted.count {
                let note = sorted[index]
                if looping, let b = loopB, let a = loopA, note.onset >= b {
                    // the loop's end: restart from the first note at or
                    // after A, keeping the loop's own lead-in silence
                    if let restart = sorted.firstIndex(where: { $0.onset >= a }) {
                        index = restart
                        previous = max(0, sorted[index].onset - 0.4)
                        continue
                    }
                }
                let wait = max(0, note.onset - previous) / speed
                previous = note.onset
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }
                self?.cursor = index + 1
                self?.previousOnset = previous
                self?.sentNotes += 1
                self?.publisher.noteStruck(note)
                self?.piano.noteOn(pitch: note.pitch, velocity: note.velocity)
                self?.view?.noteStruck(note)
                self?.view?.setNoteCount(self?.sentNotes ?? 0)
                let held = note
                let heldFor = max(held.duration, 0.05) / speed
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(heldFor * 1_000_000_000))
                    // a release belongs to the run that struck it: when the
                    // outer task was cancelled (pause or stop), let it go
                    guard self?.task?.isCancelled == false else { return }
                    self?.publisher.noteReleased(held)
                    self?.piano.noteOff(pitch: held.pitch)
                    self?.view?.noteReleased(held)
                }
                index += 1
            }
            // let the last note ring, then hand the keys back
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.finished()
        }
    }

    /// A playback ran to its end: stop the machinery; a play-along scores
    /// itself before the keys come back.
    private func finished() {
        if playAlong != nil {
            scorePlayAlong()
        }
        stop()
        refresh()
    }

    /// Scores a finished play-along: every note the player struck matches
    /// the nearest same-pitch reference note within 150 ms; the fit is the
    /// match rate, the timing the mean of the struck-too-late amounts.
    private func scorePlayAlong() {
        let played = Array(engine.notes.dropFirst(min(playAlongStartNoteCount, engine.notes.count)))
        guard playAlong != nil, !played.isEmpty else {
            view?.setStatus("Play-along ended without any played notes", error: false)
            return
        }
        guard let reference = playAlong.flatMap({ store.notes(for: $0) }) else {
            view?.setStatus("Couldn't reread the reference notes", error: true)
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
        view?.setStatus(line, error: false)
    }

    // MARK: notes

    /// The sorted notes of the playing take, for the loop's moment bookkeeping.
    private func sortedNotes() -> [NoteEvent]? {
        guard let record = playing, let notes = store.notes(for: record) else { return nil }
        return notes.sorted { $0.onset < $1.onset }
    }

    /// The playing take's notes, sorted by onset, read once per session.
    private func cachedNotes(for record: SessionRecord) -> [NoteEvent]? {
        if notesCacheID == record.id { return notesCache }
        guard let notes = store.notes(for: record) else { return nil }
        notesCache = notes.sorted { $0.onset < $1.onset }
        notesCacheID = record.id
        return notesCache
    }
}
