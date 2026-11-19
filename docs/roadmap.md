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

## Ideas parked

Three directions agreed on, waiting for their turn. None of them starts
until the sheet generator is done.

- Harmony analysis: roman numerals in the detected key, secondary
  dominants, modulations. Pure CadenzaCore work, layered directly on the
  chord engine once that engine's output has survived real use.
- Repertoire library: named sessions that keep their chord sheet, MIDI,
  MusicXML and the raw audio, so older recordings can be re-transcribed
  when the model improves — the `--replay` tooling already proves the
  capture format for this.
- MIDI routing controls: transpose, velocity curve, hand split onto two
  channels, sustain passthrough. Cheap, and it makes the virtual keyboard
  genuinely usable next to other apps.

## Where the sheet generator stands

- Framing logic (tempo, key, meter), quantization, the score model, a
  MusicXML writer and the layout pass (`ScoreLayout`: systems, noteheads,
  stems, flags, dots, accidentals, rests, key glyphs, chord symbols) live
  in CadenzaCore, all testable from recorded note events with no audio
  stack. `--score` replays a captured session and engraves it offline,
  `--midiscore <file.mid>` does the same from a MIDI file, `--sheet` renders
  the engraved sheet to /tmp/cadenza_sheet.png for inspection.
- The app's Sheet music menu opens a paper window with the choices step —
  tempo, meter and key as pop-ups fed by the engraver's ranked candidates
  (`tempoCandidates`, `scoreMeterCandidates`, `scoreKeyCandidates`) — and an
  Engrave action that cuts the session into measures and draws the grand
  staff in ink. Export MusicXML writes the same score as .musicxml.
- Engraving fills empty measures with whole rests, and chord symbols share
  the measures' phase space (a pickup no longer orphans them).

## MIDI vs published PDF (research, two MuseScore files)

Both files came with their MIDI meta and the published PDF; the PDFs were
rendered to PNG (`/tmp/pdf2png.swift`, CGPDFDocument) and read visually.

| | meta (MIDI) | PDF (published) | engraver output |
|---|---|---|---|
| Je te veux (Satie) | 172 bpm, 3/4, C major | 3/4, no key signature (C major), "Modéré" | 172 bpm, C major, 4/4 by a near-tie (3/4 ranked #2, 0.150 vs 0.153) |
| Hey Bulldog (Beatles) | 104 bpm, 4/4, B major | quarter = 104, 4/4, 5 sharps (B major) | 104 bpm, 4/4, B major — exact match |

- Quantization is healthy on both: every onset lands within one sixteenth
  of the engraved grid (bulldog mean 0.8 ticks, Satie mean 42 of 480).
- Tempo octaves are decided by the heaviest inter-onset cluster inside
  50-190 bpm; faster clusters are subdivisions. This nailed both files.
- Key uses Krumhansl-Schmuckler plus an out-of-scale penalty and a
  first/last-chord cadence bias; both files read the published key.
- Meter is the honest weak spot: 4/4 vs 3/4 in a waltz is a near-tie from
  note data alone, so `scoreMeterCandidates` returns the ranked list and
  the choices step lets the user pick — that step is load-bearing, not
  cosmetic.

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
