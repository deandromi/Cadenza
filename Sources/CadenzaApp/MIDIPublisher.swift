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
///
/// The source is published as a plain MIDI 1.0 endpoint with a short name and
/// real manufacturer metadata: Web MIDI stacks (BandLab, Ableton in a
/// browser, MIDI monitor pages) are much pickier about what they list than
/// desktop DAWs, and an endpoint that carries its protocol and identity from
/// creation is listed by every one of them.
final class MIDIPublisher {
    private(set) var client = MIDIClientRef()
    private(set) var source = MIDIEndpointRef()
    private(set) var ready = false
    private(set) var lastError: String?

    /// What other apps see in their device pickers. Short on purpose: web
    /// MIDI device lists truncate hard and a name that survives truncation
    /// stays recognisable.
    static let portName = "Cadenza"

    func setup() {
        guard !ready else { return }
        var status = MIDIClientCreate("Cadenza" as CFString, nil, nil, &client)
        guard status == noErr else {
            lastError = "MIDI client creation failed (\(status))"
            return
        }
        status = Self.makeSource(client: client, into: &source)
        guard status == noErr else {
            lastError = "MIDI source creation failed (\(status))"
            return
        }
        advertise()
        ready = true
        lastError = nil
    }

    /// Creates the virtual source as an explicit MIDI 1.0 endpoint. On macOS
    /// 11 and later an endpoint's protocol is fixed when it is created, so
    /// asking for 1.0 here is what makes a browser that speaks only MIDI 1.0
    /// list it at all; setting the property afterwards is too late.
    private static func makeSource(client: MIDIClientRef, into source: inout MIDIEndpointRef) -> OSStatus {
        let status = MIDISourceCreateWithProtocol(client, portName as CFString, ._1_0, &source)
        if status == noErr { return status }
        // older systems have no protocol-aware creation
        return MIDISourceCreate(client, portName as CFString, &source)
    }

    private func advertise() {
        MIDIObjectSetIntegerProperty(source, kMIDIPropertyPrivate, 0)
        MIDIObjectSetStringProperty(source, kMIDIPropertyName, Self.portName as CFString)
        MIDIObjectSetStringProperty(source, kMIDIPropertyManufacturer, "Cadenza" as CFString)
        MIDIObjectSetStringProperty(source, kMIDIPropertyModel, "Virtual piano keyboard" as CFString)
    }

    /// Republishes the port: pages that enumerated their MIDI devices when
    /// they loaded pick up a state change when the endpoint disappears and
    /// comes back, so a web app already open can find Cadenza without a
    /// reload. Disposes the old source first so no half-dead endpoint stays
    /// in the list.
    @discardableResult
    func refresh() -> Bool {
        if source != 0 {
            MIDIEndpointDispose(source)
            source = 0
        }
        ready = false
        guard client != 0 else {
            setup()
            return ready
        }
        var fresh = MIDIEndpointRef()
        let status = Self.makeSource(client: client, into: &fresh)
        guard status == noErr else {
            lastError = "MIDI source creation failed (\(status))"
            // the client may have died under us: rebuild it from scratch
            MIDIClientDispose(client)
            client = 0
            setup()
            return ready
        }
        source = fresh
        advertise()
        ready = true
        lastError = nil
        return true
    }

    /// Releases the endpoint and the client, for app termination.
    func shutdown() {
        guard client != 0 else { return }
        if source != 0 {
            MIDIEndpointDispose(source)
            source = 0
        }
        MIDIClientDispose(client)
        client = 0
        ready = false
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

    /// The source's display name as the rest of the system sees it, for the
    /// diagnostics and the settings row.
    var publishedName: String? {
        guard source != 0 else { return nil }
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(source, kMIDIPropertyName, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
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

/// End-to-end proof that the virtual port works: listens on the published
/// source the way a browser or DAW would, sends a few notes, and reports what
/// came back. Cross-process visibility cannot be checked from inside the app,
/// but the packet path can, and it is the half that silently breaks.
enum MIDILoopbackCheck {
    @discardableResult
    static func run() -> Bool {
        let publisher = MIDIPublisher()
        publisher.setup()
        guard publisher.ready, let name = publisher.publishedName else {
            print("midi check FAILED: no source (\(publisher.lastError ?? "unknown"))")
            return false
        }
        print("midi check: published \"\(name)\"")

        final class Box: @unchecked Sendable {
            var received: [(UInt8, UInt8, UInt8)] = []
            var port = MIDIPortRef()
        }
        let box = Box()
        var status = MIDIInputPortCreateWithProtocol(publisher.client, "probe" as CFString, ._1_0, &box.port) { list, _ in
            for packet in list.unsafeSequence() {
                let wordCount = Int(packet.pointee.wordCount)
                guard wordCount > 0 else { continue }
                withUnsafeBytes(of: packet.pointee.words) { raw in
                    let words = raw.bindMemory(to: UInt32.self)
                    for index in 0..<wordCount {
                        // MIDI 1.0 channel voice inside a UMP word: 0x2s s p p v v
                        let word = words[index]
                        let status = UInt8((word >> 16) & 0xFF)
                        let pitch = UInt8((word >> 8) & 0xFF)
                        let velocity = UInt8(word & 0xFF)
                        box.received.append((status, pitch, velocity))
                    }
                }
            }
        }
        guard status == noErr else {
            print("midi check FAILED: input port creation (\(status))")
            return false
        }
        status = MIDIPortConnectSource(box.port, publisher.source, nil)
        guard status == noErr else {
            print("midi check FAILED: connecting to the source (\(status))")
            return false
        }
        publisher.noteStruck(NoteEvent(pitch: 60, velocity: 90, onset: 0, duration: 0.2))
        publisher.noteStruck(NoteEvent(pitch: 64, velocity: 80, onset: 0, duration: 0.2))
        publisher.noteReleased(NoteEvent(pitch: 60, velocity: 80, onset: 0, duration: 0.2))
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let onNotes = box.received.filter { $0.0 == 0x90 }
        let offNotes = box.received.filter { $0.0 == 0x80 }
        let pitches = onNotes.map { $0.1 }
        print("midi check: received \(box.received.count) packets, note-ons \(pitches)")
        var passed = pitches.contains(60) && pitches.contains(64) && offNotes.contains { $0.1 == 60 }
        if !passed {
            print("midi check FAILED: notes did not arrive")
        }

        // the menu's republish path: the endpoint must come back and still
        // carry notes, which is what a web app's state-change handler needs
        let refreshed = publisher.refresh()
        let renamed = publisher.publishedName ?? "-"
        box.received.removeAll()
        MIDIPortConnectSource(box.port, publisher.source, nil)
        publisher.noteStruck(NoteEvent(pitch: 67, velocity: 70, onset: 0, duration: 0.2))
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let afterRefresh = box.received.filter { $0.0 == 0x90 }.map { $0.1 }
        let refreshPassed = refreshed && renamed == MIDIPublisher.portName && afterRefresh.contains(67)
        print("midi check: after republish \"\(renamed)\" received \(afterRefresh)")
        if !refreshPassed {
            print("midi check FAILED: the republished port does not carry notes")
            passed = false
        }
        print(passed ? "midi check PASSED" : "midi check FAILED")
        publisher.shutdown()
        return passed
    }
}
