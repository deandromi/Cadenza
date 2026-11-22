# Cadenza sheet generator — the rhythm pipeline

Angle: **the rhythm must read correctly.** This is an attempt to do what MuseScore
does when it imports a performance: quantize onsets on the take's own grid, take each
note's written value from the room it owns in its voice, split values that would hide a
beat, beam inside the beat, and fill every silence with rests so each voice tiles its
bar exactly.

Worktree: `/tmp/cadenza-lab-a` (all changes in the working tree, nothing committed).

---

## 1. What was wrong (measured, before any change)

`swift run CadenzaCoreChecks` → `all 200 checks passed`; `--sheet-rules je-te-veux-satie.mid`
→ `clean — 46 systems, 56 ties, 10 beams`. So the old sheet passed its own rules and was
still unreadable. The cause was upstream of the rules:

| symptom | cause found |
| --- | --- |
| page 1 is a wall of heads; bars 3, 5, 6 of the first system nearly empty | the file's note onsets were converted ticks → **seconds at its tempo map**, then back to ticks at **one nominal tempo (172)**. The file has 42 tempo changes (172, 86, 34.4, …). Measured on the old path: **grid error avg 42 ticks, max 60, 1238/2050 attacks more than 40 ticks off the 16th grid** |
| dotted halves everywhere in both hands | with a smeared grid, a voice's next attack was 3 beats away, so every note "owned" a whole bar |
| only 10 beams in the whole piece | almost nothing landed on an eighth or sixteenth, so nothing could beam |
| long values hiding the beat | durations were rounded to the quarter grid (`roundDurations`) with no metrical rule at all; no value was ever split |

The file's **ticks** are the notation: on its own clock the attacks sit on a 16th grid
with **avg residual 0.0 ticks, max 58, 2/2050 off-grid** (`--sheet-report` prints both
readings). The fix has to start there.

## 2. What changed

New files:

* **`Sources/CadenzaCore/SheetTime.swift`** — `SheetDraft.TimeMap`: an imported file's own
  clock (its tempo map, piecewise seconds↔ticks, scaled to the engraver's 480/quarter) plus
  `MidiFile.sheetTimeMap`. A MIDI file's ticks are its notation; its tempo map is what turns
  those ticks into playing time, and reading the seconds back at one tempo throws the
  notation away. This is the single biggest correction.
* **`Sources/CadenzaCore/SheetMeter.swift`** — `SheetDraft.Meter`: where the beats fall (with
  compound meters felt in dotted beats), the ladder of values one symbol may carry, and the
  one rule that decides how a span is written: *a length is one symbol when it is aligned to
  its own value, or when it starts on a beat and lasts at most two beats; otherwise it is
  tied pieces.* Rests use the same rule without dots. Everything else calls this; there is no
  second set of splitting rules anywhere.
* **`Sources/CadenzaCore/SheetVoices.swift`** — `SheetEngraver.StaffWriter`, the rhythm stage:
  1. voices by overlap (a note still sounding when the next attack lands is the other voice);
  2. a column's value = the room it owns in **its own voice** (distance to that voice's next
     attack, cut at the barline), unless the player clearly let go early (then it prints what
     was played and rests close the room);
  3. splits at beats and barlines, with ties only where a split happened;
  4. rests fill every silence of every voice;
  5. beams per beat, per voice, same flag count, never through a rest or a barline;
  6. phrase marks only where the player actually overlapped the next attack (no legato in
     this performance ⇒ no slurs invented).
* **`Sources/CadenzaCore/SheetAudit.swift`** — `SheetDraft.rhythmAudit(_:)`: the invariant the
  whole change leans on, in one place: every voice tiles every bar exactly; what is drawn is
  the value decided; **no value contradicts the meter** (every chord is a value this bar can
  hold where it stands); every tie joins two pieces that exist and meet. Run by
  `CadenzaCoreChecks` and by `--sheet-rules`.

Rewritten / changed:

* **`SheetEngrave.swift`** (929 → 616 lines): quantization via `Quantizer`, chordify with the
  take's own roll window, bar grid that stops when the music stops (no trailing empty bar),
  columns per staff, then the `StaffWriter`; the layout code is untouched.
* **`SheetDraft+Rhythm.swift`**: `SheetDraft.Quantizer` chooses the grid **from the take** —
  1/16 at most, 1/8 when fewer than one attack in fifty sits off the eighth grid (a file's
  ticks are notation, so its jitter is measurable); a performance without a tempo map keeps
  the 16th grid and only nudges an attack already most of the way to the pulse.
  `roundDurations` (the old "stretch to the quarter grid" model) is deleted.
* **`SheetDraft.swift`**: `Chord.voice` (a chord belongs to a voice — needed by the audit and
  honest in the model); `Options.combineMillis` default 40 → 90 ms, documented: a rolled chord
  spreads over up to ~90 ms and is one chord.
* **`SheetDraft+Pipeline.swift`, `CadenzaApp/SheetPDF.swift`, `ProbesSheet.swift`,
  `SheetRulesProbe.swift`**: pass the file's clock through; the report now prints the grid
  error on the file's clock *and* at one nominal tempo; the rules probe reads polyphony from
  `Chord.voice` (not from the presence of a voiced rest) and runs the shared audit.

### Checks (`Sources/CadenzaCoreChecks/main.swift`) — 200 before, 200 after

Four checks were **replaced** (not weakened), and the total is still 200:

* Removed: the two `chordify` checks and the two `roundDurations` checks. Both helpers were
  the old model this change deletes: `roundDurations` rounded every note to a quarter grid
  regardless of the bar (exactly the "long values that hide the beat" bug), and `chordify`
  was superseded by the engine's own roll merge in the take's tick domain. Neither function
  exists any more.
* Added: **every voice tiles its measure exactly** (`rhythmAudit` on a 3/4 waltz with a melody
  held over the accompaniment), **a held value is split where it would hide a beat** (half
  tied to an eighth, one tie), **a value is the room a note owns** (a hair-early lift fills its
  quarter; a note let go early prints short with a rest closing the room), and **a file's
  tempo map, not its nominal tempo, is the notation clock** (same two attacks: a quarter apart
  on the file's clock, an eighth apart read at one tempo).
* One pre-existing check was edited because its *fixture* encoded the old model: the four-
  eighths beaming check held each note for 0.15 s of a 0.25 s room, which under gap-based
  values is honestly a sixteenth. The fixture now holds each eighth for its eighth; the
  assertion (two beam groups of two, one per beat, every eighth beamed) is unchanged.

## 3. Numbers

`je-te-veux-satie.mid` (3/4, 172 bpm nominal, 285 bars, 2050 notes):

| | before | after |
| --- | --- | --- |
| systems (rows) | 46 | **42** |
| beams | 10 | **18** |
| ties | 56 | **333** (216 across a barline) |
| slurs | one per adjacent pair (~341) | **0** (no legato overlap in the performance) |
| `--sheet-rules` | `clean — 46 systems, 56 ties, 10 beams` | `clean — 42 systems, 333 ties, 18 beams` |
| `rhythmAudit` | (did not exist) | **0 issues** |
| grid error on the file's clock | 42 avg / 1238 off-grid | **0 avg / 2 off-grid** |
| grid error read at one tempo | 42 avg / 1238 off-grid | 42 avg / 1238 off-grid (unchanged — that is the point) |
| bars | 291 measures, several empty | **285**, one sparse (the fermata bar) |

Written values on the Satie, after: quarter 856, half 251, dotted half 161, dotted quarter 20,
eighth 34, dotted eighth 34, sixteenth 59, whole-note *chords* 0 (there is no whole note in
3/4 — the old sheet printed them across barlines). Whole-bar rests 13.

`images-1ere-serie-claude-debussy-reflets-dans-leau.mid` (2033 notes, dense 16ths):

| | after |
| --- | --- |
| systems / beams / ties | 33 / **263** / 456 |
| `--sheet-rules` | `clean — 33 systems, 456 ties, 263 beams` |
| `rhythmAudit` | 0 issues |
| values | sixteenth 716, eighth 227, quarter 193, dotted eighth 65 … |

## 4. What looks better (page 1, side by side with the reference)

`out/compare-page1-top.png` is the reference's first system above mine.

1. **Bar 1 now matches the reference exactly**: quarter rest, two quarter notes in the treble,
   a whole rest in the bass. Before, the same bar was a dotted half plus scattered heads.
2. **The bass reads as a waltz**: dotted-half chords where the chord is held for the bar, then
   quarter chords with low octave roots once the accompaniment starts (bars 20-33 show the
   boom-chuck-chuck as three quarter chords per bar, exactly what was played). Before, both
   staves printed dotted halves with no rhythmic relation to the meter.
3. **The melody reads in quarters with dotted halves only where the note is really held**, and
   the 16th figures are 16ths (the rolled chord in bar 3 is now an eighth rest + a tied eighth
   and quarter instead of four colliding columns).
4. Nothing contradicts the meter any more: a value that would hide a beat is tied (audit: 0
   issues), and no bar is left unfilled (every voice tiles its bar).
5. Beams exist and are legal: 263 in the Debussy, 18 in the Satie (all pairs, all inside a
   beat). The Satie's first page has none because the piece is quarter-based there — see the
   weaknesses.

## 5. What still looks wrong (honest)

* **Ties are heavy ink.** 333 of them, and they are drawn by the untouched layout code
  (`ScoreView.drawTies`): a tie leaves the head edge and reaches the next head edge, bowing
  away from the chord's centre. When a two-note chord ties to the next column, the two curves
  bow outward and a reader glancing at it sees a small bracket rather than two ties. Pre-
  existing shape code, but my values make it six times as dense, so it is more visible now.
* **Ties went up, 56 → 333.** They are real: this transcription sustains a lot of notes past
  a beat or a barline (max raw duration 2399 ticks ≈ 5 beats), and the sheet now ties each
  continuation instead of hiding it behind a longer value. MuseScore's import of this file
  would tie the same continuations; the *edition* in the reference has few because it is a
  cleaner engraving, not because the performance has fewer sustains. It is busier ink.
* **No slurs.** A phrase mark should mean the player joined the notes; in this file no note is
  held past the next attack, so the sheet prints none rather than inventing 341 of them. The
  reference's slurs are editorial.
* **Beams on the Satie's page 1: none.** All 18 groups are pairs in the 16th passage around
  bars 103-128; the rest of the piece is quarter-based, and an isolated sixteenth pickup
  cannot beam with a quarter. The Debussy's 263 beams show the beaming itself works.
* **Short notes print short.** Notes released well before their room ends (about 5% of the
  Satie) print their played value plus rests: 59 sixteenths, 53 sixteenth rests, 34 dotted
  eighths. Honest ("simplify durations" in MuseScore only shortens), but fussier than an
  edition would be. The threshold is 50% of the room; raising it would print fewer rests and
  more legato, at the cost of writing notes the player did not hold.
* **The register split at middle C** puts the waltz's inner chords on the treble staff in a few
  passages (e.g. bars 15-20), which leaves bars of whole rests in the bass. A hand split would
  read better, but a transcription carries no hands.
* **Meter changes are still ignored**: the Debussy declares 4/2 → 3/2 → 6/2 …, and the engraver
  uses the first signature for the whole piece. Out of scope here, but it is the next real
  rhythm limitation.
* A handful of 32nd values (14 in the Debussy) appear where a 16th had to be split at a
  position the meter will not let it stand; legal, slightly fussy.
* The Satie is 11 pages (42 systems × 7 bars). That is the performance's 285 bars, not a layout
  fault: the reference is a 3-page edition of a 90-bar score.
* `Sources/CadenzaCoreChecks/main.swift` grew 1178 → 1257 lines (four new checks). It was already
  a flat list above the ~1000-line guideline; splitting it into per-area check files is worth
  doing but is unrelated to this change, so I left it. Everything else is under 600 lines.

## 6. Reproduce

```bash
cd /tmp/cadenza-lab-a
swift build 2>&1 | grep error:            # empty
swift run CadenzaCoreChecks | tail -1     # all 200 checks passed
.build/debug/CadenzaApp --sheet-rules je-te-veux-satie.mid
.build/debug/CadenzaApp --sheet-report je-te-veux-satie.mid
.build/debug/CadenzaApp --pdf je-te-veux-satie.mid out/satie.pdf
.build/debug/CadenzaApp --pdf images-1ere-serie-claude-debussy-reflets-dans-leau.mid out/debussy.pdf
/tmp/pdfzoom out/satie.pdf out/satie-p1.png 0 3
/tmp/pdfzoom out/debussy.pdf out/debussy-p1.png 0 2
/tmp/pdfzoom "/Users/deandromink/Library/CloudStorage/ProtonDrive-Deandro.GJ@protonmail.com-folder/Piano-Musescore/Pdf/je-te-veux-satie.pdf" out/reference-satie-p1.png 0 3
```

`out/` holds: `satie.pdf`, `debussy.pdf` (this build), `satie-before.pdf` (the render I made
before touching anything, for the comparison), `satie-p1.png`, `debussy-p1.png`,
`reference-satie-p1.png`, `compare-page1-top.png` (reference above, mine below).

Note on fixtures: `je-te-veux-satie.mid` is gitignored in this repo, so it was copied into the
worktree root from the lead's checkout (same file, read-only source). `Fixtures/golden/*.f32`
are also gitignored; they are symlinked from the lead's checkout so `CadenzaCoreChecks` can
run. Both are ignored by git and none of them is modified.

## 7. Verification of this exact tree

Run after the last edit, on the working tree as it stands:

```
$ swift build 2>&1 | grep -c error:
0
$ swift run CadenzaCoreChecks | tail -1
all 200 checks passed
$ .build/debug/CadenzaApp --sheet-rules je-te-veux-satie.mid
rules: clean — 42 systems, 333 ties, 18 beams
$ .build/debug/CadenzaApp --sheet-rules images-1ere-serie-claude-debussy-reflets-dans-leau.mid
rules: clean — 33 systems, 456 ties, 263 beams
$ .build/debug/CadenzaApp --sheet-report je-te-veux-satie.mid      (excerpt)
report: inferred tempo 172 meter 3/4
report: grid error on the file's clock avg 0 max 58, off-grid(>40) 2/2050
report: grid error read at one tempo avg 42 max 60, off-grid(>40) 1238/2050
report: notes per measure (first 12) 0:6 1:6 2:8 3:2 4:0 5:5 6:7 7:6 8:7 9:7 10:7 11:6, measures 285
$ /tmp/probe/satie je-te-veux-satie.mid                            (value histogram, excerpt)
rows 42 beams 18 ties 333 slurs 0 fifths 0
  quarter [480]: 856     half [960]: 251        dotted half [1440]: 161
  16th [120]: 59         eighth [240]: 34       dotted eighth [360]: 34
  dotted quarter [720]: 20   rest whole: 13     audit issues 0
```

and bars 21-22 of the bass, straight from the probe, are the waltz this change was for:

```
m21 chord t28800 [36,48,52] room 1440 dotted half    m21 rest t28800 quarter v1
m21 chord t29280 [55] room 480 quarter               m21 chord t29760 [55] room 480 quarter
m22 chord t30240 [35,47,50] quarter  t30720 [52] quarter  t31200 [55] quarter
```

`git status --short` shows only the intended eight modified files, the four new files
(`SheetTime.swift`, `SheetMeter.swift`, `SheetVoices.swift`, `SheetAudit.swift`), `REPORT.md`
and `out/`. Nothing is committed.
