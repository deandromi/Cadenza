import CadenzaCore
import Foundation

/// Writes note events to a Standard MIDI File, format 0 with one track.
///
/// Timing uses 480 ticks per quarter note at the tempo the take implies, so
/// the file and the printed page speak of the same beat: a sheet marked 189
/// that opens at 120 in a DAW is two documents, not one. Multi-byte values are
/// big-endian and every event carries a full status byte, so no running status
/// is used.
public enum MidiFileWriter {
    /// Largest delta time a single event may carry, also the four-byte
    /// variable-length quantity ceiling.
    private static let maxDelta = 0x0F_FF_FF_FF

    private static let ticksPerQuarter = 480

    /// Writes `notes` as a format 0 MIDI file to `url`, replacing any file there.
    /// Without a framing the file is 120 bpm in 4/4, the neutral reading.
    public static func write(_ notes: [NoteEvent], to url: URL,
                             framing: ScoreFraming? = nil) throws {
        var track: [UInt8] = []

        let bpm = min(300, max(20, framing?.beatsPerMinute ?? 120))
        let microsPerQuarter = Int((60_000_000.0 / bpm).rounded())
        track.append(contentsOf: [0x00, 0xFF, 0x51, 0x03,
                                  UInt8((microsPerQuarter >> 16) & 0xFF),
                                  UInt8((microsPerQuarter >> 8) & 0xFF),
                                  UInt8(microsPerQuarter & 0xFF)])
        if let meter = framing?.timeSignature {
            // FF 58 04 nn dd cc bb: the meter, its denominator as a power of
            // two, and 24 clocks per metronome click (LilyPond's 4 = default).
            let denominatorPower = UInt8(max(0, Int(log2(Double(max(1, meter.beatUnit))))))
            track.append(contentsOf: [0x00, 0xFF, 0x58, 0x04,
                                      UInt8(min(255, meter.beatsPerMeasure)),
                                      denominatorPower, 24, 8])
        }

        let ticksPerSecond = Double(ticksPerQuarter) * bpm / 60.0
        func tick(ofSeconds seconds: Double) -> Int { max(0, Int((seconds * ticksPerSecond).rounded())) }

        // The note's own length is the key's: a score and another app's
        // playback both read it that way. Whatever the pedal added is written
        // where a pedal belongs — as CC64 — so a chord struck once and held by
        // the pedal sounds exactly as long as before while reading as one
        // chord instead of a chain of ties.
        enum Message {
            case noteOn(pitch: Int, velocity: Int)
            case noteOff(pitch: Int)
            case pedal(down: Bool)
        }
        var wire: [(tick: Int, rank: Int, pitch: Int, message: Message)] = []
        for note in notes {
            let onset = tick(ofSeconds: note.onset)
            wire.append((onset, 2, note.pitch, .noteOn(pitch: note.pitch, velocity: note.velocity)))
            wire.append((onset + max(1, tick(ofSeconds: note.keyDuration)), 0, note.pitch,
                         .noteOff(pitch: note.pitch)))
        }
        for span in Self.pedalSpans(of: notes, ticksPerSecond: ticksPerSecond) {
            wire.append((span.start, 1, 0, .pedal(down: true)))
            wire.append((span.end, 1, 0, .pedal(down: false)))
        }
        // Note-offs precede note-ons at the same tick so a reiterated pitch
        // releases before it is struck again, and the pedal moves between them.
        wire.sort { lhs, rhs in
            if lhs.tick != rhs.tick { return lhs.tick < rhs.tick }
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.pitch < rhs.pitch
        }

        var previousTick = 0
        for item in wire {
            let delta = min(max(item.tick - previousTick, 0), maxDelta)
            track.append(contentsOf: variableLengthQuantity(delta))
            previousTick = item.tick
            switch item.message {
            case .noteOff(let pitch):
                track.append(contentsOf: [0x80, UInt8(pitch & 0x7F), 64])
            case .noteOn(let pitch, let velocity):
                track.append(contentsOf: [0x90, UInt8(pitch & 0x7F),
                                          UInt8(min(max(velocity, 1), 127))])
            case .pedal(let down):
                track.append(contentsOf: [0xB0, 64, down ? 127 : 0])
            }
        }

        // End of track meta event.
        track.append(contentsOf: [0x00, 0xFF, 0x2F, 0x00])

        // Header chunk first, then the track chunk; each chunk is
        // id + length + payload.
        var bytes: [UInt8] = []
        bytes.append(contentsOf: chunk(id: "MThd", payload: headerPayload()))
        bytes.append(contentsOf: chunk(id: "MTrk", payload: track))
        try Data(bytes).write(to: url)
    }

    /// The pedal's own spans, in ticks: every note that outlived its key says
    /// how long the string kept ringing, and spans that touch or overlap are
    /// one press, because a pedal cannot lift and return within a tick.
    private static func pedalSpans(of notes: [NoteEvent],
                                   ticksPerSecond: Double) -> [(start: Int, end: Int)] {
        func tick(ofSeconds seconds: Double) -> Int {
            max(0, Int((seconds * ticksPerSecond).rounded()))
        }
        var spans: [(start: Int, end: Int)] = []
        for note in notes where note.isPedalled {
            let down = tick(ofSeconds: note.onset + note.keyDuration)
            let up = tick(ofSeconds: note.offset)
            if up > down { spans.append((down, up)) }
        }
        spans.sort { $0.start < $1.start }
        var merged: [(start: Int, end: Int)] = []
        for span in spans {
            if let last = merged.last, span.start <= last.end {
                merged[merged.count - 1].end = max(last.end, span.end)
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    /// Assembles a length-prefixed chunk: id, big-endian payload length,
    /// then the payload itself.
    private static func chunk(id: String, payload: [UInt8]) -> [UInt8] {
        var bytes = Array(id.utf8.prefix(4))
        bytes.append(contentsOf: bigEndianBytes(UInt32(payload.count)))
        bytes.append(contentsOf: payload)
        return bytes
    }

    /// Format 0, one track, 480 ticks per quarter note. Six bytes total.
    private static func headerPayload() -> [UInt8] {
        var payload: [UInt8] = []
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
