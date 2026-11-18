import numpy as np
import coremltools as ct

mel = np.fromfile("Fixtures/golden/mel_gold.f32", dtype=np.float32).reshape(1, 174, 229, 6)
model = ct.models.MLModel("Models/TranskunBackbone.mlpackage")
out = model.predict({"mel": mel})
np.asarray(out["S"]).tofile("Fixtures/golden/S_mlpython_debug.f32")

s = np.fromfile("Fixtures/golden/S_swift_debug.f32", dtype=np.float32).reshape(174, 174, 90)
m = np.fromfile("Fixtures/golden/S_mlpython_debug.f32", dtype=np.float32).reshape(174, 174, 90)
g = np.fromfile("Fixtures/golden/S_gold.f32", dtype=np.float32).reshape(174, 174, 90)
print("swift-ml vs python-ml max:", np.abs(s - m).max())
print("swift-ml vs gold max:", np.abs(s - g).max())
print("python-ml vs gold max:", np.abs(m - g).max())
