"""Renders a MIDI file with the app's recorded piano samples.

The harness synth is a stack of six harmonics: clean, but nothing like a real
piano in the top octaves, where the attack transient carries most of the
energy a transcriber keys on. This renders with the CC0 samples that ship in
Resources/Piano, each note taken from the nearest recorded pitch and shifted,
which is what PianoSampler does at playback. It makes benchmark audio that a
microphone could plausibly have captured.

Usage:
    python3 Tools/render_midi_samples.py <midi> <out.f32> [rate] [maxSeconds]
"""

import array
import json
import math
import struct
import sys
import wave
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def read_midi(path: Path):
    """Minimal SMF reader: returns (onset, pitch, duration, velocity) notes."""
    data = path.read_bytes()
    assert data[:4] == b"MThd"
    _, fmt, tracks, division = struct.unpack(">IHHH", data[4:14])
    offset = 14
    notes = []
    tempos = [(0, 500000)]
    for _ in range(tracks):
        assert data[offset:offset + 4] == b"MTrk"
        length = struct.unpack(">I", data[offset + 4:offset + 8])[0]
        body = data[offset + 8:offset + 8 + length]
        offset += 8 + length
        tick = 0
        i = 0
        running = None
        active = {}
        while i < len(body):
            delta = 0
            while True:
                byte = body[i]
                i += 1
                delta = (delta << 7) | (byte & 0x7F)
                if not byte & 0x80:
                    break
            tick += delta
            status = body[i]
            if status < 0x80:
                status = running
            else:
                i += 1
                running = status
            kind = status & 0xF0
            if status == 0xFF:
                meta = body[i]
                i += 1
                size = 0
                while True:
                    byte = body[i]
                    i += 1
                    size = (size << 7) | (byte & 0x7F)
                    if not byte & 0x80:
                        break
                payload = body[i:i + size]
                i += size
                if meta == 0x51 and size == 3:
                    tempos.append((tick, int.from_bytes(payload, "big")))
                continue
            if status in (0xF0, 0xF7):
                size = 0
                while True:
                    byte = body[i]
                    i += 1
                    size = (size << 7) | (byte & 0x7F)
                    if not byte & 0x80:
                        break
                i += size
                continue
            if kind in (0x80, 0x90):
                pitch, velocity = body[i], body[i + 1]
                i += 2
                if kind == 0x90 and velocity > 0:
                    active.setdefault(pitch, []).append((tick, velocity))
                else:
                    if active.get(pitch):
                        start, vel = active[pitch].pop(0)
                        notes.append((start, pitch, tick, vel))
            elif kind in (0xC0, 0xD0):
                i += 1
            else:
                i += 2

    # tick -> seconds, honouring the file's own tempo map
    tempos.sort()
    if not tempos or tempos[0][0] != 0:
        tempos.insert(0, (0, 500000))

    def seconds(tick):
        total = 0.0
        last_tick, tempo = 0, tempos[0][1]
        for change_tick, change_tempo in tempos:
            if change_tick > tick:
                break
            total += (change_tick - last_tick) * (tempo / 1e6) / division
            last_tick, tempo = change_tick, change_tempo
        total += (tick - last_tick) * (tempo / 1e6) / division
        return total

    rendered = []
    for start, pitch, end, velocity in notes:
        onset = seconds(start)
        duration = max(0.02, seconds(end) - onset)
        rendered.append((onset, pitch, duration, velocity))
    rendered.sort()
    return rendered


def load_samples():
    manifest = json.loads((REPO / "Resources" / "Piano" / "manifest.json").read_text())
    samples = []
    for entry in manifest.get("samples", manifest if isinstance(manifest, list) else []):
        path = REPO / "Resources" / "Piano" / entry.get("file", f"{entry['pitch']}.wav")
        if not path.exists():
            path = REPO / "Resources" / "Piano" / f"{entry['pitch']}.wav"
        with wave.open(str(path)) as handle:
            rate = handle.getframerate()
            raw = handle.readframes(handle.getnframes())
        frames = array.array("h")
        frames.frombytes(raw)
        samples.append((entry["pitch"], rate, [value / 32768.0 for value in frames]))
    samples.sort()
    return samples


def main():
    midi = Path(sys.argv[1])
    out = Path(sys.argv[2])
    rate = int(sys.argv[3]) if len(sys.argv) > 3 else 44100
    limit = float(sys.argv[4]) if len(sys.argv) > 4 else 1e9

    notes = [note for note in read_midi(midi) if note[0] < limit]
    samples = load_samples()
    total = max(note[0] + note[2] for note in notes) + 1.5
    frames = [0.0] * int(total * rate)

    for onset, pitch, duration, velocity in notes:
        source = min(samples, key=lambda entry: abs(entry[0] - pitch))
        sample_pitch, sample_rate, data = source
        ratio = 2 ** ((pitch - sample_pitch) / 12) * (sample_rate / rate)
        gain = (velocity / 127.0) ** 1.6 * 0.9
        start = int(onset * rate)
        # reading the sample faster raises its pitch: one output sample per
        # `ratio` input samples
        length = int(duration * rate)
        step = ratio
        position = 0.0
        for index in range(length):
            base = int(position)
            if base + 1 >= len(data):
                break
            fraction = position - base
            value = data[base] * (1 - fraction) + data[base + 1] * fraction
            target = start + index
            if 0 <= target < len(frames):
                frames[target] += value * gain
            position += step

    peak = max(1e-9, max(abs(value) for value in frames))
    scale = 0.7 / peak
    buffer = array.array("f", [value * scale for value in frames])
    out.write_bytes(buffer.tobytes())
    print(f"rendered {len(notes)} notes -> {out} ({len(frames) / rate:.1f} s at {rate} Hz)")


if __name__ == "__main__":
    main()
