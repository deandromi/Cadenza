"""Compare eager transcribe() vs transcribeFrames() on the cmaj fixture."""
import sys
from pathlib import Path

import numpy as np
import torch
import wave

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "third_party" / "transkun"))
import moduleconf

REPO = Path(__file__).resolve().parent.parent
weight = REPO / "third_party" / "transkun" / "transkun" / "pretrained" / "2.0.pt"
manager = moduleconf.parseFromFile(str(REPO / "third_party" / "transkun" / "transkun" / "pretrained" / "2.0.conf"))
TransKun = manager["Model"].module.TransKun
conf = manager["Model"].config
checkpoint = torch.load(str(weight), map_location="cpu", weights_only=False)
model = TransKun(conf=conf)
model.load_state_dict(checkpoint.get("best_state_dict", checkpoint.get("state_dict")), strict=False)
model.eval()
for module in model.modules():
    if hasattr(module, "useGradientCheckpoint"):
        module.useGradientCheckpoint = False

from transkun.Util import makeFrame

with wave.open(str(REPO / "Fixtures" / "cmaj_stacked.wav")) as w:
    audio = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 2 ** 15
xBatch = torch.from_numpy(audio).unsqueeze(-1).transpose(-1, -2)

with torch.no_grad():
    frames = makeFrame(xBatch, model.hopSize, model.windowSize)
    notes_ref = model.transcribe(torch.from_numpy(audio).unsqueeze(-1))
    notes_ref = sorted([(n.pitch, round(n.start, 3), round(n.end, 3), int(n.velocity)) for n in notes_ref])
    print("transcribe() reference notes:", notes_ref)

    notes_ef, _ = model.transcribeFrames(frames.unsqueeze(0), velocityCriteron="hamming", lastFrameIdx=174)
    notes_ef = sorted([(n.pitch, round(n.start, 3), round(n.end, 3), int(n.velocity)) for n in notes_ef[0]])
    print("transcribeFrames eager notes:", notes_ef)

    # manual replication of transcribe()'s segmented loop over the padded clip
    import math
    import torch.nn.functional as TF
    stepInSecond, segmentSizeInSecond = 8, 16
    padTimeBegin = segmentSizeInSecond - stepInSecond
    xp = TF.pad(xBatch, (math.ceil(padTimeBegin * model.fs), math.ceil(model.fs * padTimeBegin)))
    nSample = xp.shape[-1]
    segmentSize = math.ceil(segmentSizeInSecond * model.fs)
    stepSize = math.ceil(stepInSecond * model.fs / model.hopSize) * model.hopSize
    startPos = [math.floor(padTimeBegin * model.fs / model.hopSize)] * len(model.targetMIDIPitch)
    events = []
    for i in range(0, nSample, stepSize):
        j = min(i + segmentSize, nSample)
        curSlice = xp[:, i:j]
        if curSlice.shape[-1] < segmentSize:
            curSlice = TF.pad(curSlice, (0, segmentSize - curSlice.shape[-1]))
        curFrames = makeFrame(curSlice, model.hopSize, model.windowSize)
        curEvents, lastP = model.transcribeFrames(
            curFrames.unsqueeze(0), forcedStartPos=startPos,
            velocityCriteron="hamming", onsetBound=stepSize, lastFrameIdx=segmentSize // model.hopSize)
        beginTime = i / model.fs - padTimeBegin
        for e in curEvents[0]:
            e.start = max(e.start + beginTime, 0)
            e.end = max(e.end + beginTime, e.start)
            events.append(e)
        startPos = [max(k - int(stepSize / model.hopSize), 0) for k in lastP]
    manual = sorted([(n.pitch, round(n.start, 3), round(n.end, 3), int(n.velocity)) for n in events if n.hasOnset])
    print("manual segmented notes:", manual)
