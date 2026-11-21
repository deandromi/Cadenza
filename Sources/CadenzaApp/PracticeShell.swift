import AppKit
import CadenzaCore

/// What the paper surfaces ask of the app that owns them: the practice
/// screen's panel, the sessions archive. State reads as properties, actions
/// as methods, and every member has a do-nothing default, so a preview or a
/// test shell only spells out what it actually has an opinion about.
///
/// Listening is recording: the one action starts and stops the session that
/// export hands over.
@MainActor
protocol PracticeShell: AnyObject {
    // MARK: listening
    var isListening: Bool { get }
    func toggleListening()
    var exportEnabled: Bool { get }
    func export()

    // MARK: playback
    /// Play or stop a preserved session.
    func playSession(_ record: SessionRecord)
    /// The session playing right now, if any.
    var playingSession: SessionRecord? { get }
    /// Pause a playing session, or resume a paused one; with nothing
    /// playing, starts the newest session.
    func togglePlayPause()
    /// Stop playback outright, paused or not.
    func stopPlayback()
    var playbackPaused: Bool { get }
    /// Where playback sits, 0 to 1.
    var playbackProgress: Double { get }
    func scrubPlayback(_ fraction: Double)
    /// A-B looping over the playing session: marks at the current moment,
    /// the loop toggle, and the practice rate.
    func setLoopPoint(isA: Bool)
    func toggleLoop()
    var loopActive: Bool { get }
    func setPlaybackRate(_ rate: Double)

    // MARK: the archive
    func renameSession(_ record: SessionRecord, to name: String)
    /// Removes a session and everything it owns on disk.
    func deleteSession(_ record: SessionRecord)
    /// The archive's batch actions: delete a set, or rename it from one stem
    /// with -1, -2 appended in list order.
    func deleteSessions(_ records: [SessionRecord])
    func renameSessions(_ records: [SessionRecord], base: String)
    func copySessionMIDI(_ record: SessionRecord)
    func openSessionSheet(_ record: SessionRecord)
    func playAlong(_ record: SessionRecord)
    func exportSession(_ record: SessionRecord, choice: ExportChoice)
    /// Whether the session folder holds an audio recording.
    func sessionHasAudio(_ record: SessionRecord) -> Bool
    /// Import a MIDI file as a session.
    func importMIDI()
    /// Reads a take back from its MIDI and describes it: key, tempo,
    /// harmony, phrasing, cadences, texture, register.
    func describeSession(_ record: SessionRecord) -> TakeDescription?

    // MARK: retroactive capture and the click
    func keepLastMinute()
    var canKeepLastMinute: Bool { get }
    var keepMinuteEnabled: Bool { get }
    func toggleMetronome()
    var metronomeActive: Bool { get }
    var metronomeTempo: Double { get }
    func setMetronomeTempo(_ bpm: Double)

    // MARK: status
    /// One line in the panel's status area, for actions that only need to
    /// tell the player what happened.
    func showStatus(_ text: String, isError: Bool)
}

extension PracticeShell {
    var isListening: Bool { false }
    func toggleListening() {}
    var exportEnabled: Bool { false }
    func export() {}

    func playSession(_ record: SessionRecord) {}
    var playingSession: SessionRecord? { nil }
    func togglePlayPause() {}
    func stopPlayback() {}
    var playbackPaused: Bool { false }
    var playbackProgress: Double { 0 }
    func scrubPlayback(_ fraction: Double) {}
    func setLoopPoint(isA: Bool) {}
    func toggleLoop() {}
    var loopActive: Bool { false }
    func setPlaybackRate(_ rate: Double) {}

    func renameSession(_ record: SessionRecord, to name: String) {}
    func deleteSession(_ record: SessionRecord) {}
    func deleteSessions(_ records: [SessionRecord]) {}
    func renameSessions(_ records: [SessionRecord], base: String) {}
    func copySessionMIDI(_ record: SessionRecord) {}
    func openSessionSheet(_ record: SessionRecord) {}
    func playAlong(_ record: SessionRecord) {}
    func exportSession(_ record: SessionRecord, choice: ExportChoice) {}
    func sessionHasAudio(_ record: SessionRecord) -> Bool { false }
    func importMIDI() {}
    func describeSession(_ record: SessionRecord) -> TakeDescription? { nil }

    func keepLastMinute() {}
    var canKeepLastMinute: Bool { false }
    var keepMinuteEnabled: Bool { true }
    func toggleMetronome() {}
    var metronomeActive: Bool { false }
    var metronomeTempo: Double { 96 }
    func setMetronomeTempo(_ bpm: Double) {}

    func showStatus(_ text: String, isError: Bool) {}
}
