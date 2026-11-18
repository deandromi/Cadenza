import numpy as np

g = np.fromfile("Fixtures/golden/mel_gold.f32", dtype=np.float32).reshape(1, 174, 229, 6)
s = np.fromfile("Fixtures/golden/mel_swift_debug.f32", dtype=np.float32).reshape(1, 174, 229, 6)
d = np.abs(g - s)[0]
idx = np.unravel_index(np.argmax(d), d.shape)
print("max diff at frame,bin,ch =", idx, "gold", g[0][idx], "swift", s[0][idx])
perFrame = d.max(axis=(1, 2))
print("worst frames:", np.argsort(perFrame)[-8:], perFrame[np.argsort(perFrame)[-8:]])
print("mean diff per frame (first 10):", perFrame[:10])
