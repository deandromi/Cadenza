import CadenzaCore
import CoreMIDI
import Darwin
import Foundation
import QuartzCore

/// Publishes transcribed notes over a CoreMIDI virtual source so other apps
/// hear Cadenza as a MIDI keyboard.
///
/// Decoding confirms a note only after its whole 16 s window has passed, and
/// the confirmation lag differs per note, so notes are rendered onto a
/// delayed copy of the performance clock: a note at performance time t
/// sounds at wall time `performanceOrigin + t + presentationDelay`. The delay
/// is constant, so the performance's own rhythm and overlap come out intact,
/// just uniformly late.
///
/// Packets are handed to CoreMIDI the moment a note is confirmed, carrying
/// the future timestamp of their delayed play time; CoreMIDI delivers them
/// sample-accurately on its own schedule, so main-thread load cannot affect
/// note timing.
///
/// Releases are held back until the decoding horizon has moved past the
/// note's end: a later window can still prolong the note (pedal tails), and
/// a timestamp already handed to CoreMIDI cannot be taken back. The engine
/// reports the covered span after every window, and every release behind the
/// horizon is final and is sent.
final class MIDIPublisher {
    private(set) var client = MIDIClientRef()
    private(set) var source = MIDIEndpointRef()
    private(set) var ready = false
    private(set) var lastError: String?

    /// Wall clock time (CACurrentMediaTime) of performance second zero.
    var performanceOrigin: Double = 0

    /// Constant presentation latency in seconds. It must exceed the worst
    /// confirmation lag: a window spans 16 s, the tick adds up to 1 s of
    /// submission slack before the decoder takes it, the release decoder
    /// takes about 1.2 s per window, and a margin remains — 20 s measured
    /// against the real pipeline.
    static let presentationDelay: Double = 20.0

    /// A release is final once the covered span reaches this far past its
    /// end: the next window to decode starts 16 s behind its covered edge,
    /// so a note end below `covered - 9` can no longer overlap it.
    private static let revisionHorizon: Double = 9.0

    /// mach ticks per second, the unit CoreMIDI timestamps live in
    private let ticksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1_000_000_000.0 * Double(info.denom) / Double(info.numer)
    }()

    /// pitch -> the still-held release, in performance seconds
    private var heldReleases: [Int: Double] = [:]

    func setup() {
        guard !ready else { return }
        var status = MIDIClientCreate("Cadenza" as CFString, nil, nil, &client)
        guard status == noErr else {
            lastError = "MIDI client creation failed (\(status))"
            return
        }
        status = MIDISourceCreate(client, "Cadenza keyboard" as CFString, &source)
        guard status == noErr else {
            lastError = "MIDI source creation failed (\(status))"
            return
        }
        ready = true
    }

    /// Wall clock time at which performance time `t` sounds.
    private func playWall(forPerformance t: Double) -> Double {
        performanceOrigin + t + Self.presentationDelay
    }

    /// CoreMIDI timestamp for a wall time; 0 means play immediately.
    private func timestamp(forWall wall: Double) -> MIDITimeStamp {
        let delta = wall - CACurrentMediaTime()
        guard delta > 0 else { return 0 }
        return mach_absolute_time() + MIDITimeStamp((delta * ticksPerSecond).rounded())
    }

    /// A newly confirmed note: hand its strike to CoreMIDI dated at its
    /// delayed play time, and hold its release until it is final. A re-struck
    /// pitch releases the previous note just before it sounds again.
    func noteStruck(_ event: NoteEvent) {
        guard ready else { return }
        let strikeWall = playWall(forPerformance: event.onset)
        if let heldEnd = heldReleases.removeValue(forKey: event.pitch) {
            let releaseWall = min(playWall(forPerformance: heldEnd), strikeWall - 0.001)
            sendNote(event.pitch, 64, on: false, wall: releaseWall)
        }
        heldReleases[event.pitch] = event.offset
        sendNote(event.pitch, event.velocity, on: true, wall: strikeWall)
    }

    /// A sounding note lasts longer than previously known: move the held
    /// release. The event carries the full sounding interval.
    func noteExtended(_ event: NoteEvent) {
        heldReleases[event.pitch] = event.offset
    }

    /// The engine covered `coveredSeconds` of performance audio: every held
    /// release behind the revision horizon is final now, date it at its
    /// delayed play time and hand it over.
    func decodingHorizon(coveredSeconds: Double) {
        guard ready, !heldReleases.isEmpty else { return }
        let finalThrough = coveredSeconds - Self.revisionHorizon
        let due = heldReleases.filter { $0.value < finalThrough }
        for (pitch, end) in due {
            heldReleases.removeValue(forKey: pitch)
            sendNote(pitch, 64, on: false, wall: playWall(forPerformance: end))
        }
    }

    /// Drops every held release and silences the source.
    func panic() {
        heldReleases.removeAll()
        for pitch in 0...127 {
            sendNote(pitch, 64, on: false, wall: 0)
        }
    }

    private func sendNote(_ pitch: Int, _ velocity: Int, on: Bool, wall: Double) {
        guard ready else { return }
        let clampedPitch = UInt8(max(0, min(127, pitch)))
        let clampedVelocity = UInt8(max(1, min(127, velocity)))
        let status: UInt8 = on ? 0x90 : 0x80
        var packetList = MIDIPacketList()
        packetList.numPackets = 1
        packetList.packet.timeStamp = timestamp(forWall: wall)
        packetList.packet.length = 3
        packetList.packet.data.0 = status
        packetList.packet.data.1 = clampedPitch
        packetList.packet.data.2 = clampedVelocity
        MIDIReceived(source, &packetList)
    }
}
