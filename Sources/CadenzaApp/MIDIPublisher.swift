import CadenzaCore
import CoreMIDI
import Foundation
import QuartzCore

/// Publishes transcribed notes over a CoreMIDI virtual source so other apps
/// hear Cadenza as a MIDI keyboard.
///
/// Decoding confirms a note only when its whole 16 s window has passed, and
/// the confirmation lag varies per note — so sending each note the moment it
/// is confirmed would scramble the relative timing of a phrase. Instead the
/// publisher renders notes onto a delayed copy of the performance clock:
/// a note at performance time t sounds at wall time `performanceOrigin +
/// t + presentationDelay`. The delay is constant, so the performance's own
/// rhythm and overlap come out intact, just uniformly late.
final class MIDIPublisher {
    private(set) var client = MIDIClientRef()
    private(set) var source = MIDIEndpointRef()
    private(set) var ready = false
    private(set) var lastError: String?

    /// Wall clock time (CACurrentMediaTime) of performance second zero.
    var performanceOrigin: Double = 0

    /// Constant presentation latency in seconds, chosen above the largest
    /// possible confirmation lag (a note confirmed at its window's very end).
    static let presentationDelay = 16.5

    /// per pitch: the scheduled work items (on and off)
    private var pending: [Int: [DispatchWorkItem]] = [:]

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

    /// Wall-clock seconds from now at which performance time `t` sounds.
    private func leadTime(forPerformanceSeconds t: Double) -> Double {
        max(0, performanceOrigin + t + Self.presentationDelay - CACurrentMediaTime())
    }

    /// A newly confirmed note: schedule its strike and its release at their
    /// delayed performance times, replacing anything pending on the pitch.
    func noteStruck(_ event: NoteEvent) {
        guard ready else { return }
        cancelPitch(event.pitch)
        var items: [DispatchWorkItem] = []
        let strike = DispatchWorkItem { [weak self] in
            self?.sendNote(event.pitch, event.velocity, on: true)
        }
        items.append(strike)
        let release = scheduledRelease(pitch: event.pitch, at: event.onset + max(event.duration, 0.05))
        items.append(release)
        pending[event.pitch] = items
        DispatchQueue.main.asyncAfter(deadline: .now() + leadTime(forPerformanceSeconds: event.onset), execute: strike)
    }

    /// A sounding note last longer than previously known: move its release.
    /// The event carries the full sounding interval (onset and new duration).
    func noteExtended(_ event: NoteEvent) {
        guard ready else { return }
        // keep the pending strike, replace only the release
        if let items = pending[event.pitch] {
            pending[event.pitch] = items.filter { !$0.isCancelled }
        }
        let release = scheduledRelease(pitch: event.pitch, at: event.onset + event.duration)
        pending[event.pitch, default: []].append(release)
    }

    /// Releases everything still scheduled and silences the source.
    func panic() {
        for items in pending.values {
            for item in items { item.cancel() }
        }
        pending = [:]
        for pitch in 0...127 {
            sendNote(pitch, 64, on: false)
        }
    }

    private func scheduledRelease(pitch: Int, at end: Double) -> DispatchWorkItem {
        let release = DispatchWorkItem { [weak self] in
            self?.sendNote(pitch, 64, on: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + leadTime(forPerformanceSeconds: end), execute: release)
        return release
    }

    private func cancelPitch(_ pitch: Int) {
        for item in pending[pitch] ?? [] { item.cancel() }
        pending[pitch] = nil
    }

    private func sendNote(_ pitch: Int, _ velocity: Int, on: Bool) {
        guard ready else { return }
        let clampedPitch = UInt8(max(0, min(127, pitch)))
        let clampedVelocity = UInt8(max(1, min(127, velocity)))
        let status: UInt8 = on ? 0x90 : 0x80
        var packetList = MIDIPacketList()
        packetList.numPackets = 1
        packetList.packet.timeStamp = 0
        packetList.packet.length = 3
        packetList.packet.data.0 = status
        packetList.packet.data.1 = clampedPitch
        packetList.packet.data.2 = clampedVelocity
        MIDIReceived(source, &packetList)
    }
}
