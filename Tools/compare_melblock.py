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

wins = np.fromfile("Models/tensors/windows.f32", dtype=np.float32).reshape(6, W)
f2m = np.fromfile("Models/tensors/freq2mels.f32", dtype=np.float32).reshape(2049, 229)

frame = torch.from_numpy(padded[0:W].copy())
powers = np.zeros((6, 2049), dtype=np.float32)
for c in range(6):
    X = torch.fft.rfft(frame * torch.from_numpy(wins[c].copy()), norm="ortho")
    powers[c] = (X.abs() ** 2).numpy()

mel = powers @ f2m  # [6, 229]
s = np.fromfile("Fixtures/golden/melblock_swift_debug.f32", dtype=np.float32).reshape(6, 229)
print("torch melblock[0,:5]", mel[0, :5])
print("swift melblock[0,:5]", s[0, :5])
print("ratio", (mel[1:100] / np.maximum(s[1:100], 1e-30)).mean())
print("max diff", np.abs(mel - s).max())
