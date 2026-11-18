"""Reference transcription with Transkun directly on wav files.

Avoids pydub/ffmpeg (transkun's transcribe.py reads mp3 only); loads the
checkpoint the same way, resamples if needed, and prints note events
(midi pitch, onset s, offset s, velocity) as JSON for later comparison
against the CoreML path.
"""
import json
import wave
import sys
from pathlib import Path

import numpy as np
import torch


def read_wav(path: Path) -> tuple[int, np.ndarray]:
    with wave.open(str(path)) as w:
        assert w.getsampwidth() == 2
        assert w.getnchannels() == 1
        fs = w.getframerate()
        raw = w.readframes(w.getnframes())
    y = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 2 ** 15
    return fs, y


def main() -> None:
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "third_party" / "transkun"))

    import moduleconf
    from transkun.Data import writeMidi

    repo = Path(__file__).resolve().parent.parent
    weight = repo / "third_party" / "transkun" / "transkun" / "pretrained" / "2.0.pt"
    conf_path = repo / "third_party" / "transkun" / "transkun" / "pretrained" / "2.0.conf"

    confManager = moduleconf.parseFromFile(str(conf_path))
    TransKun = confManager["Model"].module.TransKun
    conf = confManager["Model"].config

    checkpoint = torch.load(str(weight), map_location="cpu", weights_only=False)
    model = TransKun(conf=conf)
    state = checkpoint.get("best_state_dict", checkpoint.get("state_dict"))
    model.load_state_dict(state, strict=False)
    model.eval()
    torch.set_grad_enabled(False)

    for wav_path in sys.argv[1:]:
        fs, audio = read_wav(Path(wav_path))
        if fs != model.fs:
            import soxr
            audio = soxr.resample(audio, fs, model.fs)
        # transcribe() expects (frames, channels); our wavs are mono
        x = torch.from_numpy(audio).unsqueeze(-1)
        notes = model.transcribe(x)
        rows = [
            {
                "pitch": n.pitch,
                "start": round(float(n.start), 4),
                "end": round(float(n.end), 4),
                "velocity": int(n.velocity),
            }
            for n in notes
        ]
        rows.sort(key=lambda r: (r["start"], r["pitch"]))
        print(f"== {wav_path}: {len(rows)} notes")
        print(json.dumps(rows))
        out_midi = Path(wav_path).with_suffix(".ref.mid")
        writeMidi(notes).write(str(out_midi))
        print(f"wrote {out_midi}")


if __name__ == "__main__":
    main()
