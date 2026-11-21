import AppKit

if CommandLine.arguments.contains("--smoke") {
    SmokeMain.run(audioPath: nil)
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--score"), CommandLine.arguments.count > index + 2 {
    SmokeMain.runScore(
        path: CommandLine.arguments[index + 1],
        deviceRate: Double(CommandLine.arguments[index + 2]) ?? 48000
    )
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--midiscore"), CommandLine.arguments.count > index + 1 {
    SmokeMain.runMidiScore(path: CommandLine.arguments[index + 1])
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--pdf"), CommandLine.arguments.count > index + 2 {
    SmokeMain.runPDF(path: CommandLine.arguments[index + 1], out: CommandLine.arguments[index + 2])
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--sheet"), CommandLine.arguments.count > index + 1 {
    SmokeMain.runSheet(path: CommandLine.arguments[index + 1])
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--replay"), CommandLine.arguments.count > index + 2 {
    SmokeMain.runReplay(path: CommandLine.arguments[index + 1], deviceRate: Double(CommandLine.arguments[index + 2]) ?? 48000)
    exit(0)
}

if CommandLine.arguments.contains("--morph-shot") {
    SmokeMain.runMorphShot()
    exit(0)
}
if CommandLine.arguments.contains("--menu-check") {
    SmokeMain.runMenuCheck()
    exit(0)
}
if CommandLine.arguments.contains("--overlay-shot") {
    SmokeMain.runOverlayShot()
    exit(0)
}
if CommandLine.arguments.contains("--screen-shot") {
    SmokeMain.runScreenShot()
    exit(0)
}
if CommandLine.arguments.contains("--sheet-window-probe") {
    SheetBench.windowProbe()
    exit(0)
}
if CommandLine.arguments.contains("--draft-bench") {
    SheetBench.run()
    exit(0)
}
if CommandLine.arguments.contains("--piano-play") {
    PianoProbe.play()
    exit(0)
}
if CommandLine.arguments.contains("--midi-check") {
    exit(MIDILoopbackCheck.run() ? 0 : 1)
}

if CommandLine.arguments.contains("--piano-probe") {
    PianoProbe.run()
    exit(0)
}
if CommandLine.arguments.contains("--ui-timings") {
    UITimings.run()
    exit(0)
}
if CommandLine.arguments.contains("--strip-shot") {
    SmokeMain.runStripShot()
    exit(0)
}
if let index = CommandLine.arguments.firstIndex(of: "--replay-stream"), CommandLine.arguments.count > index + 2 {
    SmokeMain.runReplayStream(path: CommandLine.arguments[index + 1], deviceRate: Double(CommandLine.arguments[index + 2]) ?? 48000)
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--eval"), CommandLine.arguments.count > index + 2 {
    SmokeMain.runEval(
        audioPath: CommandLine.arguments[index + 1],
        midiPath: CommandLine.arguments[index + 2],
        deviceRate: CommandLine.arguments.count > index + 3 ? Double(CommandLine.arguments[index + 3]) ?? 48000 : 48000
    )
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--probe-short"), CommandLine.arguments.count > index + 1 {
    // --probe-short <audio.f32> [rate] [crops] [segmentSeconds] [modelName]
    let seconds = CommandLine.arguments.count > index + 4 ? Double(CommandLine.arguments[index + 4]) ?? 4.0 : 4.0
    let modelName = CommandLine.arguments.count > index + 5 ? CommandLine.arguments[index + 5] : "TranskunBackbone.mlpackage"
    let plan = WindowPlan(
        segmentSeconds: seconds,
        padSeconds: min(1.0, seconds / 4),
        streamingStep: 0.3,
        streamingWarmup: 0.45,
        ringHistorySeconds: seconds * 3
    )
    SmokeMain.runProbeShort(
        audioPath: CommandLine.arguments[index + 1],
        deviceRate: CommandLine.arguments.count > index + 2 ? Double(CommandLine.arguments[index + 2]) ?? 44100 : 44100,
        crops: CommandLine.arguments.count > index + 3 ? Int(CommandLine.arguments[index + 3]) ?? 6 : 6,
        plan: plan,
        modelURL: SmokeMain.modelByName(modelName)!
    )
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--decode-dump"), CommandLine.arguments.count > index + 3 {
    SmokeMain.runDecodeDump(
        audioPath: CommandLine.arguments[index + 1],
        deviceRate: Double(CommandLine.arguments[index + 2]) ?? 48000,
        edge: Double(CommandLine.arguments[index + 3]) ?? 16
    )
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--mel-probe"), CommandLine.arguments.count > index + 3 {
    SmokeMain.runMelProbe(
        audioPath: CommandLine.arguments[index + 1],
        deviceRate: Double(CommandLine.arguments[index + 2]) ?? 48000,
        at: Double(CommandLine.arguments[index + 3]) ?? 0
    )
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--synth-midi"), CommandLine.arguments.count > index + 2 {
    SmokeMain.runSynthMidi(
        path: CommandLine.arguments[index + 1],
        out: CommandLine.arguments[index + 2],
        rate: CommandLine.arguments.count > index + 3 ? Double(CommandLine.arguments[index + 3]) ?? 48000 : 48000,
        maxSeconds: CommandLine.arguments.count > index + 4 ? Double(CommandLine.arguments[index + 4]) : nil
    )
    exit(0)
}

if CommandLine.arguments.contains("--midi") {
    SmokeMain.runMidiProbe()
    exit(0)
}

if CommandLine.arguments.contains("--probe") {
    SmokeMain.runConverterProbe()
    exit(0)
}

if CommandLine.arguments.contains("--simulate") {
    SmokeMain.runSimulate()
    exit(0)
}

if CommandLine.arguments.contains("--capture") {
    MainActor.assumeIsolated {
        SmokeMain.runCapture()
    }
    exit(0)
}

// GUI mode: tee console output to a fixed file so diagnostics can be read
// no matter how the app was launched.
freopen("/tmp/cadenza_gui.log", "a", stdout)
freopen("/tmp/cadenza_gui.log", "a", stderr)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
