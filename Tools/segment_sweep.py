"""Segment/step sweep for the real-time design.

Runs the reference transcribe() with several window configurations on a
recorded session and compares each against the verified 16 s / 8 s baseline.

A window's trailing edge never sees future audio, so a config of
(segment=S, step=K) simulates streaming with:
  - window = [now-S, now], refreshed every K seconds
  - the same forced-start chaining the streaming engine must do

It reports, per config:
  - note counts and greedy matches against the baseline
    (same pitch, onset within tolerance)
  - onset/offset deviation and velocity deltas for matched notes
  - wall time, window count, average per-window decode time,
    and the realtime factor (wall / audio duration)

The smallest config that still matches the baseline is the streaming design.
"""
import sys
import time
from pathlib import Path

import numpy as np
import torch


def load_model():
    repo = Path(__file__).resolve().parent.parent
    sys.path.insert(0, str(repo / "third_party" / "transkun"))
    import moduleconf

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
    return model


def note_key(n):
    return (n.start, n.pitch)


def diff(ref, cfg, onset_tol=0.040):
    ref = sorted(ref, key=note_key)
    cfg = sorted(cfg, key=note_key)
    used = [False] * len(cfg)
    ref_hit = [False] * len(ref)
    matched = []
    for i, rn in enumerate(ref):
        best = None
        for j, cn in enumerate(cfg):
            if used[j] or cn.pitch != rn.pitch:
                continue
            d = abs(cn.start - rn.start)
            if d <= onset_tol and (best is None or d < best[0]):
                best = (d, j)
        if best:
            used[best[1]] = True
            ref_hit[i] = True
            matched.append((rn, cfg[best[1]]))
    missed = [n for i, n in enumerate(ref) if not ref_hit[i]]
    extra = [cn for j, cn in enumerate(cfg) if not used[j]]

    onset_devs = np.array([cn.start - rn.start for rn, cn in matched])
    offset_devs = np.array([cn.end - rn.end for rn, cn in matched])
    vel_diffs = np.array([cn.velocity - rn.velocity for rn, cn in matched])

    def stats(a):
        if len(a) == 0:
            return "n/a"
        return (
            f"mean {a.mean()*1000:+.1f} ms, |mean| {abs(a).mean()*1000:.1f} ms, "
            f"p95 |dev| {np.percentile(abs(a), 95)*1000:.1f} ms, "
            f"max |dev| {abs(a).max()*1000:.1f} ms"
        )

    print(f"    matched {len(matched)}/{len(ref)}, missed {len(missed)}, extra {len(extra)}")
    print(f"    onset  dev: {stats(onset_devs)}")
    print(f"    offset dev: {stats(offset_devs)}")
    print(f"    veloc  dev: mean {vel_diffs.mean():+.2f}, |p95| {np.percentile(abs(vel_diffs), 95):.2f}, max {abs(vel_diffs).max():.2f}")
    if missed:
        sample = ", ".join(f"{n.pitch}@{n.start:.2f}" for n in missed[:8])
        print(f"    missed sample: {sample}")
    if extra:
        sample = ", ".join(f"{n.pitch}@{n.start:.2f}" for n in extra[:8])
        print(f"    extra sample: {sample}")


def main() -> None:
    if len(sys.argv) < 3:
        print("usage: segment_sweep.py <capture.f32> <deviceRate>")
        sys.exit(1)
    path = Path(sys.argv[1])
    rate = float(sys.argv[2])

    audio = np.fromfile(str(path), dtype=np.float32)
    print(f"sweep: {len(audio)} samples at {int(rate)} Hz ({len(audio)/rate:.1f} s)")
    if len(audio) == 0:
        print("sweep FAILED: empty capture")
        sys.exit(1)

    second = int(rate)
    absr = np.abs(audio[: len(audio) // second * second]).reshape(-1, second).max(axis=1)
    print(f"sweep: peak per second: min {absr.min():.4f}, max {absr.max():.4f}")

    model = load_model()

    import torchaudio.functional

    x = audio
    if rate != model.fs:
        x = torchaudio.functional.resample(torch.from_numpy(audio), int(rate), model.fs).numpy()
    x = torch.from_numpy(x).unsqueeze(-1)
    duration = x.shape[0] / model.fs

    default_configs = "16/8,16/2,16/1,16/0.5"
    configs = []
    for arg in sys.argv[3:] if len(sys.argv) > 3 else [default_configs]:
        for spec in arg.split(","):
            segment, step = spec.split("/")
            configs.append((float(segment), float(step)))

    ref_notes = None
    for segment, step in configs:
        pad = segment - step
        n_windows = max(1, int(np.ceil((duration - pad) / step)))
        t0 = time.time()
        notes = model.transcribe(x, stepInSecond=step, segmentSizeInSecond=segment)
        wall = time.time() - t0
        per_window = wall / n_windows
        print(f"config segment={segment} step={step}: {len(notes)} notes in {wall:.1f} s"
              f" ({n_windows} windows, {per_window:.2f} s/window, {wall/duration:.2f}x realtime, realtime factor {duration/wall:.2f})")
        if ref_notes is None:
            ref_notes = notes
            print("    (baseline)")
        else:
            diff(ref_notes, notes)
        sys.stdout.flush()


if __name__ == "__main__":
    main()
