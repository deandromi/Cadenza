"""Generates goldens for the Swift runtime checks, replicating transcribe()'s
first 16 s segment exactly:
  - pad the audio by (segmentSize - step) = 8 s on both sides
  - take segment [0, 16s], frame it (T=690), normalize, mel, backbone, scorer
  - decode with forcedStartPos = frame index of the 8 s pre-roll
  - assemble notes with the attribute heads
Outputs raw f32 goldens + notes_gold.json (compared against transcribe()).
"""
import json
import math
import sys
import wave
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "third_party" / "transkun"))
import moduleconf
from transkun.Util import makeFrame

REPO = Path(__file__).resolve().parent.parent
SEGMENT_SECONDS = 16.0
STEP_SECONDS = 8.0


def main() -> None:
    out_dir = REPO / "Fixtures" / "golden"
    out_dir.mkdir(parents=True, exist_ok=True)

    with wave.open(str(REPO / "Fixtures" / "cmaj_stacked.wav")) as w:
        fs = w.getframerate()
        audio = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 2 ** 15

    manager = moduleconf.parseFromFile(str(REPO / "third_party" / "transkun" / "transkun" / "pretrained" / "2.0.conf"))
    TransKun = manager["Model"].module.TransKun
    model = TransKun(conf=manager["Model"].config)
    checkpoint = torch.load(str(REPO / "third_party" / "transkun" / "transkun" / "pretrained" / "2.0.pt"), map_location="cpu", weights_only=False)
    model.load_state_dict(checkpoint.get("best_state_dict", checkpoint.get("state_dict")), strict=False)
    model.eval()

    hop, win = model.hopSize, model.windowSize

    # replicate transcribe(): pad both sides by padTimeBegin
    pad_time_begin = SEGMENT_SECONDS - STEP_SECONDS
    pad_samples = math.ceil(pad_time_begin * fs)
    x = torch.from_numpy(audio).unsqueeze(-1).transpose(-1, -2)  # [1, N]
    x = torch.nn.functional.pad(x, (pad_samples, math.ceil(fs * pad_time_begin)))

    segment_size = math.ceil(SEGMENT_SECONDS * fs)
    cur_slice = x[:, 0:segment_size]
    if cur_slice.shape[-1] < segment_size:
        cur_slice = torch.nn.functional.pad(cur_slice, (0, segment_size - cur_slice.shape[-1]))

    cur_frames = makeFrame(cur_slice, hop, win)          # [1, T, W]
    T = cur_frames.shape[-2]
    frames4 = cur_frames.unsqueeze(0)                      # [1, 1, T, W]

    with torch.no_grad():
        mean = frames4.mean(dim=[1, 2, 3], keepdim=True)
        std = frames4.std(dim=[1, 2, 3], keepdim=True)
        frames_norm = (frames4 - mean) / (std + 1e-8)
        features = model.framewiseFeatureExtractor(frames_norm)
        flat = features.reshape(1, T, 229, 6)
        ctx = model.backbone(flat, outputIndices=torch.tensor(model.targetMIDIPitch, dtype=torch.long))
        S_batch, S_skip_batch = model.scorer(ctx)
        S = S_batch.flatten(-2, -1)
        S_skip = S_skip_batch.flatten(-2, -1)

    # raw audio of the padded segment (what the app would feed)
    cur_slice.numpy().tofile(out_dir / "audio_window.f32")
    flat.detach().numpy().tofile(out_dir / "mel_gold.f32")
    S.detach().numpy().tofile(out_dir / "S_gold.f32")
    S_skip.detach().numpy().tofile(out_dir / "S_skip_gold.f32")
    ctx.detach().numpy().tofile(out_dir / "ctx_gold.f32")
    print("T =", T, "S shape:", tuple(S.shape))

    # decode the segment like transcribe() does
    start_frame_idx = math.floor(pad_time_begin * fs / hop)
    with torch.no_grad():
        notes, _ = model.transcribeFrames(
            frames4, forcedStartPos=[start_frame_idx] * len(model.targetMIDIPitch),
            velocityCriteron="hamming", onsetBound=None, lastFrameIdx=round(segment_size / hop))
    begin_time = 0 / fs - pad_time_begin
    rows = []
    for n in notes[0]:
        start = max(float(n.start) + begin_time, 0.0)
        end = max(float(n.end) + begin_time, start)
        rows.append({"pitch": int(n.pitch), "start": round(start, 4), "end": round(end, 4), "velocity": int(n.velocity)})
    rows.sort(key=lambda r: (r["start"], r["pitch"]))
    (out_dir / "notes_gold.json").write_text(json.dumps(rows, indent=2))
    print("segment notes:", rows)

    # full transcribe() reference for comparison
    with torch.no_grad():
        ref = model.transcribe(torch.from_numpy(audio).unsqueeze(-1))
    ref_rows = sorted(
        [{"pitch": int(n.pitch), "start": round(float(n.start), 4), "end": round(float(n.end), 4), "velocity": int(n.velocity)} for n in ref],
        key=lambda r: (r["start"], r["pitch"]))
    print("transcribe() reference:", ref_rows)


if __name__ == "__main__":
    main()
