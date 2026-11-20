# Cadenza roadmap

The project in one line: a macOS app that listens to a piano, transcribes it
in real time with a Transkun-style model, shows a live chord sheet, acts as
a MIDI keyboard for other apps, and afterwards turns the recorded
performance into a finished sheet of music. Longer term it grows into a
learning tool — a serious alternative to paid music-learning apps — and a
landing page of its own.

## North star: accuracy and latency

The single most important factor, above every feature: sound-to-MIDI
conversion close to real time with near-perfect note capture.

- Target: **under 1 second** end-to-end latency, **99% registration**
  (played notes detected) and **99% recognition** (correct pitch), including
  correct handling of the **sustain pedal and silencer (soft) pedal**.
- Measured today, for calibration:
  - Live pipeline on a real session: median latency ~2.0 s, p90 ~2.6 s.
  - Best case (clean synthesized audio, `--synth-midi` + `--replay-stream`
    over the first 60 s of two reference pieces): precision 0.98–1.00,
    recall 0.80–0.93 (F1 0.89–0.96), misses concentrated in the lowest bass
    register. See the eval notes in the `--synth-midi` commit.
  - Dense synthetic polyphony costs more: median 4–6 s latency on those
    same pieces.
- Path to the target: a smaller or hybrid model tier behind a **sub-second
  mode toggle** in the UI, pedal-aware training/eval data (sustain extents
  are already captured in note durations), and a standing eval harness
  (`--synth-midi`/`--replay-stream` + offline matching) that reports
  precision/recall/F1 per piece on every model change. Latency below one
  second needs that different model tier and would repeat the same
  verification path the current backbone went through.
- **Pedal notation on the sheet**: sustain and silencer pedals engraved as
  real pedal lines (Ped./release marks) on the staff, not just folded into
  note durations.

## Where it stands

- The CoreML backbone, mel front end, semi-CRF decoder and attribute heads
  are verified against the Python reference, note for note.
- Live transcription streams: windows decode back to back over the newest
  audio, notes emit with about one to two seconds of latency, and replay of
  a real session matches the offline reference within a millisecond of
  onset.
- The CoreMIDI virtual source is live, the chord sheet updates as chords
  land, and MIDI export is verified.

## Known bugs to fix (user-reported)

- **"New session" closes the app** — a crash on start-listening (seen as an
  EXC_BREAKPOINT on the audio realtime thread). Must be fixed first: a
  session start may never take the app down.
- **The Cadenza MIDI source is not visible to websites** (e.g. BandLab in a
  browser) although desktop apps see it. Investigate CoreMIDI virtual
  endpoint visibility for Web MIDI; the endpoint must be advertised so
  browser-based DAWs can subscribe.

## Session panel and export (redesign agreed)

- The panel's footer Export button goes away. **Export lives on each
  individual session**: tapping it opens a **liquid glass popover** asking
  what to export — the **MIDI file, the audio recording, or both**.
- **Every session is converted to MIDI automatically** when it ends; no
  manual export is needed for the .mid to exist.
- **The panel expands on tap**: pressing anywhere on the session panel other
  than the existing buttons (which become named shortcuts to functions)
  expands the panel with a **liquid glass animation** and reveals extra
  per-session options: **rename**, **copy the MIDI file** directly (without
  going through an export dialog), delete, and later the sheet PDF.
- **Session lifecycle**: when a new session starts, the previous one moves
  to the session history automatically — unless it is empty (no recording,
  no MIDI, no sheet), in which case it is discarded.

## Sessions: import, playback tools and statistics

- **MIDI import**: open a .mid file in Cadenza — play it back through the
  virtual source, watch it on the keybed and endless measure, engrave it to
  a sheet, or use it as a play-along reference.
- **Audio export**: the raw recording exports as .wav (and .mp3), per
  session, from the session's export popover.
- **A-B loop**: select a passage in a session and loop it, with tempo
  scaling (50–75%) for slow practice.
- **Play-along with yourself**: play along with your own recording and get
  a timing-accuracy score against it.
- **Session statistics**: practice time, notes played per day/week, and
  accuracy per session in a simple overview.

## Settings (new section, not built yet)

- **Keep recorded audio** (opt-out): when off, a session's audio recording is
  deleted immediately after the session ends and only the MIDI file is
  kept.
- **Session directory: ...** — a folder picker. Sessions are saved as
  `Session directory/Session N/` containing:
  - `.mid` — always, written automatically at session end
  - `.pdf` — the engraved sheet, once sheet export lands
  - `.wav` — the audio recording, unless the keep-audio preference is off
- **Input device and channel** — which microphone or audio-interface input
  to use, plus an **input gain** control with a test tone.
- **Tuning reference** — A4 calibration (e.g. 442 Hz) so transcription
  follows the piano's actual pitch.

## Practice tools

- **Metronome with count-in** — standalone, with adjustable meter and click.
- **Transport shortcuts** — keyboard shortcuts for the panel's named
  functions: play/pause, stop, new session, export.

## Free playing: catch it, understand it, make something of it

Approved. This is the Cadenza half of the product: you sit down, you play
whatever you play, and the app turns that into something you can keep,
understand or send. Nothing here grades the player; the learning section
below is a separate door.

### Catch it

- **Retroactive capture** — a rolling buffer keeps the last minute of
  playing, so hitting one key puts what was just played into a session. No
  record button needed before the moment happens.
- **Time machine** — scrub back and forth through a session with the sheet
  redrawing and the audio following. Scrubbing only: the export flow stays
  the session export, so there is exactly one way out of a session.

### Understand it

- **The take describes itself** — after stopping, a short deterministic
  description: key, tempo curve, harmonic rhythm, phrases, cadences,
  texture, register use. Generated from note events in CadenzaCore, no model
  involved.
- **Split the voices** — melody, accompaniment and bass separated into their
  own staves, MIDI tracks and part exports. Not a default view: a toggle,
  because most takes read better as one grand staff.

### Make something of it

- **Re-orchestrate** — one action turns a take into a four-part chorale, a
  piano reduction or a string-quartet sketch, from voice-leading rules
  alone.
- **Accompaniment under your own melody** — bass and chords written under
  what was played, in the take's key and tempo, as a second staff and a
  second MIDI track. A toggle that runs after the session stops, never by
  default.
- **Loop and overdub** — loop a region, play over it with separate hands,
  and Cadenza merges the passes into one MIDI and one sheet.

### Send it

- **Performance card** — one file holding MIDI, audio and analysis that
  opens on another Mac in Cadenza, ideally with a browser view so a take can
  be listened to without installing anything.
- **Repertoire shelf with musical search** — play a fragment and the app
  finds the take or the idea that contains that motif.
- **Recital booklet** — selected takes become one PDF: titles, dates,
  durations, analysis and the engraved sheet, as a programme to give away.
- **Image export** — sheet plus audio rendered as a clean recording with a
  fixed composition, so a take can be shared without a screen capture.

Where this lands: retroactive capture, the time machine, image export and
the performance card are app-layer work on top of the existing session
store; the take's description, voice splitting, re-orchestration,
accompaniment and musical search are CadenzaCore work, testable from
recorded note events with no audio stack.

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

### Where the sheet generator stands

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
  staff in ink with Bravura SMuFL glyphs. Export MusicXML writes the same
  score as .musicxml.
- Engraving fills empty measures with whole rests, and chord symbols share
  the measures' phase space (a pickup no longer orphans them).

### MIDI vs published PDF (research, two MuseScore files)

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

## Learning section (future)

Chord and melody learning as the third main functionality alongside
recording and the sheet music generator/editor. Cadenza should become a
feasible free alternative to paid music-learning applications. None of it
starts until the sheet generator is done.

The concrete trainers:

- **Chord trainer, jazz chords included** — shows a chord name (maj7, m7b5,
  alt, ...), you play it, the app checks the pitch set.
- **Ear training** — interval and chord-quality recognition with a score.
- **Scale and arpeggio trainer** — with metronome and rising tempo.
- **Sight-reading trainer** — a random measure is shown, you play it, the
  app scores notes and timing.
- **Auto-lessons from your own mistakes** — after each session the app
  finds where you stumbled (timing, wrong notes, missed chords) and
  generates a personalized drill of exactly those passages.
- **Piano spellcheck — suggestions only** — likely mis-hits are flagged as
  *suggestions* in the live view; the MIDI stream and the sheet are never
  silently altered, the played note always stands.

## Theory-based suggestions (no AI)

Cadenza should be able to **propose melodies and chords without any AI**,
purely from professional music theory, based on what was played in a
session: cadence suggestions, voice-leading continuations, diatonic chord
progressions in the detected key, motif development. Pure CadenzaCore
work — deterministic, testable from recorded note events, no model
involved — layered on top of the harmony analysis below.

## Landing page (future)

When the three main functionalities are all fully complete — **recording**,
**sheet music generator/editor**, and the **learning section** — the project
gets a beautiful, lush and creative landing page in the app's paper-and-glass
design language (see `docs/design-language.md`).

## Ideas parked

Directions agreed on, waiting for their turn:

- Harmony analysis: roman numerals in the detected key, secondary
  dominants, modulations. Pure CadenzaCore work, layered directly on the
  chord engine once that engine's output has survived real use.
- Repertoire library: named sessions that keep their chord sheet, MIDI,
  MusicXML and the raw audio, so older recordings can be re-transcribed
  when the model improves — the `--replay` tooling already proves the
  capture format for this.
- MIDI routing controls: transpose, velocity curve, hand split onto two
  channels, sustain passthrough. Cheap, and it makes the virtual keyboard
  genuinely usable next to other apps (and in the browser, once the Web
  MIDI visibility bug above is fixed).

### Measured and set aside: chord completion from the attack spectrum

The idea: a chord the model half-heard can be completed by asking one
spectrum, taken at the attack, which other pitches' harmonic series it still
carries. Built and measured on three pieces at `CDZ_FIXED_STEP=0.9`.

- Hey Bulldog (synth, 30 s): precision 0.959 unchanged, recall 0.877 -> 0.884,
  F1 0.916 -> 0.920 at the best threshold pair.
- Je te veux (Satie, pedalled and legato): precision 0.993 -> 0.719 at first,
  and still only 0.921 after subtracting every sounding note's partials,
  requiring a spectral peak, and refusing octave ratios. Every added note was
  a phantom: on pedalled music an undetected ringing note explains a pitch an
  octave or a fifth above itself, and the residual cannot tell that from a
  note nobody played.
- The threshold that is safe on the Satie piece (1.5x the weakest decoded
  note) adds nothing anywhere.

Conclusion: the recoverable chord members are too few to pay for the phantoms
they bring, so the completer was removed rather than shipped behind a flag.
It can come back only with a test that separates a struck note from a
ringing partial, such as onset coherence across several frames.

The broader reading of the same measurements: precision is already 0.92-0.99,
recall is 0.80-0.88. The next accuracy work belongs to **missed notes**, not
to note lengths or false notes.

## Small levers, in rough order

- A level meter on the session meta lens, wired to the existing tap state.
- Input validation for quiet rooms: an energy gate study if quiet-passage
  misfires persist on a good microphone.

## Tooling that stays useful

- `swift run CadenzaCoreChecks` must pass for any CadenzaCore change.
- `--replay` runs the reference grid pipeline on a session capture,
  `--replay-stream` runs the live streaming pipeline on the same audio, so
  live quality questions can be answered offline.
- `--synth-midi <file.mid> <out.f32>` renders a MIDI file to clean synthetic
  audio and prints ground-truth notes; match against `--replay-stream`
  output for best-case precision/recall/F1.
- `Tools/corpus_eval.sh <outdir> <seconds> <midi...>` does both for a folder
  of pieces and writes one eval line per piece, so a change can be judged on
  slow pedalled music as well as on dense pop.
- `Tools/segment_sweep.py` and `Tools/probe_compute_units.py` answer window
  and hardware questions if the latency work returns.
