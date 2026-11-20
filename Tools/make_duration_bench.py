#!/usr/bin/env python3
"""Builds the note-length benchmark: real piano samples cut at known lengths.

The transcription benchmark in --eval scores onsets; this one scores the other
half of a note, how long it lasts. It renders the app's own piano samples
(Resources/Piano) at chosen durations with a 60 ms damping fade, and writes the
matching MIDI as the ground truth, so `--eval <f32> <mid>` reports the offset
error on real piano tone instead of the synthetic six-harmonic tone.

Usage: Tools/make_duration_bench.py [out-prefix]

Writes <prefix>.f32 (44.1 kHz mono float) and <prefix>.mid.
"""

import struct
import sys
import wave
from pathlib import Path

import numpy as np

RATE = 44100
REPO = Path(__file__).resolve().parent.parent
SAMPLES = REPO / "Resources" / "Piano"

# (pitch, key-held seconds): short staccato through two full seconds, spread
# over the register so a low note's ring cannot be mistaken for the next one.
PLAN = [
    (48, 0.15), (60, 0.30), (67, 0.50), (78, 0.80), (93, 1.10), (48, 2.00),
    (67, 0.15), (78, 0.30), (93, 0.50), (60, 0.80), (48, 1.20), (60, 2.00),
]
SPACING = 1.6
LEAD = 1.0
TAIL = 2.6
FADE = 0.06


def load(pitch: int) -> np.ndarray:
    with wave.open(str(SAMPLES / f"{pitch}.wav"), "rb") as handle:
        raw = handle.readframes(handle.getnframes())
        data = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768
        if handle.getnchannels() == 2:
            data = data.reshape(-1, 2).mean(axis=1)
        if handle.getframerate() != RATE:
            index = np.arange(int(len(data) * RATE / handle.getframerate()))
            index = index * handle.getframerate() / RATE
            data = np.interp(index, np.arange(len(data)), data).astype(np.float32)
    return data


def vlq(value: int) -> bytes:
    out = [value & 0x7F]
    value >>= 7
    while value:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    return bytes(reversed(out))


def main() -> None:
    prefix = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/durations")
    samples = {pitch: load(pitch) for pitch, _ in PLAN}
    total = LEAD + len(PLAN) * SPACING + TAIL
    audio = np.zeros(int(total * RATE), dtype=np.float32)
    notes = []
    for index, (pitch, duration) in enumerate(PLAN):
        onset = LEAD + index * SPACING
        start = int(onset * RATE)
        length = min(int(duration * RATE), len(samples[pitch]))
        tone = samples[pitch][:length].copy()
        fade = int(FADE * RATE)
        if len(tone) > fade:
            tone[-fade:] *= np.hanning(fade * 2)[fade:]
        audio[start:start + len(tone)] += tone
        notes.append((pitch, onset, onset + len(tone) / RATE))

    prefix.with_suffix(".f32").write_bytes(audio.tobytes())

    division = 480
    events = []
    for pitch, onset, offset in notes:
        # 120 bpm, so a second is two quarters and the ticks stay exact
        events.append((int(onset * 2 * division), 0x90, pitch, 80))
        events.append((int(offset * 2 * division), 0x80, pitch, 0))
    events.sort(key=lambda event: event[0])
    track = bytearray()
    last = 0
    for tick, status, data1, data2 in events:
        track += vlq(tick - last)
        last = tick
        track += bytes([status, data1, data2])
    track += vlq(0) + b"\xFF\x2F\x00"
    header = b"MThd" + struct.pack(">IHHH", 6, 0, 1, division)
    prefix.with_suffix(".mid").write_bytes(
        header + b"MTrk" + struct.pack(">I", len(track)) + bytes(track)
    )

    print(f"{prefix}.f32: {len(audio) / RATE:.1f} s, {len(notes)} notes")
    print(f"{prefix}.mid: ground truth")
    for pitch, onset, offset in notes:
        print(f"  {pitch} @{onset:.2f}-{offset:.2f} ({offset - onset:.2f} s)")


if __name__ == "__main__":
    main()
