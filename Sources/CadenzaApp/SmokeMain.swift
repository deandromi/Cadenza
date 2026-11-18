import AVFoundation
import CadenzaCore
import CoreML
import Foundation

enum SmokeMain {
    /// Live capture smoke: requests mic access, captures for ~24 s, prints
    /// level and note output. Exercises the permission flow, the tap and
    /// the ring without any UI.
    @MainActor
    static func runCapture() {
        let permission = AVAudioApplication.shared.recordPermission
        let permissionName: String
        switch permission {
        case .undetermined: permissionName = "undetermined"
        case .granted: permissionName = "granted"
        case .denied: permissionName = "denied"
        @unknown default: permissionName = "unknown"
        }
        print("permission before: \(permissionName)")
        guard let assets = AppDelegate.locateAssets() else {
            print("capture smoke: model assets not found")
            exit(1)
        }
        let engine = TranscriptionEngine()
        engine.onNoteEvent = { event, kind in
            let label: String
            if case .struck = kind { label = "on" } else { label = "extend" }
            print(String(format: "note %@: %d v%d @%.2f", label, event.pitch, event.velocity, event.onset))
        }
        engine.start(tensorsDir: assets.tensors, modelURL: assets.model)
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                print(String(format: "capture: level %.4f, notes %d, running %@", engine.level, engine.noteCount, engine.isRunning ? "yes" : "no"))
                if let error = engine.lastError { print("error: \(error)") }
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(24))
        timer.invalidate()
        engine.stop()
        print(String(format: "capture smoke done: %d notes", engine.noteCount))
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

    private static func fmt(_ rate: Double, _ interleaved: Bool) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: interleaved)!
    }

    /// Offline full-pipeline simulation: feeds the fixture through the tap
    /// ring as if a 48 kHz device had captured it, takes window 0 the way
    /// the engine's tick would, and decodes it. Expected: the three golden
    /// notes.
    static func runSimulate() {
        guard let assets = AppDelegate.locateAssets() else {
            print("simulate: model assets not found")
            exit(1)
        }
        let audioURL = URL(fileURLWithPath: rootPath("Fixtures/golden/audio_window.f32"))
        guard let fixture = try? Data(contentsOf: audioURL) else {
            print("simulate: fixture missing")
            exit(1)
        }
        let fixture44 = fixture.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        print("simulate: \(fixture44.count) fixture samples at 44100")

        let context: InferenceContext
        do {
            context = try InferenceContext(tensorsDir: assets.tensors, modelURL: assets.model)
        } catch {
            print("simulate FAILED: \(error)")
            exit(1)
        }

        // The fixture is window 0's padded view: 8 s of silence + 8 s of
        // music. As live audio, only the performance part (the last 8 s)
        // arrives through the tap; the engine adds the leading pad itself.
        let performance44 = Array(fixture44[(8 * 44100)...])
        guard let performance48 = InferenceContext.resample(performance44, from: 44100, to: 48000) else {
            print("simulate FAILED: upsample to 48 kHz failed")
            exit(1)
        }
        print("simulate: \(performance48.count) device samples at 48000")

        let tapState = AudioTapState()
        tapState.reset(rate: 48000)
        // feed in tap-sized chunks, like the realtime tap does
        var index = 0
        while index < performance48.count {
            let end = min(index + 8192, performance48.count)
            tapState.append(Array(performance48[index..<end]))
            index = end
        }

        guard let window = tapState.takeWindow(index: 0) else {
            print("simulate FAILED: window 0 not available")
            exit(1)
        }
        print("simulate: window 0 is \(window.count) device samples")

        guard let result = context.run(windowIndex: 0, samples: window, deviceRate: 48000,
                                       forcedStartPos: Array(repeating: WindowGeometry.padFrames, count: WindowGeometry.symbols.count)) else {
            print("simulate FAILED: no decode result")
            exit(1)
        }
        for event in result.events {
            let duration = event.offsetSeconds - event.onsetSeconds
            print(String(format: "simulate note: %d@%.3f-%.3f v%d", event.pitch, event.onsetSeconds, event.onsetSeconds + duration, event.velocity))
        }
        let pitches = Set(result.events.map({ $0.pitch }))
        if pitches == [60, 64, 67] {
            print("simulate PASSED")
        } else {
            print("simulate FAILED: expected pitches 60, 64, 67, got \(pitches.sorted())")
            exit(1)
        }
    }

    private static func rootPath(_ relative: String) -> String {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Models/tensors").path) {
                return dir.appendingPathComponent(relative).path
            }
            dir = dir.deletingLastPathComponent()
        }
        return relative
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

            let result = context.run(windowIndex: 0, samples: audio,
                                     deviceRate: 44100,
                                     forcedStartPos: Array(repeating: WindowGeometry.padFrames, count: WindowGeometry.symbols.count))
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

    private static func readF32(_ url: URL) -> [Float] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }
    }
}
