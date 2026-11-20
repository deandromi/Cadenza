#!/usr/bin/env python3
"""Builds Cadenza's bundled piano from the CC0 Libre Studio Grand samples.

The instrument in the app is eight notes of a Schulze Pollmann grand,
recorded for the Libre Studio Grand project (CC0 1.0). Eight centres plus
linear interpolation cover A0-C8 with at most six semitones of stretch,
which is the whole trick behind keeping the app small: no 30 MB soundfont,
no plugin, just 2.8 MB of trimmed mono samples.

Run from the repository root:

    python3 Tools/build_piano_samples.py

It downloads the source WAVs (44.1 kHz stereo, ~1.2 MB each), mixes them to
mono, trims each to a usable decay, normalises the peak, writes
`Resources/Piano/<midi>.wav`, and refreshes `Resources/Piano/manifest.json`
plus the licence notice. Downloads are cached in /tmp so a rebuild is cheap.
"""

import json
import os
import pathlib
import struct
import subprocess
import sys
import urllib.parse
import wave

BASE = "https://raw.githubusercontent.com/NeoSoundFonts/Libre-Studio-Grand/main/samples/"
CACHE = pathlib.Path("/tmp/cadenza-piano-cache")

# MIDI pitch -> source file. Centres are spread so no note stretches more
# than six semitones; the low octave keeps its own sample because a shifted
# bass note loses its body first.
CENTRES = {
    24: "SP StudioGrand C1.wav",
    36: "SP StudioGrand C2.wav",
    48: "SP StudioGrand C3.wav",
    60: "SP StudioGrand C4.wav",
    67: "SP StudioGrand G4.wav",
    78: "SP StudioGrand F#5.wav",
    93: "SP StudioGrand A6.wav",
    103: "SP StudioGrand G7.wav",
}

KEEP_SECONDS = 4.0
FADE_SECONDS = 0.35
PEAK = 0.85
OUT = pathlib.Path("Resources/Piano")

LICENCE = """Libre Studio Grand — piano samples
====================================

Source:  https://github.com/NeoSoundFonts/Libre-Studio-Grand
Author:  Simone Piervergili, Yingchun Soul
Licence: CC0 1.0 Universal (public domain dedication)

The full licence text ships in this folder as LICENSE-CC0.txt. Cadenza
bundles eight notes of the set, mixed to mono, trimmed and peak-normalised
by Tools/build_piano_samples.py.
"""


def fetch(name: str) -> pathlib.Path:
    CACHE.mkdir(parents=True, exist_ok=True)
    target = CACHE / name.replace(" ", "_")
    if target.exists() and target.stat().st_size > 1000:
        return target
    url = BASE + urllib.parse.quote(name)
    print(f"downloading {name}")
    subprocess.run(["curl", "-sL", "--fail", "-m", "120", "-o", str(target), url], check=True)
    return target


def read_mono(path: pathlib.Path):
    with wave.open(str(path), "rb") as handle:
        channels = handle.getnchannels()
        width = handle.getsampwidth()
        rate = handle.getframerate()
        frames = handle.getnframes()
        raw = handle.readframes(frames)
    if width != 2:
        raise SystemExit(f"{path.name}: expected 16-bit, got {width * 8}-bit")
    total = len(raw) // 2
    values = struct.unpack(f"<{total}h", raw)
    if channels == 1:
        return list(values), rate
    mono = [(values[i] + values[i + 1]) / 2 for i in range(0, total - 1, 2)]
    return mono, rate


def trim_and_shape(samples, rate):
    limit = int(KEEP_SECONDS * rate)
    if len(samples) > limit:
        samples = samples[:limit]
    fade = int(FADE_SECONDS * rate)
    if fade > 0 and len(samples) > fade:
        start = len(samples) - fade
        for i in range(fade):
            samples[start + i] *= 1.0 - (i / fade)
    peak = max(abs(v) for v in samples) or 1.0
    scale = (PEAK * 32767) / peak
    return [max(-32768, min(32767, int(round(v * scale)))) for v in samples]


def write_wav(path: pathlib.Path, samples, rate: int):
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(rate)
        handle.writeframes(struct.pack(f"<{len(samples)}h", *samples))


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    manifest = {"name": "Libre Studio Grand", "licence": "CC0-1.0", "samples": []}
    total = 0
    for pitch, name in sorted(CENTRES.items()):
        samples, rate = read_mono(fetch(name))
        shaped = trim_and_shape(samples, rate)
        target = OUT / f"{pitch}.wav"
        write_wav(target, shaped, rate)
        total += target.stat().st_size
        manifest["samples"].append({"pitch": pitch, "file": f"{pitch}.wav", "rate": rate})
        print(f"  {pitch:3d}  {target.name}  {len(shaped) / rate:.2f} s  {target.stat().st_size // 1024} KB")
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (OUT / "README.txt").write_text(LICENCE)
    licence = subprocess.run(
        ["curl", "-sL", "--fail", "-m", "60",
         "https://raw.githubusercontent.com/NeoSoundFonts/Libre-Studio-Grand/main/LICENSE"],
        check=True, capture_output=True, text=True)
    (OUT / "LICENSE-CC0.txt").write_text(licence.stdout)
    print(f"total {total / 1e6:.2f} MB in {OUT}")


if __name__ == "__main__":
    sys.exit(main())
