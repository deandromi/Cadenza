import CadenzaCore
import CoreMIDI
import Foundation

/// Publishes transcribed notes over a CoreMIDI virtual source so other apps
/// hear Cadenza as a MIDI keyboard.
///
/// The streaming merge emits an event the moment a decode confirms it, which
/// is about the attack plus the decode time, so notes go out the instant
/// they are emitted: CoreMIDI timestamps add nothing to a live strike. A
/// re-struck pitch receives its note-off before the new note-on, and
/// panic() silences everything the source could still be holding.
final class MIDIPublisher {
    private(set) var client = MIDIClientRef()
    private(set) var source = MIDIEndpointRef()
    private(set) var ready = false
    private(set) var lastError: String?

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

    /// A newly confirmed strike: sounds immediately.
    func noteStruck(_ event: NoteEvent) {
        guard ready else { return }
        sendNote(on: true, pitch: event.pitch, velocity: event.velocity)
    }

    /// A sounding note ended: silences the key immediately.
    func noteReleased(_ event: NoteEvent) {
        guard ready else { return }
        sendNote(on: false, pitch: event.pitch, velocity: 64)
    }

    /// A continuation refinement does not re-sound a key that is held.
    func noteExtended(_ event: NoteEvent) {}

    /// Silences the source.
    func panic() {
        guard ready else { return }
        for pitch in 0...127 {
            sendNote(on: false, pitch: pitch, velocity: 64)
        }
    }

    private func sendNote(on: Bool, pitch: Int, velocity: Int) {
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
