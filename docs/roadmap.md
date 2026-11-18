# Cadenza roadmap

The project in one line: a macOS app that listens to a piano, transcribes it
in real time with a Transkun-style model, shows a live chord sheet, acts as
a MIDI keyboard for other apps, and afterwards turns the recorded
performance into a finished sheet of music.

## Where it stands

- The CoreML backbone, mel front end, semi-CRF decoder and attribute heads
  are verified against the Python reference, note for note.
- Live transcription streams: windows decode back to back over the newest
  audio, notes emit with about one to two seconds of latency, and replay of
  a real session matches the offline reference within a millisecond of
  onset.
- The CoreMIDI virtual source is live, the chord sheet updates as chords
  land, and MIDI export is verified.

## Sheet music generation

The next large block. The flow the product wants:

1. The user starts a recording and plays. Everything is captured as it
   happens: raw microphone audio, transcribed note events, onset groups and
   chords. The sheet drafts itself live, so a mistake or a replay is never
   lost.
2. When the recording stops, the engraving pass runs. It looks at the
   recorded performance and chooses the framing the notation needs:
   - time signature, inferred from onset clustering and measure stability
   - key, inferred from the pitch-class profile of everything played
   - average tempo, from inter-onset intervals over the whole session
3. The generator then lays out the staff: notes with their refined onsets
   and durations, chord symbols above the staff, pedal extents where the
   transcriber found them, bars chosen with the inferred meter.
4. The result is a document the user can export, print or keep editing.

Ground rules for that work: meter, key and tempo inference belong in
CadenzaCore where they are testable from recorded MIDI with no audio stack,
notation layout is deterministic and unit-testable, and the renderer only
draws what the layout produces.

## Small levers, in rough order

- A level meter on the session meta lens, wired to the existing tap state.
- Input validation for quiet rooms: an energy gate study if quiet-passage
  misfires persist on a good microphone.
- Latency below one second needs a different model tier, smaller or hybrid,
  and would repeat the same verification path the current backbone went
  through. Only worth it for exercise software that demands sub-second
  input.

## Tooling that stays useful

- `swift run CadenzaCoreChecks` must pass for any CadenzaCore change.
- `--replay` runs the reference grid pipeline on a session capture,
  `--replay-stream` runs the live streaming pipeline on the same audio, so
  live quality questions can be answered offline.
- `Tools/segment_sweep.py` and `Tools/probe_compute_units.py` answer window
  and hardware questions if the latency work ever returns.
