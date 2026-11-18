import sys
from pathlib import Path
import numpy as np, torch, wave

sys.path.insert(0, "third_party/transkun")
import moduleconf
from transkun.Util import makeFrame

repo = Path(".")
weight = repo/"third_party/transkun/transkun/pretrained/2.0.pt"
conf_path = repo/"third_party/transkun/transkun/pretrained/2.0.conf"
confManager = moduleconf.parseFromFile(str(conf_path))
TransKun = confManager["Model"].module.TransKun
conf = confManager["Model"].config
checkpoint = torch.load(str(weight), map_location="cpu", weights_only=False)
model = TransKun(conf=conf)
model.load_state_dict(checkpoint.get("best_state_dict", checkpoint.get("state_dict")), strict=False)
model.eval()

with wave.open("Fixtures/cmaj_stacked.wav") as w:
    audio = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32)/2**15

x = torch.from_numpy(audio).unsqueeze(-1)  # [N, 1]
xBatch = x.transpose(-1, -2)  # [1, N]
with torch.no_grad():
    framesBatch = makeFrame(xBatch, model.hopSize, model.windowSize)
    print("framesBatch:", tuple(framesBatch.shape))
    framesBatch4 = framesBatch.unsqueeze(0)
    crfBatch, ctx = model.processFramesBatch(framesBatch4)
    print("framesBatch4:", tuple(framesBatch4.shape))
    S_batch, S_skip_batch = crfBatch.score, crfBatch.noiseScore
    print("S:", tuple(S_batch.shape), "S_skip:", tuple(S_skip_batch.shape))
    np.save("Fixtures/golden/frames_probe.npy", framesBatch.numpy())
    np.save("Fixtures/golden/S_probe.npy", S_batch.numpy())
    np.save("Fixtures/golden/S_skip_probe.npy", S_skip_batch.numpy())
    np.save("Fixtures/golden/ctx_probe.npy", ctx.numpy())
