// Assertion-based checks for CadenzaCore, runnable with Xcode Command Line
// Tools via `swift run CadenzaCoreChecks`. Replaces a XCTest/Swift Testing
// target until a full Xcode install is available on this machine.
import Foundation
import CadenzaCore

var failures = 0
var checks = 0

@MainActor func expect(_ condition: Bool, _ name: String) {
    checks += 1
    if !condition {
        failures += 1
        print("failed: \(name)")
    }
}

// MARK: NoteEvent

expect(NoteEvent(pitch: 60, velocity: 64, onset: 0, duration: 1).pitchClass == 0, "pitch class C")
expect(NoteEvent(pitch: 61, velocity: 64, onset: 0, duration: 1).pitchClass == 1, "pitch class C sharp")
expect(NoteEvent(pitch: 108, velocity: 64, onset: 0, duration: 1).pitchClass == 0, "pitch class wraps at C8")

do {
    let notes = [
        NoteEvent(pitch: 60, velocity: 80, onset: 0.00, duration: 1),
        NoteEvent(pitch: 64, velocity: 80, onset: 0.04, duration: 1),
        NoteEvent(pitch: 67, velocity: 80, onset: 0.08, duration: 1), // chained: 40 ms from second
        NoteEvent(pitch: 72, velocity: 80, onset: 0.20, duration: 1),
    ].assignOnsetGroups()
    expect(notes[0].onsetGroup == notes[1].onsetGroup, "first two notes share a group")
    expect(notes[1].onsetGroup == notes[2].onsetGroup, "chain rule groups third note")
    expect(notes[2].onsetGroup != notes[3].onsetGroup, "40 ms gap and 120 ms gap split groups")
}

// MARK: Chords

do {
    // C major, bass not first in input order
    let notes = [
        NoteEvent(pitch: 64, velocity: 80, onset: 0.0, duration: 1.0),  // E4
        NoteEvent(pitch: 48, velocity: 90, onset: 0.01, duration: 1.0), // C3
        NoteEvent(pitch: 55, velocity: 70, onset: 0.02, duration: 1.0), // G3
    ].assignOnsetGroups()
    expect(Chord.identify(in: notes, group: 1)?.symbol == "C", "major triad in any order")
}

do {
    // Cm7 stacked, bass not lowest in input order
    let notes = [
        NoteEvent(pitch: 58, velocity: 80, onset: 0.0, duration: 1.0),  // B flat 3
        NoteEvent(pitch: 63, velocity: 80, onset: 0.01, duration: 1.0), // E flat 4
        NoteEvent(pitch: 48, velocity: 90, onset: 0.02, duration: 1.0), // C3
        NoteEvent(pitch: 55, velocity: 80, onset: 0.03, duration: 1.0), // G3
    ].assignOnsetGroups()
    expect(Chord.identify(in: notes, group: 1)?.symbol == "Cm7", "minor seventh from stacked notes")
}

do {
    // G7: G B D F. Same pitch-class set spells B diminished under B,
    // so this exercises the bass tiebreak.
    let notes = [
        NoteEvent(pitch: 55, velocity: 90, onset: 0.0, duration: 1.0),  // G3
        NoteEvent(pitch: 59, velocity: 80, onset: 0.01, duration: 1.0), // B3
        NoteEvent(pitch: 62, velocity: 80, onset: 0.02, duration: 1.0), // D4
        NoteEvent(pitch: 65, velocity: 80, onset: 0.03, duration: 1.0), // F4
    ].assignOnsetGroups()
    expect(Chord.identify(in: notes, group: 1)?.symbol == "G7", "dominant seventh prefers bass root")
}

do {
    let notes = [
        NoteEvent(pitch: 60, velocity: 80, onset: 0.0, duration: 1.0),
        NoteEvent(pitch: 64, velocity: 80, onset: 0.01, duration: 1.0),
    ].assignOnsetGroups()
    expect(Chord.identify(in: notes, group: 1) == nil, "fewer than three notes yields nothing")
}

do {
    let notes = [
        NoteEvent(pitch: 60, velocity: 80, onset: 0.0, duration: 1.0), // C
        NoteEvent(pitch: 61, velocity: 80, onset: 0.01, duration: 1.0),// C sharp
        NoteEvent(pitch: 66, velocity: 80, onset: 0.02, duration: 1.0),// F sharp
    ].assignOnsetGroups()
    expect(Chord.identify(in: notes, group: 1) == nil, "dissonant cluster yields nothing")
}

do {
    let notes = [
        NoteEvent(pitch: 60, velocity: 80, onset: 0.0, duration: 1.0),
        NoteEvent(pitch: 64, velocity: 80, onset: 0.0, duration: 1.0),
        NoteEvent(pitch: 67, velocity: 80, onset: 0.4, duration: 1.0), // arpeggio
    ].assignOnsetGroups()
    expect(Set(notes.map(\.onsetGroup)) == [1, 2], "separate onsets get separate groups")
}

if failures == 0 {
    print("all \(checks) checks passed")
} else {
    print("\(failures) of \(checks) checks failed")
    exit(1)
}
