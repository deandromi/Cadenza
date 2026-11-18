import AppKit

if CommandLine.arguments.contains("--smoke") {
    SmokeMain.run(audioPath: nil)
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
