# Cadenza
An application that listens to you play piano and makes a chord scheme in real time and acts as a midi input for applications.

Real-time piano transcription for macOS: listens to a piano performance, renders a live
chord sheet, and exposes a CoreMIDI virtual source so other apps can receive the played
notes as if from a hardware keyboard.

Transcription approach is based on [Transkun](https://github.com/Yujia-Yan/Transkun)
(neural semi-CRF interval scoring, MIT license). See `NOTICE`.

## Layout

```
Sources/CadenzaCore/    Transcription-agnostic core: note events, chord inference, MIDI types
Sources/CadenzaApp/     App entry point and all AppKit UI (native glass views)
Sources/CadenzaCoreChecks/  Assertion-based checks for CadenzaCore (runs via swift run)
project.yml             XcodeGen spec — the .xcodeproj is generated, never committed
```

## Building

```bash
swift build                  # all targets
swift run CadenzaCoreChecks  # assertion checks for CadenzaCore
xcodegen generate            # regenerate Cadenza.xcodeproj
```

A full Xcode install is not required: `swift build` and the checks work with the
Command Line Tools alone. The generated Cadenza.xcodeproj exists for optional
GUI-side work in Xcode (schemes, Instruments, code signing).

## Committing

Generated files (`*.xcodeproj`, `.build/`, `DerivedData/`) are gitignored. Commit
`project.yml` and sources only.
