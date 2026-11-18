import numpy as np

g = np.fromfile("Fixtures/golden/mel_gold.f32", dtype=np.float32).reshape(1, 174, 229, 6)
s = np.fromfile("Fixtures/golden/mel_swift_debug.f32", dtype=np.float32).reshape(1, 174, 229, 6)
mb = np.fromfile("Fixtures/golden/melblock_swift_debug.f32", dtype=np.float32).reshape(6, 229)

eps = 1e-5
logmel = ((mb + eps).astype(np.float64).astype(np.float32))
import math
logmel = (np.log(mb + eps) - math.log(eps)) / (-math.log(eps))
print("log of swift melblock ch0[:5]:", logmel[0, :5])
print("gold mel frame0 ch0[:5]:", g[0, 0, :5, 0])
print("swift out frame0 ch0[:5]:", s[0, 0, :5, 0])
