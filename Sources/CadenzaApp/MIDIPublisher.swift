import CadenzaCore
import CoreMIDI
import Foundation

/// Publishes transcribed notes over a CoreMIDI virtual source so other apps
/// (DAWs, notation editors) hear Cadenza as a MIDI keyboard. A confirmed
/// note sounds immediately; its release is scheduled on the main queue and
/// is pushed later when a pedal tail extends the note.
final class MIDIPublisher {
    private(set) var client = MIDIClientRef()
    private(set) var source = MIDIEndpointRef()
    private(set) var ready = false
    private(set) var lastError: String?

    /// per pitch: the scheduled note-off work item
    private var scheduledOffs: [Int: DispatchWorkItem] = [:]

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

    /// A fresh strike: release anything scheduled on the pitch, sound it,
    /// schedule its release.
    func noteStruck(_ event: NoteEvent) {
        guard ready else { return }
        let pitch = event.pitch
        cancelOff(pitch: pitch)
        sendNote(pitch: pitch, velocity: event.velocity, on: false)
        sendNote(pitch: pitch, velocity: event.velocity, on: true)
        scheduleOff(pitch: pitch, after: max(0.05, event.duration))
    }

    /// A sounding note lasts longer than previously known: move its release.
    func noteExtended(_ event: NoteEvent) {
        guard ready else { return }
        scheduleOff(pitch: event.pitch, after: max(0.05, event.duration))
    }

    /// Releases everything still scheduled.
    func panic() {
        for item in scheduledOffs.values { item.cancel() }
        scheduledOffs = [:]
        for pitch in 0...127 {
            sendNote(pitch: pitch, velocity: 64, on: false)
        }
    }

    private func scheduleOff(pitch: Int, after delay: Double) {
        cancelOff(pitch: pitch)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scheduledOffs.removeValue(forKey: pitch)
            self.sendNote(pitch: pitch, velocity: 64, on: false)
        }
        scheduledOffs[pitch] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelOff(pitch: Int) {
        if let item = scheduledOffs.removeValue(forKey: pitch) {
            item.cancel()
        }
    }

    private func sendNote(pitch: Int, velocity: Int, on: Bool) {
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
