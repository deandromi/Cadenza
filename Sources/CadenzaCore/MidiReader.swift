import Foundation

/// A MIDI standard file read into note events plus the framing metadata it
/// carries: tempo changes, time signatures, key signatures. Pure Swift, no
/// audio stack — the same ground the engraver tests itself against, because
/// published MIDI carries its own tempo, meter and key meta events.
public struct MidiFile: Sendable {
    /// Notes with onset and duration in seconds, sorted by onset, velocity
    /// 1...127, onset groups not yet assigned.
    public var notes: [NoteEvent]
    public var ticksPerQuarter: Int
    /// Tempo changes as (tick, quarter-notes per minute), ascending.
    public var tempoChanges: [(tick: Int, bpm: Double)]
    /// Time signature changes as (tick, signature), ascending.
    public var timeSignatures: [(tick: Int, signature: TimeSignature)]
    /// Key signature changes as (tick, key), ascending.
    public var keySignatures: [(tick: Int, key: KeySignature)]
    /// Sustain-pedal spans in seconds, from CC64 down to its release. Notes
    /// already carry the pedal's effect folded into their durations; this
    /// keeps the pedal itself so the sheet can engrave real pedal lines.
    public var sustainPedals: [(start: Double, end: Double)]

    public init(
        notes: [NoteEvent],
        ticksPerQuarter: Int,
        tempoChanges: [(tick: Int, bpm: Double)],
        timeSignatures: [(tick: Int, signature: TimeSignature)],
        keySignatures: [(tick: Int, key: KeySignature)],
        sustainPedals: [(start: Double, end: Double)] = []
    ) {
        self.notes = notes
        self.ticksPerQuarter = ticksPerQuarter
        self.tempoChanges = tempoChanges
        self.timeSignatures = timeSignatures
        self.keySignatures = keySignatures
        self.sustainPedals = sustainPedals
    }

    /// The file's tempo at its start; 120 when it carries no tempo event.
    public var initialTempo: Double {
        tempoChanges.first?.bpm ?? 120
    }
}

public enum MidiReaderError: Error, Sendable, Equatable {
    case notMidi
    case unsupportedDivision
    case truncated
}

/// Standard MIDI File reader: format 0 and 1, running status, all meta
/// events the framing comparison needs, sustain-pedal-aware note pairing.
public enum MidiReader {

    public static func read(_ data: Data) throws -> MidiFile {
        var reader = ByteReader(data)
        guard reader.take(4) == Array("MThd".utf8) else { throw MidiReaderError.notMidi }
        let headerLength = Int(reader.u32())
        guard headerLength >= 6 else { throw MidiReaderError.truncated }
        let format = Int(reader.u16())
        let trackCount = Int(reader.u16())
        let division = Int(reader.u16())
        if division & 0x8000 != 0 { throw MidiReaderError.unsupportedDivision }
        let ticksPerQuarter = division
        reader.skip(max(0, headerLength - 6))

        var tempoChanges: [(tick: Int, bpm: Double)] = []
        var timeSignatures: [(tick: Int, signature: TimeSignature)] = []
        var keySignatures: [(tick: Int, key: KeySignature)] = []
        // raw notes in ticks: (onTick, offTick, pitch, velocity)
        var raw: [(on: Int, off: Int, pitch: Int, velocity: Int)] = []
        // sustain pedal events across all tracks: (tick, isDown)
        var pedalEvents: [(tick: Int, isDown: Bool)] = []
        var trackEndTick = 0

        for _ in 0..<trackCount {
            guard reader.take(4) == Array("MTrk".utf8) else { throw MidiReaderError.notMidi }
            let length = Int(reader.u32())
            let end = reader.offset + length
            guard end <= reader.count else { throw MidiReaderError.truncated }
            var tick = 0
            var runningStatus: UInt8 = 0
            // open notes keyed by channel and pitch, oldest first
            var open: [Int: [(tick: Int, velocity: Int)]] = [:]
            while reader.offset < end {
                tick += reader.vlq()
                var status = reader.u8()
                if status < 0x80 {
                    // running status: the byte is the first data byte
                    reader.offset -= 1
                    guard runningStatus != 0 else { throw MidiReaderError.truncated }
                    status = runningStatus
                } else if status < 0xF0 {
                    runningStatus = status
                }

                switch status {
                case 0x80...0x8F, 0x90...0x9F, 0xA0...0xBF, 0xE0...0xEF:
                    let channel = status & 0x0F
                    let kind = status & 0xF0
                    let data1 = reader.u8()
                    let data2: UInt8
                    if kind == 0xC0 || kind == 0xD0 {
                        data2 = 0
                        reader.offset -= 1
                    } else {
                        data2 = reader.u8()
                    }
                    if kind == 0x90 && data2 > 0 {
                        open[(Int(channel) << 8) | Int(data1), default: []].append((tick, Int(data2)))
                    } else if kind == 0x80 || (kind == 0x90 && data2 == 0) {
                        let key = (Int(channel) << 8) | Int(data1)
                        if var pending = open[key], !pending.isEmpty {
                            let (onTick, velocity) = pending.removeFirst()
                            open[key] = pending.isEmpty ? nil : pending
                            raw.append((onTick, max(tick, onTick + 1), Int(data1), velocity))
                        }
                    } else if kind == 0xB0 && data1 == 64 {
                        pedalEvents.append((tick, data2 >= 64))
                    }
                case 0xFF:
                    let type = reader.u8()
                    let length = reader.vlq()
                    let payload = reader.take(length)
                    switch type {
                    case 0x51 where length == 3:
                        let microseconds = (Int(payload[0]) << 16) | (Int(payload[1]) << 8) | Int(payload[2])
                        if microseconds > 0 {
                            tempoChanges.append((tick, 60_000_000.0 / Double(microseconds)))
                        }
                    case 0x58 where length >= 2:
                        let beats = Int(payload[0])
                        let unit = 1 << Int(payload[1])
                        timeSignatures.append((tick, TimeSignature(beatsPerMeasure: beats, beatUnit: unit)))
                    case 0x59 where length >= 2:
                        let sf = Int(Int8(bitPattern: payload[0]))
                        let minor = payload[1] == 1
                        // circle of fifths to tonic: major tonic is 7f mod 12,
                        // minor tonic is 3 semitones below its relative major
                        let majorTonic = ((sf * 7) % 12 + 12) % 12
                        let tonic = minor ? (majorTonic - 3 + 12) % 12 : majorTonic
                        keySignatures.append((tick, KeySignature(tonic: tonic, isMinor: minor)))
                    default:
                        break
                    }
                    runningStatus = 0
                case 0xF0, 0xF7:
                    let length = reader.vlq()
                    reader.skip(length)
                    runningStatus = 0
                default:
                    break
                }
            }
            reader.offset = end
            trackEndTick = max(trackEndTick, tick)
            // notes still open at the end of the track close at the track end
            for (key, pending) in open {
                for (onTick, velocity) in pending {
                    raw.append((onTick, max(tick, onTick + 1), key & 0xFF, velocity))
                }
            }
        }

        // sustain pedal: a note released while the pedal is down keeps
        // sounding until the pedal lifts
        let pedals = pedalEvents.sorted { $0.tick < $1.tick }
        func pedalIsDown(atTick tick: Int) -> Bool {
            var down = false
            for event in pedals {
                if event.tick > tick { break }
                down = event.isDown
            }
            return down
        }
        func pedalLifts(atOrAfter tick: Int) -> Int {
            for event in pedals where event.tick >= tick {
                if !event.isDown { return event.tick }
            }
            return trackEndTick
        }
        let sustained = raw.map { note -> (on: Int, off: Int, pitch: Int, velocity: Int) in
            if pedalIsDown(atTick: note.off) {
                return (note.on, max(note.off, pedalLifts(atOrAfter: note.off)), note.pitch, note.velocity)
            }
            return note
        }

        // ticks to seconds through the tempo map
        let tempos = tempoChanges.sorted { $0.tick < $1.tick }
        func seconds(atTick tick: Int) -> Double {
            var seconds = 0.0
            var lastTick = 0
            var microsecondsPerQuarter = 500_000  // 120 bpm default
            for change in tempos {
                if change.tick >= tick { break }
                seconds += Double(change.tick - lastTick) * Double(microsecondsPerQuarter) / 1_000_000.0 / Double(ticksPerQuarter)
                lastTick = change.tick
                microsecondsPerQuarter = Int(60_000_000.0 / change.bpm)
            }
            seconds += Double(tick - lastTick) * Double(microsecondsPerQuarter) / 1_000_000.0 / Double(ticksPerQuarter)
            return seconds
        }

        // sustain spans: each pedal-down opens one, its release closes it;
        // a pedal still down at the end closes at the track end
        var sustainPedals: [(start: Double, end: Double)] = []
        var openPedal: Int?
        for event in pedals {
            if event.isDown {
                if openPedal == nil { openPedal = event.tick }
            } else if let start = openPedal {
                if event.tick > start {
                    sustainPedals.append((seconds(atTick: start), seconds(atTick: event.tick)))
                }
                openPedal = nil
            }
        }
        if let start = openPedal {
            sustainPedals.append((seconds(atTick: start), seconds(atTick: trackEndTick)))
        }

        let notes = sustained
            .map { note in
                NoteEvent(
                    pitch: note.pitch,
                    velocity: note.velocity,
                    onset: seconds(atTick: note.on),
                    duration: seconds(atTick: note.off) - seconds(atTick: note.on)
                )
            }
            .sorted { ($0.onset, $0.pitch) < ($1.onset, $1.pitch) }

        return MidiFile(
            notes: notes,
            ticksPerQuarter: ticksPerQuarter,
            tempoChanges: tempos,
            timeSignatures: timeSignatures.sorted { $0.tick < $1.tick },
            keySignatures: keySignatures.sorted { $0.tick < $1.tick },
            sustainPedals: sustainPedals.sorted { $0.start < $1.start }
        )
    }

    public static func read(url: URL) throws -> MidiFile {
        try read(Data(contentsOf: url))
    }
}

/// Byte cursor over the file with big-endian reads and VLQ decoding.
private struct ByteReader {
    let bytes: [UInt8]
    var offset = 0

    init(_ data: Data) {
        self.bytes = [UInt8](data)
    }

    var count: Int { bytes.count }

    mutating func u8() -> UInt8 {
        guard offset < bytes.count else { return 0 }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() -> UInt16 {
        (UInt16(u8()) << 8) | UInt16(u8())
    }

    mutating func u32() -> UInt32 {
        (UInt32(u16()) << 16) | UInt32(u16())
    }

    /// Variable-length quantity: 7 bits per byte, high bit continues.
    mutating func vlq() -> Int {
        var value = 0
        while true {
            let byte = u8()
            value = (value << 7) | Int(byte & 0x7F)
            if byte & 0x80 == 0 { return value }
        }
    }

    mutating func take(_ count: Int) -> [UInt8] {
        let end = min(offset + count, bytes.count)
        let slice = Array(bytes[offset..<end])
        offset = end
        return slice
    }

    mutating func skip(_ count: Int) {
        offset = min(offset + count, bytes.count)
    }
}
