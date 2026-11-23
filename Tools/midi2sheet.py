#!/usr/bin/env python3
"""MIDI -> engraved sheet music.

No glyph is drawn here. The notation decisions are made by music21
(quantization, measures, rests, ties, beams, key) and the typesetting by
LilyPond, which is the engraver a publisher would use. This file only does the
one thing neither of them can: it decides what a *performance* means as
notation.

usage: midi2sheet.py <in.mid> <out-basename> [--grid 0.5] [--split 60]
"""
import argparse
import copy
import shutil
import subprocess
import sys
from pathlib import Path

from music21 import (
    converter, stream, note, chord, meter, clef, tempo, layout, key, duration,
    metadata, pitch as m21pitch,
)


# ---------------------------------------------------------------- reading

KRUMHANSL_MAJOR = (6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88)
KRUMHANSL_MINOR = (6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17)

# Every key, spelled the way it sits on the page: index is the number of
# accidentals in the signature, from seven flats to seven sharps. A signature
# has two names for the same sound, and the list holds both so the speller can
# choose without inventing a third.
KEY_NAMES = {
    "major": ("Cb", "Gb", "Db", "Ab", "Eb", "Bb", "F", "C", "G", "D", "A", "E", "B", "F#", "C#"),
    "minor": ("Ab", "Eb", "Bb", "F", "C", "G", "D", "A", "E", "B", "F#", "C#", "G#", "D#", "A#"),
}


def _pitch_class_weights(source):
    """How much of the piece each of the twelve pitch classes occupies."""
    weights = [0.0] * 12
    for element in source.recurse().notes:
        length = float(element.duration.quarterLength)
        for found in element.pitches:
            weights[found.pitchClass] += length
    total = sum(weights)
    return [weight / total for weight in weights] if total else [1.0 / 12] * 12


def _correlate(weights, profile, tonic):
    """Krumhansl's correlation, with the profile rotated onto the tonic."""
    rotated = [profile[(step - tonic) % 12] for step in range(12)]
    count = 12
    mean_a = sum(weights) / count
    mean_b = sum(rotated) / count
    covariance = sum((a - mean_a) * (b - mean_b) for a, b in zip(weights, rotated))
    spread_a = sum((a - mean_a) ** 2 for a in weights) ** 0.5
    spread_b = sum((b - mean_b) ** 2 for b in rotated) ** 0.5
    return covariance / (spread_a * spread_b) if spread_a and spread_b else 0.0


def rank_keys(source):
    """All twenty-four keys, best fit first, as (correlation, KeySignature)."""
    weights = _pitch_class_weights(source)
    ranked = []
    for mode, names in KEY_NAMES.items():
        profile = KRUMHANSL_MAJOR if mode == "major" else KRUMHANSL_MINOR
        for index, name in enumerate(names):
            accidentals = index - 7
            tonic = m21pitch.Pitch(name).pitchClass
            ranked.append((_correlate(weights, profile, tonic),
                           key.Key(name, mode), accidentals))
    ranked.sort(key=lambda row: row[0], reverse=True)
    return ranked


def choose_key(source):
    """The key signature the page should carry.

    Krumhansl gives a *tonic*; it does not care what the page looks like. A
    piece in D flat comes back as C sharp, which prints seven sharps and turns
    a page of flats into a thicket of double sharps. Among the keys that fit
    the music equally well — the same sound under two signatures scores the
    same — take the one with the fewest accidentals, flats before sharps.
    """
    ranked = rank_keys(source)
    if not ranked:
        return source.analyze("key")
    best = ranked[0][0]
    candidates = [row for row in ranked if best - row[0] <= 0.02]
    _, chosen, _ = min(candidates, key=lambda row: (abs(row[2]), -row[2]))
    return chosen


def read_events(path):
    """(voice, pitch, onset, length) for every sounding note, in quarter notes.

    A file's own tracks are the composer's own split between the hands; only a
    single-track file has to be guessed at, and then middle C is the line an
    engraver draws.
    """
    score = converter.parse(path)
    parts = list(score.parts)
    multi = len(parts) > 1
    events = []
    for index, part in enumerate(parts):
        for element in part.recurse().notes:
            pitches = list(element.pitches) if hasattr(element, "pitches") else [element.pitch]
            onset = float(element.getOffsetInHierarchy(score))
            length = float(element.duration.quarterLength)
            for pitch in pitches:
                events.append((index if multi else None, pitch.midi, onset, length))
    events.sort(key=lambda e: (e[1 + 0], e[2]))
    return score, events, multi


# ------------------------------------------------------------- cleaning

def start_at_zero(events):
    if not events:
        return events
    origin = min(onset for _, _, onset, _ in events)
    return [(voice, pitch, onset - origin, length) for voice, pitch, onset, length in events]


def snap(events, grid, bar_length=0.0):
    """Put every note on the grid the ear hears, and keep it there.

    A transcription reports measured time: 0.33 of a beat here, 0.51 there.
    Notation has no such thing. Onsets move to the nearest grid step, a note
    keeps at least one step, and a note of the same key struck again cuts the
    one before it, because one key cannot sound twice.
    """
    snapped = []
    for voice, pitch, onset, length in events:
        start = round(onset / grid) * grid
        span = max(grid, round(length / grid) * grid)
        snapped.append((voice, pitch, start, span))

    by_key = {}
    for index, (voice, pitch, start, span) in enumerate(snapped):
        by_key.setdefault((voice, pitch, round(start, 6)), index)

    kept = []
    seen = set()
    for index, event in enumerate(snapped):
        voice, pitch, start, span = event
        identity = (voice, pitch, round(start, 6))
        if identity in seen:
            continue
        seen.add(identity)
        kept.append(event)

    # A hand plays one thing at a time. The next attack in that hand ends the
    # note before it, exactly as a pianist's finger does; without this the
    # held notes run past the barline and the page fills with ties that no
    # performer needs.
    by_hand = {}
    for index, (voice, pitch, start, span) in enumerate(kept):
        by_hand.setdefault(voice, []).append((start, index))
    result = list(kept)
    for hits in by_hand.values():
        hits.sort()
        for position in range(len(hits) - 1):
            start, index = hits[position]
            following = hits[position + 1][0]
            voice, pitch, _, span = result[index]
            limit = following - start
            if span > limit:
                result[index] = (voice, pitch, start, max(grid, limit))
    # Nothing runs past the barline: a note that would is tied by the
    # engraver, not stretched over the bar it does not belong to.
    if bar_length:
        for index, (voice, pitch, start, span) in enumerate(result):
            end_of_bar = (int(start // bar_length) + 1) * bar_length
            room = end_of_bar - start
            if span > room:
                result[index] = (voice, pitch, start, max(grid, room))
    return result


def spell(events, found_key):
    """Give every pitch the letter the key asks for.

    A MIDI note is a number. In D flat major the black key above C is a
    D flat, not a C sharp; spelled as a C sharp it needs an accidental on
    every single note. This is what turns a chromatic smear into music.
    """
    if found_key is None:
        return [(voice, m21pitch.Pitch(pitch), onset, length) for voice, pitch, onset, length in events]
    scale = {step.pitchClass: step for step in found_key.getScale().getPitches()}
    spelled = []
    for voice, midi, onset, length in events:
        step = scale.get(midi % 12)
        candidate = None
        if step is not None:
            try:
                candidate = m21pitch.Pitch(step.name + str(midi // 12 - 1))
            except Exception:
                candidate = None
        if candidate is None or candidate.midi != midi:
            # A chromatic note outside the scale: spell it the way the
            # signature leans, so a flat key stays flat and a sharp key sharp.
            candidate = m21pitch.Pitch(midi)
            if found_key.sharps < 0 and candidate.name.endswith("#"):
                candidate = candidate.getEnharmonic()
            elif found_key.sharps > 0 and candidate.name.endswith("-"):
                candidate = candidate.getEnharmonic()
        spelled.append((voice, candidate, onset, length))
    return spelled


# -------------------------------------------------------------- notation

def flatten_single_voice_measures(part):
    """A measure whose second voice is the only one playing belongs in one voice.

    makeVoices answers any overlap with a second line, and a line that then
    stays silent still prints its whole rest — a staff that looks empty above
    the notes it is actually playing. When only one of the voices sounds, its
    notes are folded back into the measure and the empty line is dropped.
    """
    for measure in part.getElementsByClass(stream.Measure):
        voices = list(measure.getElementsByClass(stream.Voice))
        if len(voices) < 2:
            continue
        sounding = [voice for voice in voices if voice.notes]
        if len(sounding) != 1:
            continue
        elements = [(element.getOffsetInHierarchy(measure), element)
                    for element in sounding[0].notesAndRests]
        for voice in voices:
            measure.remove(voice)
        for offset, element in elements:
            measure.insert(offset, element)


def build(events, signature_text, bpm, split, tonic, title):
    score = stream.Score()
    score.metadata = metadata.Metadata()
    score.metadata.title = title
    score.metadata.movementName = None
    score.metadata.composer = ""

    voices = sorted({voice for voice, _, _, _ in events if voice is not None})
    if len(voices) >= 2:
        right_id, left_id = voices[0], voices[1]
        def hand_of(voice, pitch):
            return "right" if voice == right_id and voice != left_id else "left"
    else:
        def hand_of(voice, pitch):
            return "right" if pitch >= split else "left"

    right = stream.Part(id="right")
    left = stream.Part(id="left")
    right.insert(0, clef.TrebleClef())
    left.insert(0, clef.BassClef())

    # Notes one hand strikes together are one chord. Seven separate notes at
    # one moment are seven voices to a reader, and a piano has two.
    moments = {}
    for voice, pitch, onset, length in events:
        moments.setdefault((hand_of(voice, pitch.midi), round(onset, 6)), []).append((pitch, length))
    for (hand, onset), members in sorted(moments.items(), key=lambda item: (item[0][1])):
        pitches = sorted({pitch for pitch, _ in members}, key=lambda p: p.midi)
        span = max(length for _, length in members)
        target = right if hand == "right" else left
        element = note.Note(pitches[0]) if len(pitches) == 1 else chord.Chord(pitches)
        element.duration = duration.Duration(quarterLength=span)
        element.volume.velocity = 80
        target.insert(onset, element)

    score.insert(0, meter.TimeSignature(signature_text))
    mark = tempo.MetronomeMark(number=round(bpm))
    score.insert(0, mark)

    for part in (right, left):
        score.insert(0, part)
        part.insert(0, meter.TimeSignature(signature_text))
        part.insert(0, copy.deepcopy(mark))
        part.insert(0, key.Key(tonic) if tonic else key.Key("C"))

    # Measures, gaps, beams: what a flat transcription lacks.
    #
    # A hand is one line. When a captured length runs past the next attack of
    # that same hand, the key was already released; engraving the two as
    # simultaneous voices fills the page with whole rests and stray ties, so
    # the length is capped instead. This is the difference between a piano
    # staff and a page of counterpoint nobody played.
    for part in (right, left):
        part.makeMeasures(inPlace=True)
        part.makeVoices(inPlace=True)
        part.makeRests(fillGaps=True, inPlace=True)
        flatten_single_voice_measures(part)
        part.makeTies(inPlace=True)
        part.makeBeams(inPlace=True)
    score.makeNotation(inPlace=True)

    group = layout.StaffGroup([right, left], symbol="brace", barTogether=True)
    score.insert(0, group)
    return score


def engrave(score, out):
    xml = out.with_suffix(".musicxml")
    score.write("musicxml", fp=str(xml))
    print(f"musicxml: {xml}")

    lilypond = shutil.which("lilypond") or "/opt/homebrew/bin/lilypond"
    musicxml2ly = shutil.which("musicxml2ly") or "/opt/homebrew/bin/musicxml2ly"
    if not Path(lilypond).exists():
        print("lilypond: not installed, stopping at MusicXML")
        return 0

    ly = out.with_suffix(".ly")
    converted = subprocess.run([musicxml2ly, "-o", str(ly), str(xml)],
                               capture_output=True, text=True)
    if converted.returncode != 0:
        print("musicxml2ly failed:", converted.stdout[-600:], converted.stderr[-600:])
        return 1
    # musicxml2ly repeats the title as a subtitle; an edition prints one.
    try:
        text = ly.read_text()
        lines = text.splitlines()
        title = next((l for l in lines if l.strip().startswith('title =')), None)
        if title:
            name = title.split('=', 1)[1].strip()
            cleaned_lines = [l for l in lines
                             if not (l.strip().startswith('subtitle =') and l.split('=', 1)[1].strip() == name)]
            ly.write_text("\n".join(cleaned_lines) + "\n")
    except Exception:
        pass

    result = subprocess.run([lilypond, "-o", str(out), str(ly)],
                            capture_output=True, text=True, cwd=str(out.parent))
    if result.returncode != 0:
        print("lilypond failed:", result.stdout[-900:], result.stderr[-900:])
        return 1
    print(f"pdf: {out.with_suffix('.pdf')}")
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("midi")
    parser.add_argument("out")
    parser.add_argument("--grid", type=float, default=0.5, help="grid in quarter notes")
    parser.add_argument("--split", type=int, default=60)
    parser.add_argument("--ts", default=None)
    parser.add_argument("--title", default=None)
    args = parser.parse_args()

    source, events, multi = read_events(args.midi)

    signature_text = args.ts
    if not signature_text:
        for found in source.recurse().getElementsByClass(meter.TimeSignature):
            signature_text = f"{found.numerator}/{found.denominator}"
            break
        signature_text = signature_text or "4/4"
    bpm = 0
    for found in source.recurse().getElementsByClass(tempo.MetronomeMark):
        bpm = found.number or 0
        break
    bpm = bpm or 120

    found_key = choose_key(source)
    tonic = found_key.tonic.name if found_key is not None else None

    try:
        beats, unit = (int(piece) for piece in signature_text.split("/"))
        bar_length = beats * 4.0 / unit
    except ValueError:
        bar_length = 4.0
    cleaned = spell(snap(start_at_zero(events), args.grid, bar_length), found_key)
    title = args.title or Path(args.midi).stem.replace("-", " ").title()
    score = build(cleaned, signature_text, bpm, args.split, tonic, title)

    print(f"notes in {len(events)}, on the page {len(cleaned)}, "
          f"{signature_text} @ {round(bpm)}, key {found_key}")
    return engrave(score, Path(args.out).expanduser().resolve())


if __name__ == "__main__":
    sys.exit(main())
