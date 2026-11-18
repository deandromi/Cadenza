# Cadenza — project instructions

These instructions apply to every file in this repository.

## What this is

A macOS app that listens to piano audio, transcribes it to MIDI in real time using a
Transkun-style neural semi-CRF model ported to CoreML, renders a live chord sheet, and
exposes a CoreMIDI virtual source that other apps can play.

## Language and platform

- Swift 6, strict concurrency (`Swift.Sendable` everywhere data crosses a boundary).
- SwiftUI for all UI, targeting macOS 26+ so Liquid Glass APIs are native.
- CadenzaCore must stay free of AppKit/SwiftUI/AVFoundation imports: pure Swift types,
  deterministic and unit-testable. Audio (AVAudioEngine), ML (CoreML) and MIDI
  (CoreMIDI) live behind protocols that CadenzaCore defines and the app layer injects.

## UI copy: sentence case, always

All user-facing strings use sentence case. Never Title Case, never ALL CAPS.

- Buttons and menu items: "Add track", not "Add Track"
- Settings rows: "Input device", not "Input Device"
- Errors keep normal sentence punctuation and never shout: "Couldn't hear any notes" not "ERROR: NO INPUT"

Keep copy short and human. No exclamation marks, no emoji anywhere in the UI.

## Design language: Liquid Glass

The app is Liquid Glass inspired. Rules:

- Use the native materials, never fake them: `.glassEffect()` and
  `glassEffectContainer` for floating layers,`.regularMaterial` and thinner materials
  for large surfaces. No hand-rolled blur stacks, gradient overlays, or stacked
  shadows pretending to be glass.
- Chrome floats on content, it does not tile the window: toolbars and floating
  controls are glass lenses over the chord sheet; the content area is the star.
- Prefer translucency over opaque filled cards. If a card is opaque "just in case",
  it is wrong.
- One accent color, used sparingly for state (listening, recording, errors), not for
  decoration.
- Respect light and dark mode, increased contrast, and reduced transparency from day
  one — test all three before calling a screen done.
- Spacing is generous, type is native system type at default sizes. No custom fonts.

## Architecture

Data flows one way:

```
audio in -> transcription engine -> NoteEvent stream -> MIDI endpoint + chord engine -> UI
```

- UI never talks to CoreMIDI, AVAudioEngine or CoreML directly; it consumes observable
  state from the app layer.
- Chord inference sees only `NoteEvent` values (pitch, velocity, onset, duration,
  shared-onset grouping). It must be testable from recorded MIDI with no audio stack.
- New subsystems land in `Sources/CadenzaCore` with tests before the UI uses them.

## Verification

`CadenzaCoreChecks` is the source of truth: `swift run CadenzaCoreChecks` must pass
before a change to CadenzaCore is done. It is a plain assertion-based executable so it
runs under Xcode Command Line Tools, which cannot run XCTest or Swift Testing targets.
Convert it to a proper `testTarget` once a full Xcode install is available here.
Changes to the app target are compile-checked with `swift build` only under a full Xcode
toolchain (SwiftUI macros need it); `swift build` on Command Line Tools is expected to
fail for CadenzaApp and is not a regression signal.
