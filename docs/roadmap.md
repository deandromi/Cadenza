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
- **Pedal notation on the sheet**: the sustain pedal is engraved (done in
  `0d41746` — `Ped.` and the release star from CC64, under the bass staff);
  the soft pedal is still only heard, not written.

## Where it stands

- The CoreML backbone, mel front end, semi-CRF decoder and attribute heads
  are verified against the Python reference, note for note.
- Live transcription streams: windows decode back to back over the newest
  audio, notes emit with about one to two seconds of latency, and replay of
  a real session matches the offline reference within a millisecond of
  onset.
- The CoreMIDI virtual source is live, the chord sheet updates as chords
  land, and MIDI export is verified.

## Known bugs (user-reported, and where they stand)

- **"New session" closes the app.** Not reproduced as a crash since the audio
  path was rebuilt. The audit that came out of it found three things worth
  keeping fixed, all in the capture path:
  - the session wav was never written: the sink was gated on a flag that was
    never set, so `hasAudio` could only ever be false and audio export had
    nothing to hand over. The recording now runs unconditionally into the temp
    file and is proven by `--record-probe` (one second of a 440 Hz sine lands
    as 48000 frames, peak 16383).
  - the wav write happened *on the audio thread*, under the sample ring's
    lock — a disk stall could hold up capture. The tap now only copies into a
    two-second staging buffer, and the level timer drains it to the file.
  - the tap block built an `Array` per buffer. It now hands its buffer
    pointer straight to the ring.
- **The Cadenza MIDI source is not visible to websites.** Fixed earlier by
  creating the endpoint as an explicit MIDI 1.0 source with real manufacturer
  metadata; `--midi-check` proves the packet path and the republish path.
- **A trap on CoreMIDI's realtime queue** is what an actor-isolation mistake
  in a callback looks like: a block handed to CoreMIDI (or AVFoundation) that
  silently inherits the main actor traps with `SIGTRAP` the moment the system
  calls it on its own queue. Both callbacks in the app now say `@Sendable`
  explicitly, and the record-permission completion does too. Worth remembering
  when adding any new callback: `--midi-check` reproduced the trap instantly
  when the annotation was missing.

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

- **Metronome with count-in** — built: the click runs on its own engine with an
  accented downbeat, tempo and meter in Settings, and a session started while
  the click runs waits one bar before it takes its first note.
- **Transport shortcuts** — keyboard shortcuts for the panel's named
  functions: play/pause, stop, new session, export.

## Free playing: catch it, understand it, make something of it

Approved. This is the Cadenza half of the product: you sit down, you play
whatever you play, and the app turns that into something you can keep,
understand or send. Nothing here grades the player; the learning section
below is a separate door.

### Catch it

- **Retroactive capture** — built and complete: a rolling minute of struck
  notes is kept with wall-clock stamps, and "Keep last minute" (Option-Space
  or the panel) writes that window out as its own session without stopping
  the one that is running. The minute carries its **raw audio** as well: the
  tap holds the last sixty seconds of the microphone (twelve megabytes, no
  file), and the kept take is cut to exactly the span its notes cover, so it
  plays back and exports like any other session.
- **Listening in the background** — built: while the rolling minute is on in
  settings, the app captures from launch instead of only during a take. That
  capture is ambient: no wav is written, nothing is published to the virtual
  MIDI port, and a silent room costs no decode at all (silent windows are
  skipped), so an idle Cadenza is quiet and cheap. Starting a take switches
  capture to session mode with a fresh timeline; stopping it returns to
  listening.
- **One key for the session** — Space starts or stops a session, the way a
  transport key should; play and pause stay on Command-P. Option-Space keeps
  the last minute, with Command-Shift-K as the alias. Command-Space was the
  first choice and was given up on purpose: macOS hands it to Spotlight
  before any app sees it.
- **Time machine** — the transport scrub is built: dragging the scrub hand in
  the panel jumps playback to that point and the keybed and endless measure
  follow. Scrubbing only: the export flow stays the session export, so there is
  exactly one way out of a session. Scrubbing the *sheet* waits for the
  engraver rewrite.

### Understand it

- **The take describes itself** — built in `TakeDescription`: key (Krumhansl
  profiles, near ties decided by fewest accidentals and a major reading),
  tempo, harmonic rhythm, phrase count and length, cadences on the tonic or the
  dominant, texture and register. The summary lands in the panel the moment a
  session stops, and any archived take describes itself from its MIDI through
  the row's "Describe take" card. Deterministic, from note events only.
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

## Beyond the sheet: the room, the sound and the archive

Approved directions that never touch notation. They sit beside the sheet
block rather than behind it, because none of them needs the engraver to be
finished first.

### Always there

- **Cadenza in the menu bar** — the app listens from the menu bar with no
  window open, and one shortcut keeps the last minute from wherever the
  player is. The idea is caught before it is forgotten; the session screen
  stays the place where takes are made, not where they are rescued.
- **An idea inbox** — a quick capture becomes an *idea*, not a session: a
  card with audio and MIDI that can be brought back through the piano
  sampler. Bundling is manual: the player groups ideas by hand and the app
  never guesses at a collection. Sessions are performances, ideas are
  sketches, and the two lists stay apart.

### Play together

- **Comping partner** — while the player plays, Cadenza generates and plays
  a bass and chord part that follows the harmony, in the player's own tempo.
  Voice leading and chord theory, no model: the same CadenzaCore harmony
  layer the theory suggestions need.
- **MIDI clock and Ableton Link out** — the player's tempo becomes the
  session tempo of a DAW or looper next to it. Cadenza stops being only the
  app you play into and becomes the clock the room plays to. Needs a stable
  tempo estimate from note events while the music is still arriving.

### Your sound

- **Playback in the same room** — the piano emulator renders with the
  measured decay of the room the take was played in, so a recording sounds
  where it was made instead of in a neutral box. Measured once per room: a
  clap or a test tone gives the decay time and the early reflections.
- **Take radio** (opens once the piano emulator is better) — an endless
  stream from the player's own archive, chosen by mood and energy, played
  through the sampler. It waits until the sampler is good enough that an old
  take sounds like music rather than a mock-up.

### What the take says about the player

- **Chord vocabulary** — over months: which chord colours the player
  actually uses and which are never touched, with the neighbours one step
  away from each. From note events only, no scoring, no lessons.
- **Take diff** — two performances of the same piece read as a difference:
  timing curve, dynamics, pedalling. The question "was that better?" gets
  an answer instead of a feeling.

### Sparks

- **Vonk (spark)** — the player sits down with no plan; Cadenza proposes a
  key, a tempo and a mood and plays two bars as a fuse. Theory, no model, no
  notation.
- **Morning warm-up** — five minutes of scales and chord grips in the keys
  the player uses least, with the app as a second voice rather than a
  teacher. It never grades; it only plays the other part.

### Waiting on the sheet

Approved, but not started until the engraver is finished, because they read
the notation it writes:

- **Touch in the notation** — dynamics, hairpins, accents and articulation
  from velocity and decay: the sheet remembers how it was played, not only
  which keys went down.
- **Score follower with page turns** — the app knows which bar is sounding
  while the player plays from the app's own sheet, and turns the page.

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

### Pedal is not note length (found and fixed 2026-11-22)

The sheet's longest tie chains are not a tie bug: they are the pedal. The
engine extends every note to the moment the sustain pedal lifts, which is
right for the *sound* (the string keeps ringing) and wrong for the *sheet*
(a chord struck once and pedalled for five seconds is one strike with a
pedal mark, not five bars of tied notes). The session MIDI carries no CC64,
so the key release is gone by the time the engraver sees the notes and it
cannot tell the two apart.

Measured on the first recording: one five-note chord at 17.3 s with a 5.4 s
duration produced 25 tie marks across five bars. The chord itself is right —
a spectrum of the same moment shows G4, D4/D5, D♯4/D♯5, C4 and A♯3 as real
partials — so this is notation, not detection.

The fix that keeps both readings honest: carry the key release beside the
sounding length (`NoteEvent.keyDuration`, filled from the decode offset
before the audio refiner extends it), write the sustain spans as CC64 in the
session MIDI, engrave `keyDuration`, and ink `Ped.` / `✱` from the pedal
spans the model already knows.

Shipped in `0d41746`: `NoteEvent.keyDuration` and `keyOffset`, the writer's
note-off on the key and CC64 for the tail, `PedalSpans.merged` in CadenzaCore
(a release and a re-press milliseconds apart are one held pedal, which turned
277 spans on the Satie file into the pedals a player actually made), and the
marks drawn under everything the bass staff prints instead of through it.
`--midi` proves the round trip: keys 0.5 s, pedal 1.5–5.0 s, sound 4.0 s.

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

### What the harness synth got wrong (and the benchmark to trust now)

For a while the measurements said the model was deaf below C2 and again above
C6: isolated G1 notes did not decode at any velocity, and every note above
pitch 84 vanished. The reference PyTorch model missed them identically, so it
looked like a checkpoint limit and a bass fallback (`LowRegisterDetector`) was
built, measured, and shipped in 1.3.

It was the benchmark audio, not the model. `Tools/render_midi_samples.py`
renders a MIDI file with the CC0 piano samples that ship in `Resources/Piano`,
each note taken from the nearest recorded pitch and shifted, which is what the
app itself plays back. On that audio — real attack transients, real
inharmonicity — the model hears what the harmonic-stack synth hid from it:

| test (recorded samples, `CDZ_FIXED_STEP=0.9`) | F1 |
| --- | --- |
| one lone C1, G1 at v40 and v90, C2, D2, low chords | 0.938 (15/16 notes) |
| high notes C6 to C7, velocities 33 to 100 | 0.933 (7/8) |
| note lengths, 0.15 s to 2 s | 1.000, offsets 0.03 s median |
| Debussy, Reflets dans l'eau, 25 s | 0.870 (P 0.949, R 0.802) |

Same note-length bench with `CDZ_REFINER=0`: F1 0.800, recall 0.667, offsets
0.43 s median. The refiner earns its place on real timbre, not only on the
synth.

So the bass fallback is now **off by default** (`CDZ_LOW=1` turns it on): real
timbre never needed it, and it cost 0.02 s per window (the attribute stage
runs 0.18 s with it against 0.16 s without), so the reason to switch it off is
trust rather than speed. Its
code and checks stay, because it is still the answer for material whose bass
the model genuinely drops — which so far is the synth's bare stacks only.

The lesson for the next round: measure on recorded samples, never on the
harmonic stack. The synth is fine for plumbing tests (lengths, merging,
latency), not for judging what the model can hear.

### Normalisation: two paths, measured

The mel front end can scale each window by its own mean and standard deviation
(`CADENZA_MEL_NORM`, the default) or leave levels absolute, the way Transkun
trained (`CADENZA_MEL_ABS=1`). On recorded samples they trade places:

| Debussy 25 s, peak level | normalised F1 | absolute F1 |
| --- | --- | --- |
| 0.70 | 0.870 | 0.886 |
| 0.20 | 0.870 | 0.873 |
| 0.07 | 0.870 | 0.870 |

The absolute path is a point and a half better on healthy levels and exactly
as good on quiet input, but it loses on the bass test (0.933 against 1.000)
and the normalised path is the only one that cannot be sunk by a quiet room or
a low input gain. It stays the default, with the numbers recorded here rather
than a hunch.

### Heat: what a session actually costs

Measured on this laptop with `CADENZA_DEBUG_INFERENCE=1` and the release
build, on the Debussy take: one 16 s window costs **2.0–2.4 s of model time**
on the GPU, 0.05–0.1 s of mel, 0.05–0.15 s of semi-CRF DP and 0.2–0.8 s of
attribute heads. The pipeline stretches its step until two decoders keep up, so
the GPU is busy for most of a session — that is the heat a player feels.

What is now in place because of it:

- **A silent window is not decoded.** Before a window is submitted, the engine
  asks the ring for the peak of the window's whole 16 s *and* whether any note
  is still sounding. Both quiet means no decode, with the streaming cursor
  advanced so the grid stays intact. Skipping a window in the middle of
  sounding music is forbidden: the merge carries note state across windows and
  that experiment produced thousands of phantom repeats (F1 0.02), which is
  why the condition is the strict one.
- **The neural engine is not a shortcut.** It decodes in the same time as the
  GPU (2.0–2.4 s) but returns a broken score tensor on this model: F1 0.023
  against 0.851, thousands of phantom notes. The GPU stays the default;
  `CADENZA_COMPUTE_UNITS` still exists for experiments.
- **Per-window timing prints are opt-in** (`CADENZA_DEBUG_INFERENCE`): they
  used to write two lines a second for the whole session.
- Already true before this pass: the sheet redrafts at most four times a
  second, and the endless measure's 30 Hz clock stops when the last note has
  drifted off the paper.

Still on the table, in order of expected effect:

1. **Pace from measured throughput** instead of `decodeWall * 0.6`: the
   current formula assumes two decoders halve the pace, which one GPU cannot
   do, so the step drifts to the 4 s ceiling and queue depth (and latency)
   grows with it.
2. **Incremental chords**: `recomputeChords()` re-infers every onset group of
   the whole history on every window. On a long take that is O(n) work per
   2.6 s for output that only changed in the tail.
3. **Occlusion**: no decodes while the window is not visible.
4. **Economy mode**: a larger step ceiling when on battery, as an explicit
   trade of latency for quiet fans.

### Threshold study: measured, no bias ships

The quiet-end question was: does the semi-CRF's own decision point sit too
high? `CADENZA_ONSET_BIAS` (logit units, applied to every diagonal of the score
tensor before the DP) made that testable without touching the model.

Reflets dans l'eau, first 30 s, rendered with the recorded piano samples and
scored by `--eval`:

| onset bias | precision | recall | F1 |
| --- | --- | --- | --- |
| 0 | 0.960 | 0.736 | 0.833 |
| -0.4 | 0.922 | 0.719 | 0.808 |
| -0.8 | 0.967 | 0.753 | 0.847 |
| -1.2 | 0.960 | 0.727 | 0.828 |
| -1.6 | 0.966 | 0.732 | 0.833 |

The same setting repeated gives 0.833 and 0.849, and -0.8 repeated gives 0.847
and 0.835: the run-to-run spread (±1.6 F1 points) is larger than any difference
between settings. Nothing here is a win, so **no bias ships**; the knob stays as
a study tool, documented, never set by the app.

Two harness facts came out of this and are worth remembering:

- The recorded-sample renderer and `MidiReader` disagree on the timeline of a
  piece (211 rendered notes against 231 truth notes in the same 30 s), which
  sinks a piece's scores to F1 ≈ 0.14 regardless of the model. Cross-piece
  averages from that pair are not comparable until the two readers agree.
- Note *lengths* on the Debussy take carry a −3.2 s bias against the MIDI.
  Measured where it comes from: the truth file holds the opening chord for
  12.9 s (the score ties it), while the audio itself only rings for one to two
  seconds. That half of the bias is a *notation* question — pedal-held ties —
  not a detection miss, and it belongs with the sheet work.

### Note lengths: the held key that comes back as a blip

Measured on the sample renderer, one note at a time, four seconds held in
silence (window 0–16 s, no other sound):

| note | model + refiner before | after | truth |
|---|---|---|---|
| C4 at 2.0 s | 0.047 s | 3.95 s | 4.0 s |
| A4 at 7.0 s | 3.15 s | 3.15 s | 4.0 s |
| D3 at 12.0 s | 3.16 s | 3.16 s | 4.0 s |

A lone held C4 came back as a 47 ms blip while an A4 in the same window came
back as 3.15 s. Neither of the two existing rules could see it: there is no
release edge in a smooth decay, and no chord or pedal damps a note that sounds
alone. The third rule added to `NoteLengthRefiner` follows the note's own band
into the silence it dies into and ends it at the frame before that silence
starts, bounded by `maximumTail` and gated on the band being both near the
window's room floor and far below the note's own attack.

On the Debussy take, same binary, same step (1.2 s), A/B:

| | rule off | rule on |
|---|---|---|
| precision | 0.937 | 0.940 |
| recall | 0.766 | 0.814 |
| F1 | 0.843 | 0.872 |
| matched | 177 | 188 |
| offset bias | −3.16 s | −2.94 s |

The extended notes also change what the merge does with them: a note that
stays live instead of releasing as a blip is no longer re-appended as a fresh
strike, so eleven more true notes survive the merge with no precision cost.
`CDZ_REFINE_SILENCE=0` poses the old behavior for the next A/B.

### Where the misses are now

On the Debussy capture, 37 notes of 179 are missed and they are all
pianissimo: 24 sit in the top octave of the texture, 24 sound inside a
two-note chord. That is masking, and the reference model misses the same notes
at the same places, so it cannot be fixed downstream of the model without
inventing notes — which is exactly what the chord completion experiment tried
and lost. The remaining honest levers are a threshold study on the quiet end
and, eventually, fine-tuning on real recordings.

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
- `Tools/render_midi_samples.py <midi> <out.f32> [rate] [maxSeconds]` renders
  a MIDI file with the recorded piano samples the app plays back. This is the
  benchmark to judge accuracy on: the harmonic-stack synth below is fine for
  plumbing, but it hides whole registers from the model.
- `Tools/corpus_eval.sh <outdir> <seconds> <midi...>` does both for a folder
  of pieces and writes one eval line per piece, so a change can be judged on
  slow pedalled music as well as on dense pop.
- `Tools/segment_sweep.py` and `Tools/probe_compute_units.py` answer window
  and hardware questions if the latency work returns.
