"""Time the compiled CoreML backbone under each compute unit choice and
check numerics against the eager gold tensors.

For each compute unit (cpu_only, cpu_and_gpu, cpu_and_ne, all):
  - load Models/TranskunBackbone.mlpackage with that preference
  - predict on the golden mel a few times, reporting steady-state wall time
  - compare S and S_skip outputs against Fixtures/golden/S_gold.f32 and
    S_skip_gold.f32, and check the decoded intervals still match
"""
import sys
import time
from pathlib import Path

import numpy as np
import coremltools as ct

REPO = Path(__file__).resolve().parent.parent
SEGMENTS_T = 691


def decode_interval_count(S, S_skip):
    sys.path.insert(0, str(REPO / "third_party" / "transkun"))
    import torch
    from transkun.CRF.NeuralSemiCRFInterval import NeuralSemiCRFInterval

    crf = NeuralSemiCRFInterval(
        torch.from_numpy(S.reshape(SEGMENTS_T, SEGMENTS_T, 90)),
        torch.from_numpy(S_skip.reshape(SEGMENTS_T - 1, 90)),
    )
    path = crf.decode(forcedStartPos=[0] * 90, forward=False)
    return sorted((s, i) for s, track in enumerate(path) for i in track)


def main() -> None:
    mel = np.fromfile(REPO / "Fixtures" / "golden" / "mel_gold.f32", dtype=np.float32)
    mel = mel.reshape(1, SEGMENTS_T, 229, 6)
    S_gold = np.fromfile(REPO / "Fixtures" / "golden" / "S_gold.f32", dtype=np.float32)
    S_skip_gold = np.fromfile(REPO / "Fixtures" / "golden" / "S_skip_gold.f32", dtype=np.float32)
    intervals_gold = decode_interval_count(S_gold, S_skip_gold)

    for name, units in (
        ("CPU_ONLY", ct.ComputeUnit.CPU_ONLY),
        ("CPU_AND_GPU", ct.ComputeUnit.CPU_AND_GPU),
        ("CPU_AND_NE", ct.ComputeUnit.CPU_AND_NE),
        ("ALL", ct.ComputeUnit.ALL),
    ):
        try:
            model = ct.models.MLModel(str(REPO / "Models" / "TranskunBackbone.mlpackage"), compute_units=units)
        except Exception as e:
            print(f"{name}: load failed: {e}")
            continue
        try:
            t0 = time.time()
            pred = model.predict({"mel": mel})
            first = time.time() - t0
            times = []
            for _ in range(3):
                t0 = time.time()
                pred = model.predict({"mel": mel})
                times.append(time.time() - t0)
            S = np.asarray(pred["S"])
            S_skip = np.asarray(pred["S_skip"])
            dS = np.abs(S.reshape(SEGMENTS_T, SEGMENTS_T, 90) - S_gold.reshape(SEGMENTS_T, SEGMENTS_T, 90)).max()
            dSkip = np.abs(S_skip.reshape(SEGMENTS_T - 1, 90) - S_skip_gold.reshape(SEGMENTS_T - 1, 90)).max()
            intervals = decode_interval_count(S, S_skip)
            same = intervals == intervals_gold
            steady = min(times)
            print(f"{name}: first {first:.2f}s, steady {steady:.3f}s, max|dS| {dS:.3e}, max|dSkip| {dSkip:.3e}, intervals {'identical' if same else 'DIFFERENT'}")
        except Exception as e:
            print(f"{name}: predict failed: {e}")


if __name__ == "__main__":
    main()
