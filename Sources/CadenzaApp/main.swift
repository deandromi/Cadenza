import AppKit

if CommandLine.arguments.contains("--designs") {
    freopen("/tmp/cadenza_designs.log", "a", stdout)
    freopen("/tmp/cadenza_designs.log", "a", stderr)
    setvbuf(stdout, nil, _IONBF, 0)
    let app = NSApplication.shared
    let gallery = DesignGalleryController()
    app.delegate = gallery
    app.setActivationPolicy(.regular)
    // the window must be born inside the run loop, like the main app's:
    // views built before it never join the live layout engine
    app.run()
    exit(0)
}

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

if let index = CommandLine.arguments.firstIndex(of: "--sheet"), CommandLine.arguments.count > index + 1 {
    SmokeMain.runSheet(path: CommandLine.arguments[index + 1])
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--replay"), CommandLine.arguments.count > index + 2 {
    SmokeMain.runReplay(path: CommandLine.arguments[index + 1], deviceRate: Double(CommandLine.arguments[index + 2]) ?? 48000)
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--replay-stream"), CommandLine.arguments.count > index + 2 {
    SmokeMain.runReplayStream(path: CommandLine.arguments[index + 1], deviceRate: Double(CommandLine.arguments[index + 2]) ?? 48000)
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
