import numpy as np
import coremltools as ct

mel = np.fromfile("Fixtures/golden/mel_gold.f32", dtype=np.float32).reshape(1, 174, 229, 6)
S_gold = np.fromfile("Fixtures/golden/S_gold.f32", dtype=np.float32).reshape(174, 174, 90)

model = ct.models.MLModel("Models/TranskunBackbone.mlpackage")
out = model.predict({"mel": mel})
S = np.asarray(out["S"])
print("S shape", S.shape)
d = np.abs(S - S_gold)
print("max diff", d.max(), "mean", d.mean())
idx = np.unravel_index(np.argmax(d), d.shape)
print("worst at", idx, "ml", S[idx], "gold", S_gold[idx])
# where are big diffs
big = np.argwhere(d > 1.0)
print("num diffs > 1:", len(big), "of", d.size)
if len(big):
    print("sample big diffs:", [(tuple(b), float(d[tuple(b)])) for b in big[:5]])
