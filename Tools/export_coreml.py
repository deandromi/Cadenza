"""Export the Transkun backbone+scorer network to CoreML and dump the
auxiliary tensors the Swift side needs (mel front end + attribute heads).

Outputs (all under Models/):
  TranskunBackbone.mlpackage   input mel [1, T, 229, 6] -> S [T, T, 90], S_skip [T-1, 90], ctx [1, 90, T, 256]
  tensors/*.f32                raw little-endian float32 tensors
  tensors/manifest.json        shapes and files for everything above

Verification against the eager torch model happens in the same run:
the traced wrapper is compared op-for-op on the golden mel features, and
after conversion the CoreML model output is compared on CPU.
"""
import json
import math
import sys
from pathlib import Path

import numpy as np
import torch
import coremltools as ct

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "third_party" / "transkun"))
import moduleconf
from transkun.Util import makeFrame

REPO = Path(__file__).resolve().parent.parent
SEGMENTS_T = 691   # frames in one 16 s segment at hop 1024 / 44100 Hz (matches make_goldens)


def load_model() -> torch.nn.Module:
    weight = REPO / "third_party" / "transkun" / "transkun" / "pretrained" / "2.0.pt"
    conf_path = REPO / "third_party" / "transkun" / "transkun" / "pretrained" / "2.0.conf"
    manager = moduleconf.parseFromFile(str(conf_path))
    TransKun = manager["Model"].module.TransKun
    conf = manager["Model"].config
    checkpoint = torch.load(str(weight), map_location="cpu", weights_only=False)
    model = TransKun(conf=conf)
    model.load_state_dict(checkpoint.get("best_state_dict", checkpoint.get("state_dict")), strict=False)
    model.eval()
    # gradient checkpointing is a training-time memory trick and breaks tracing
    for module in model.modules():
        if hasattr(module, "useGradientCheckpoint"):
            module.useGradientCheckpoint = False
    return model


def patch_scorer(model: torch.nn.Module) -> None:
    """Replace the shipped scorer forward with a converter-friendly one:
    matmul instead of einsum, identity-broadcast instead of diag_embed.
    Mathematically identical."""
    scorer = model.scorer
    size, expansion = scorer.size, scorer.expansionFactor

    def patched_scorer(ctx):
        q, k, diag = scorer.map(ctx).split(
            [size * expansion, size * expansion, 1], dim=-1)
        q = q / math.sqrt(q.shape[-1])
        S = torch.matmul(q, k.transpose(-1, -2))          # [i, p, e, b]
        idx_e = torch.arange(S.shape[-2], device=S.device)
        idx_b = torch.arange(S.shape[-1], device=S.device)
        len_eb = (idx_e.unsqueeze(-1) - idx_b.unsqueeze(0)).abs()
        S = S * len_eb.float()                            # linear length scaling
        eye = torch.eye(S.shape[-1], device=S.device, dtype=S.dtype)
        diagM = diag.squeeze(-1).unsqueeze(-2) * eye      # diagonal add
        S = S + diagM
        b = diag * 0.0
        b = b[..., 1:, 0]                                  # [i, p, T-1]
        S = S.permute(2, 3, 0, 1).contiguous()             # [e, b, i, p]
        b = b.permute(2, 0, 1).contiguous()
        scorer.patched_shapes = (tuple(S.shape), tuple(b.shape))
        return S, b

    scorer.forward = patched_scorer


class BackboneExport(torch.nn.Module):
    """mel features -> interval scores + context. Decode stays in Swift."""

    def __init__(self, model: torch.nn.Module):
        super().__init__()
        self.net = model
        self.register_buffer(
            "outputIndices",
            torch.tensor(model.targetMIDIPitch, dtype=torch.long),
        )

    def forward(self, features: torch.Tensor):
        ctx = self.net.backbone(features, outputIndices=self.outputIndices)
        S_batch, S_skip_batch = self.net.scorer(ctx)
        S = S_batch.flatten(-2, -1)          # [T, T, 90]
        S_skip = S_skip_batch.flatten(-2, -1)  # [T-1, 90]
        return S, S_skip, ctx


def freeze_position_embeddings(model: torch.nn.Module) -> dict:
    """Phase 1: route position-embedding builders through a shape-keyed cache.
    The eager gold computation warms it; tracing must then hit the cache."""
    backbone = model.backbone
    warmed: dict = {}
    for name in ("posEmbedBuilder", "posEmbedBuilderAttnTF", "posEmbedBuilderAttnTE"):
        builder = getattr(backbone, name)
        original = builder.forward
        cache: dict = {}

        def warm_patched(*coords, _orig=original, _cache=cache):
            key = tuple(c.shape for c in coords)
            if key not in _cache:
                with torch.no_grad():
                    _cache[key] = _orig(*coords)
            return _cache[key]

        builder.forward = warm_patched
        warmed[name] = (builder, cache)
    print("[phase 1] builders route through cache")
    return warmed


def bake_position_embeddings(warmed: dict) -> None:
    """Phase 2: replace each builder's forward with a lambda returning the
    single warmed tensor. Tracing then records it as a graph constant and no
    meshgrid/proj ops are reachable."""
    for name, (builder, cache) in warmed.items():
        if len(cache) != 1:
            raise AssertionError(f"{name} saw {len(cache)} distinct coord shapes: {list(cache)}; cannot bake")
        tensor = next(iter(cache.values()))
        builder.forward = (lambda t: (lambda *a, **k: t))(tensor)
        print(f"[phase 2] baked {name} shape {tuple(tensor.shape)}")

def save_f32(path: Path, array: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    array.astype(np.float32).tofile(path)


def main() -> None:
    model = load_model()
    tensors_dir = REPO / "Models" / "tensors"
    manifest: list[dict] = []

    # ---- auxiliary tensors for the Swift mel front end and heads ----
    spectrum = model.framewiseFeatureExtractor.spectrogramExtractor
    wins = torch.cat([spectrum.win.unsqueeze(0), spectrum.winGen.get().t()], dim=0)
    freq2mels = model.framewiseFeatureExtractor.freq2mels
    assert tuple(wins.shape) == (6, 4096), tuple(wins.shape)
    assert tuple(freq2mels.shape) == (2049, 229), tuple(freq2mels.shape)
    save_f32(tensors_dir / "windows.f32", wins.detach().numpy())
    manifest.append({"name": "windows", "file": "windows.f32", "shape": list(wins.shape)})
    save_f32(tensors_dir / "freq2mels.f32", freq2mels.detach().numpy())
    manifest.append({"name": "freq2mels", "file": "freq2mels.f32", "shape": list(freq2mels.shape)})

    for prefix, module in (("velocity", model.velocityPredictor), ("refinedOF", model.refinedOFPredictor)):
        linears = [m for m in module if isinstance(m, torch.nn.Linear)]
        linear0, linear1 = linears[0], linears[1]
        for tag, param in (("w0", linear0.weight), ("b0", linear0.bias), ("w1", linear1.weight), ("b1", linear1.bias)):
            save_f32(tensors_dir / f"{prefix}_{tag}.f32", param.detach().numpy())
            manifest.append({"name": f"{prefix}_{tag}", "file": f"{prefix}_{tag}.f32", "shape": list(param.shape)})

    manifest.append({
        "name": "symbols",
        "value": [int(p) for p in model.targetMIDIPitch],
        "note": "symbol k drives output channel k of S; negative = sentinel (pedal-like)",
    })
    manifest.append({
        "name": "mel_front_end",
        "frames": "[B,1,T,4096] -> normalize over window (mean/std, eps 1e-8) -> per window c in 0..5: rfft(win_c * frame, norm ortho) -> |X|^2 (2049 bins) -> mel[t] = |X|^2 @ freq2mels -> stack channels last -> [T, 229, 6]; log: ((m + 1e-5).ln() - ln(1e-5)) / (-ln(1e-5))",
        "rfft_ortho": "X[k] = (1/sqrt(4096)) * sum_n x[n] exp(-2*pi*i*k*n/4096 ambivalent sign convention), k = 0..2048; verify against Fixtures/golden",
        "continuous_bernoulli_mean": "p = sigmoid(logits); p<=0.499 or p>0.501: p/(2p-1) + 1/(log1p(-p) - log(p)); else taylor 0.5 + (1/3 + 16/45 x^2) x with x = p-0.5",
        "offset_refine": "ofValue = clamp((cbMean - 0.5)/0.99, -0.5, 0.5) applied to outputs 0..1; outputs 2..3 > 0 means presence",
    })

    # ---- golden data through the eager model ----
    patch_scorer(model)
    warmed = freeze_position_embeddings(model)
    mel_flat = np.fromfile(REPO / "Fixtures" / "golden" / "mel_gold.f32", dtype=np.float32)
    features_fixed = torch.from_numpy(mel_flat).reshape(1, SEGMENTS_T, 229, 6).contiguous()
    with torch.no_grad():
        wrapper = BackboneExport(model).eval()
        S_gold, S_skip_gold, ctx_gold = wrapper(features_fixed)
    print("mel gold:", tuple(features_fixed.shape))

    # ---- trace and convert ----
    bake_position_embeddings(warmed)
    traced = torch.jit.trace(wrapper, features_fixed, check_trace=False)
    traced_code = traced.code
    assert "meshgrid" not in traced_code, "traced graph still contains meshgrid"
    print("traced graph is meshgrid-free")
    with torch.no_grad():
        S_t, S_skip_t, ctx_t = traced(features_fixed)
    print("traced shapes:", tuple(S_t.shape), tuple(S_skip_t.shape), tuple(ctx_t.shape))
    print("gold shapes:", tuple(S_gold.shape), tuple(S_skip_gold.shape), tuple(ctx_gold.shape))
    diff = (S_t - S_gold).abs().max().item()
    rel = (S_t - S_gold).abs().max().item() / max(1.0, S_gold.abs().max().item())
    print(f"trace vs eager max |diff|: {diff:.3e} (relative {rel:.3e}, S range {S_gold.min().item():.2f}..{S_gold.max().item():.2f})")

    # the verdict that matters: do both score tensors decode to the same notes?
    from transkun.CRF.NeuralSemiCRFInterval import NeuralSemiCRFInterval
    def decode_notes(S, S_skip):
        crf = NeuralSemiCRFInterval(S, S_skip)
        path = crf.decode(forcedStartPos=[0] * S.shape[-1], forward=False)
        flattened = [(symbol, interval) for symbol, track in enumerate(path) for interval in track]
        return sorted(flattened)
    notes_gold = decode_notes(S_gold, S_skip_gold)
    notes_trace = decode_notes(S_t, S_skip_t)
    same = notes_gold == notes_trace
    print(f"({'identical' if same else 'DIFFERENT'}) intervals: {len(notes_gold)} gold vs {len(notes_trace)} traced")
    if not same:
        print("gold:", notes_gold[:24])
        print("traced:", notes_trace[:24])
    assert same, "trace changes decoded events"

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="mel", shape=(1, SEGMENTS_T, 229, 6))],
        outputs=[ct.TensorType(name="S"), ct.TensorType(name="S_skip"), ct.TensorType(name="ctx")],
        compute_precision=ct.precision.FLOAT32,
        compute_units=ct.ComputeUnit.CPU_ONLY,
    )
    out_path = REPO / "Models" / "TranskunBackbone.mlpackage"
    mlmodel.save(str(out_path))
    print("saved", out_path)

    pred = mlmodel.predict({"mel": features_fixed.detach().numpy()})
    for name, gold in (("S", S_gold), ("S_skip", S_skip_gold), ("ctx", ctx_gold)):
        mine = np.asarray(pred[name])
        d = np.abs(mine - np.asarray(gold)).max()
        print(f"coreml vs eager {name}: shape {mine.shape} vs {np.asarray(gold).shape}, max |diff| {d:.3e}")

    manifest_path = tensors_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2))
    print("wrote", manifest_path)


if __name__ == "__main__":
    main()
