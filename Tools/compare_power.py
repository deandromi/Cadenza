import math
import numpy as np
import torch

audio = np.fromfile("Fixtures/golden/audio_window.f32", dtype=np.float32)
W, H = 4096, 1024
nFrame = math.ceil(len(audio) / H) + 1
lPad = W // 2
rPad = (nFrame - 1) * H + W // 2 - len(audio)
padded = np.concatenate([np.zeros(lPad), audio, np.zeros(rPad)]).astype(np.float32)
mean = padded.mean()
std = padded.std()
padded = (padded - mean) / (std + 1e-8)
frame = torch.from_numpy(padded[0:W].copy())
win = torch.from_numpy(np.fromfile("Models/tensors/windows.f32", dtype=np.float32)[:W].copy())
X = torch.fft.rfft(frame * win, norm="ortho")
p = (X.abs() ** 2).numpy()
s = np.fromfile("Fixtures/golden/power_swift_debug.f32", dtype=np.float32)
print("torch power[0:5]", p[:5])
print("swift power[0:5]", s[:5])
print("ratio torch/swift (bins 1..100):", (p[1:100] / s[1:100]).mean())
