import CadenzaCore
import Foundation

/// Writes note events to a Standard MIDI File, format 0 with one track.
///
/// Timing uses 480 ticks per quarter note at 120 bpm, which makes one second
/// exactly 960 ticks. Multi-byte values are big-endian and every event carries
/// a full status byte, so no running status is used.
public enum MidiFileWriter {
    /// Largest delta time a single event may carry, also the four-byte
    /// variable-length quantity ceiling.
    private static let maxDelta = 0x0F_FF_FF_FF

    private static let ticksPerQuarter = 480

    private static let ticksPerSecond = 960.0

    /// Writes `notes` as a format 0 MIDI file to `url`, replacing any file there.
    public static func write(_ notes: [NoteEvent], to url: URL) throws {
        var track: [UInt8] = []

        // Tempo meta event, 500000 microseconds per quarter note (120 bpm),
        // so one second of audio maps to 960 ticks.
        track.append(contentsOf: [0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20])

        var events: [(tick: Int, isOn: Bool, pitch: Int, velocity: Int)] = []
        for note in notes {
            let onsetTick = tick(ofSeconds: note.onset)
            let durationTicks = max(1, tick(ofSeconds: note.duration))
            events.append((onsetTick, true, note.pitch, note.velocity))
            events.append((onsetTick + durationTicks, false, note.pitch, 64))
        }
        // Note-offs precede note-ons at the same tick so a reiterated pitch
        // releases before it is struck again.
        events.sort { lhs, rhs in
            if lhs.tick != rhs.tick { return lhs.tick < rhs.tick }
            if lhs.isOn != rhs.isOn { return !lhs.isOn }
            return lhs.pitch < rhs.pitch
        }

        var previousTick = 0
        for event in events {
            let delta = min(max(event.tick - previousTick, 0), maxDelta)
            track.append(contentsOf: variableLengthQuantity(delta))
            previousTick = event.tick
            let status: UInt8 = event.isOn ? 0x90 : 0x80
            let velocity = UInt8(min(max(event.velocity, 1), 127))
            track.append(contentsOf: [status, UInt8(event.pitch & 0x7F), velocity])
        }

        // End of track meta event.
        track.append(contentsOf: [0x00, 0xFF, 0x2F, 0x00])

        var bytes: [UInt8] = []
        bytes.append(contentsOf: chunk(id: "MTrk", payload: track))
        bytes.append(contentsOf: chunk(id: "MThd", payload: headerPayload()))
        try Data(bytes).write(to: url)
    }

    /// Rounds seconds to integer ticks under the file's 960 ticks per second.
    private static func tick(ofSeconds seconds: Double) -> Int {
        max(0, Int((seconds * ticksPerSecond).rounded()))
    }

    /// Assembles a track-length-prefixed chunk header around a payload.
    private static func chunk(id: String, payload: [UInt8]) -> [UInt8] {
        var header = Array(id.utf8.prefix(4))
        header.append(contentsOf: bigEndianBytes(UInt32(payload.count)))
        return header
    }

    /// Format 0, one track, 480 ticks per quarter note.
    private static func headerPayload() -> [UInt8] {
        var payload: [UInt8] = [0x00, 0x00, 0x00, 0x06]
        payload.append(contentsOf: bigEndianBytes(UInt16(0)))
        payload.append(contentsOf: bigEndianBytes(UInt16(1)))
        payload.append(contentsOf: bigEndianBytes(UInt16(ticksPerQuarter)))
        return payload
    }

    private static func bigEndianBytes(_ value: UInt16) -> [UInt8] {
        [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }

    /// Encodes a non-negative value as a variable-length quantity of one to
    /// four bytes, seven bits per byte with the continuation bit set on all
    /// but the last.
    private static func variableLengthQuantity(_ value: Int) -> [UInt8] {
        var value = min(max(value, 0), maxDelta)
        var encoded: [UInt8] = [UInt8(value & 0x7F)]
        value >>= 7
        while value > 0 {
            encoded.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        return encoded.reversed()
    }
}
