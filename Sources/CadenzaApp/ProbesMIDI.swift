import AppKit
import AVFoundation
import CadenzaCore
import UniformTypeIdentifiers
import CoreML
import Foundation
import CoreText

extension SmokeMain {
/// The MIDI side of the probes: writing a file from audio, reading one back,
/// the converter and the simulated session.
    /// Synthesizes a MIDI file into a raw f32 mono capture at the given rate:
    /// each note becomes a piano-ish tone (six decaying harmonics), which is
    /// the cleanest audio the engine can ever see — the "at its best" case.
    /// Prints every ground-truth note as "gt note:" lines for offline
    /// precision/recall matching against --replay-stream output.
    /// Usage: --synth-midi <file.mid> <out.f32> [rate] [maxSeconds]
    static func runSynthMidi(path: String, out: String, rate: Double, maxSeconds: Double?) {
        guard let file = try? MidiReader.read(url: URL(fileURLWithPath: path)) else {
            print("synth-midi FAILED: cannot read \(path)")
            exit(1)
        }
        let limit = maxSeconds ?? .infinity
        let notes = file.notes.filter { $0.onset < limit }
        let tail = 2.0
        let total = min(notes.map { $0.onset + $0.duration }.max() ?? 0, limit) + tail
        let count = Int(total * rate)
        var buffer = [Float](repeating: 0, count: count)
        for note in notes {
            let freq = 440.0 * pow(2.0, (Double(note.pitch) - 69.0) / 12.0)
            let amp = Double(note.velocity) / 127.0 * 0.4
            let start = Int(note.onset * rate)
            let end = min(count, Int((note.onset + note.duration) * rate))
            let dur = max(0.05, note.duration)
            let tau = min(1.8, max(0.25, dur * 0.6))
            var phase = 0.0
            let step = 2.0 * Double.pi * freq / rate
            for i in start..<end {
                let t = Double(i - start) / rate
                var s = 0.0
                for k in 1...6 {
                    s += sin(Double(k) * phase) / Double(k)
                }
                let env = exp(-t / tau) * min(1.0, t / 0.005 + 0.05)
                buffer[i] += Float(amp * env * s * 0.22)
                phase += step
            }
            print(String(format: "gt note: %d @%.3f-%.3f v%d", note.pitch, note.onset, note.onset + note.duration, note.velocity))
        }
        let data = Data(bytes: buffer, count: buffer.count * MemoryLayout<Float>.size)
        do {
            try data.write(to: URL(fileURLWithPath: out))
            print("synth-midi: \(notes.count) notes -> \(out) (\(count) samples at \(Int(rate)) Hz)")
        } catch {
            print("synth-midi FAILED: \(error)")
            exit(1)
        }
    }

    /// MIDI file writer check: three notes in, structurally parsed back out.
    static func runMidiProbe() {
        var notes: [NoteEvent] = [
            NoteEvent(pitch: 60, velocity: 39, onset: 0.0, duration: 2.0),
            NoteEvent(pitch: 64, velocity: 48, onset: 0.5, duration: 1.0),
            NoteEvent(pitch: 67, velocity: 46, onset: 0.0, duration: 2.5),
        ]
        notes.sort { $0.onset < $1.onset }
        let url = URL(fileURLWithPath: "/tmp/cadenza_smoke.mid")
        do {
            try MidiFileWriter.write(notes, to: url)
            let data = try Data(contentsOf: url)
            let bytes = [UInt8](data)

            func be16(_ i: Int) -> UInt16 { UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]) }
            func be32(_ i: Int) -> UInt32 { UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3]) }

            guard bytes.count > 14,
                  String(decoding: bytes[0..<4], as: UTF8.self) == "MThd",
                  be32(4) == 6,
                  be16(8) == 0, be16(10) == 1, be16(12) == 480,
                  String(decoding: bytes[14..<18], as: UTF8.self) == "MTrk",
                  Int(be32(18)) == bytes.count - 22 else {
                print("midi probe FAILED: structure invalid")
                exit(1)
            }
            // the track payload must carry the three note-ons and their
            // note-offs exactly once each
            let payload = Array(bytes[22...])
            var on60 = 0, on64 = 0, on67 = 0
            var off60 = 0
            for i in 0..<(payload.count - 2) {
                if payload[i] == 0x90 {
                    if payload[i + 1] == 60 { on60 += 1 }
                    if payload[i + 1] == 64 { on64 += 1 }
                    if payload[i + 1] == 67 { on67 += 1 }
                } else if payload[i] == 0x80 {
                    if payload[i + 1] == 60 { off60 += 1 }
                }
            }
            guard on60 == 1, on64 == 1, on67 == 1, off60 == 1 else {
                print("midi probe FAILED: on/off counts wrong (\(on60), \(on64), \(on67), off60 \(off60))")
                exit(1)
            }
            print("midi probe PASSED: \(bytes.count) bytes, 3 note-ons, 1 note-off found")
        } catch {
            print("midi probe FAILED: \(error)")
            exit(1)
        }
    }

    /// Converter matrix probe: which buffer sizes, directions and layouts
    /// the AVAudioConverter accepts on this machine.
    static func runConverterProbe() {
        let cases: [(String, AVAudioFormat, AVAudioFormat)] = [
            ("deinterleaved", Self.fmt(44100, false), Self.fmt(48000, false)),
            ("interleaved", Self.fmt(44100, true), Self.fmt(48000, true)),
            ("standard", AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!,
                               AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!),
        ]
        for (name, src, dst) in cases {
            guard let conv = AVAudioConverter(from: src, to: dst) else {
                print("probe: \(name) converter nil")
                continue
            }
            for n in [1000, 352800] {
                guard let ib = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(n)) else { continue }
                ib.frameLength = AVAudioFrameCount(n)
                // capacity must cover both the converted length and, for the
                // convenience API, the input length itself
                let cap = AVAudioFrameCount(max(Double(n) * dst.sampleRate / src.sampleRate, Double(n))) + 4096
                guard let ob = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: cap) else { continue }
                do {
                    try conv.convert(to: ob, from: ib)
                    print("probe: \(name) n=\(n) ok out=\(ob.frameLength)")
                } catch {
                    print("probe: \(name) n=\(n) FAIL \(error.localizedDescription)")
                }
            }
        }
        // callback flavor, deinterleaved, the way v1 used it
        let src = Self.fmt(44100, false), dst = Self.fmt(48000, false)
        if let conv = AVAudioConverter(from: src, to: dst) {
            conv.sampleRateConverterAlgorithm = "cplx"
            for n in [1000, 352800] {
                guard let ib = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(n)) else { continue }
                ib.frameLength = AVAudioFrameCount(n)
                let cap = AVAudioFrameCount(Double(n) * 48000 / 44100) + 8192
                guard let ob = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: cap) else { continue }
                do {
                    try conv.convert(to: ob, from: ib)
                    print("probe: sinc algorithm n=\(n) ok out=\(ob.frameLength)")
                } catch {
                    print("probe: sinc algorithm n=\(n) FAIL \(error.localizedDescription)")
                }
            }
        }
    }

    static func fmt(_ rate: Double, _ interleaved: Bool) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: interleaved)!
    }

    /// Headless check of the app's own inference path: feeds the golden
    /// fixture window through InferenceContext.run exactly as captured
    /// audio would arrive, then prints the notes it produces.
    ///
    /// Expected result for the fixture (verified against the Python
    /// transcribe() reference): 60@0.000-3.986 v39, 64@0.000-3.985 v48,
    /// 67@0.000-4.003 v46.
    static func run(audioPath: String?) {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var dir = CommandLine.arguments.count > 2
            ? URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            : root
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Models/tensors").path) { break }
            dir = dir.deletingLastPathComponent()
        }
        let tensors = dir.appendingPathComponent("Models/tensors", isDirectory: true)
        let model = dir.appendingPathComponent("Models/TranskunBackbone.mlpackage", isDirectory: true)
        let audioURL = URL(fileURLWithPath: audioPath ?? "Fixtures/golden/audio_window.f32")
        print("smoke: tensors \(tensors.path)")
        print("smoke: model \(model.path)")

        do {
            let context = try InferenceContext(tensorsDir: tensors, modelURL: model)
            let audio = readF32(audioURL)
            print("smoke: \(audio.count) samples from \(audioURL.path)")

            let result = context.run(windowIndex: 0, edgeSeconds: WindowPlan.standard.segmentSeconds - WindowPlan.standard.padSeconds,
                                     samples: audio,
                                     deviceRate: 44100,
                                     forcedStartPos: Array(repeating: WindowPlan.standard.padFrames, count: WindowGeometry.symbols.count),
                                     plan: .standard)
            guard let result else {
                print("smoke FAILED: no result")
                exit(1)
            }
            for event in result.events {
                let duration = event.offsetSeconds - event.onsetSeconds
                print(String(format: "smoke note: %d@%.3f-%.3f v%d", event.pitch, event.onsetSeconds, event.onsetSeconds + duration, event.velocity))
            }
            let pitches = Set(result.events.map(\.pitch))
            guard pitches == [60, 64, 67] else {
                print("smoke FAILED: expected pitches 60, 64, 67, got \(pitches.sorted())")
                exit(1)
            }
            print("smoke PASSED")
        } catch {
            print("smoke FAILED: \(error)")
            exit(1)
        }
    }
}
