"""Generate a synthetic piano-ish fixture for transcription checks.

Writes wav files (stdlib wave module, no ffmpeg needed). Each tone is a sum of
harmonics with exponential decay so it has piano-like onset and tail.
"""
import wave
import struct
import math
import sys
from pathlib import Path

FS = 44100


def midi_to_hz(midi: int) -> float:
    return 440.0 * math.pow(2.0, (midi - 69) / 12.0)


def piano_tone(midi: int, seconds: float, velocity: float = 1.0) -> list[float]:
    n = int(FS * seconds)
    hz = midi_to_hz(midi)
    out = [0.0] * n
    # decaying harmonic stack; higher partials decay faster
    for harmonic in range(1, 8):
        amp = velocity * (1.0 / (harmonic * harmonic)) * math.exp(-0.35 * (harmonic - 1))
        decay = math.exp(-1.1 * harmonic / 4.0)
        for i in range(n):
            t = i / FS
            env = math.exp(-decay * t)
            out[i] += amp * env * math.sin(2 * math.pi * hz * harmonic * t)
    # fast attack ramp to avoid a click
    attack = int(FS * 0.004)
    for i in range(min(attack, n)):
        out[i] *= i / attack
    return out


def write_wav(path: Path, samples: list[float]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    peak = max(abs(s) for s in samples) or 1.0
    scaled = [max(-1.0, min(1.0, s / peak * 0.95)) for s in samples]
    with wave.open(str(path), "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(FS)
        w.writeframes(b"".join(
            struct.pack("<h", int(s * 32767)) for s in scaled
        ))


def main(out_dir: str) -> None:
    out = Path(out_dir)

    # fixture 1: C major chord (C4 E4 G4) stacked, 4 s
    clip = [0.0] * int(FS * 4)
    for midi in (60, 64, 67):
        tone = piano_tone(midi, 4.0)
        clip = [a + b for a, b in zip(clip, tone)]
    write_wav(out / "cmaj_stacked.wav", clip)

    # fixture 2: melody then chord: C4 D4 E4 arpeggio at 0.5 s each, then Cmaj
    clip = [0.0] * int(FS * 4)
    for idx, midi in enumerate((60, 62, 64)):
        tone = piano_tone(midi, 0.5)
        start = int(FS * 0.5 * idx)
        for i, s in enumerate(tone):
            if start + i < len(clip):
                clip[start + i] += s
    for midi in (60, 64, 67):
        tone = piano_tone(midi, 2.0)
        start = int(FS * 1.5)
        for i, s in enumerate(tone):
            if start + i < len(clip):
                clip[start + i] += s
    write_wav(out / "arp_then_chord.wav", clip)

    print(f"wrote {out/'cmaj_stacked.wav'} and {out/'arp_then_chord.wav'}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "Fixtures")
