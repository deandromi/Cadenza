"""Replay a recorded Cadenza session through the original Transkun
reference pipeline, for a like-for-like comparison with the Swift app.

Reads a raw float32 mono capture at the given device rate, resamples with
soxr (the reference's own converter, independent of the Swift resampler),
transcribes with model.transcribe, and prints the notes as one line of
tab-separated "pitch @start-end vvelocity" fields, matching --replay.
"""
import sys
from pathlib import Path

import numpy as np
import torch


def main() -> None:
    if len(sys.argv) < 3:
        print("usage: replay_session.py <capture.f32> <deviceRate>")
        sys.exit(1)
    path = Path(sys.argv[1])
    rate = int(sys.argv[2])

    audio = np.fromfile(str(path), dtype=np.float32)
    print(f"replay-session: {len(audio)} samples at {rate} Hz")
    if len(audio) == 0:
        print("replay-session FAILED: empty capture")
        sys.exit(1)

    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "third_party" / "transkun"))

    import moduleconf

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

    import torchaudio.functional

    if rate != model.fs:
        audio = torchaudio.functional.resample(
            torch.from_numpy(audio), rate, model.fs
        ).numpy()
    x = torch.from_numpy(audio).unsqueeze(-1)
    notes = model.transcribe(x, stepInSecond=8.0, segmentSizeInSecond=16.0)
    print(f"replay-session: {len(notes)} notes")
    for n in sorted(notes, key=lambda n: (n.start, n.pitch)):
        print(f"ref note: {n.pitch} @{n.start:.3f}-{n.end:.3f} v{n.velocity}")


if __name__ == "__main__":
    main()
