#!/usr/bin/env python3
"""Builds Inkwell/Inkwell/Resources/SpeakerEmbedding.mlpackage.

Takes the pretrained WeSpeaker `voxceleb_resnet34_LM` speaker-embedding checkpoint, wraps it so
it returns just the embedding, traces it, and converts it to a float16 Core ML program with a
fixed 200x80 filterbank input. Nothing is trained here.

    python3 -m venv .venv && .venv/bin/pip install "coremltools>=8" torch numpy
    .venv/bin/python tools/diarization/convert.py

Downloads on first run:
  * https://huggingface.co/Wespeaker/wespeaker-voxceleb-resnet34-LM  -> avg_model (43 MB)
  * the ResNet/pooling model definitions from github.com/wenet-e2e/wespeaker (Apache-2.0)

See README.md in this folder for the licence position and the accuracy numbers.
"""
import os
import subprocess
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
CACHE = HERE / ".cache"
OUT = HERE.parent.parent / "Inkwell" / "Inkwell" / "Resources" / "SpeakerEmbedding.mlpackage"

CHECKPOINT = "https://huggingface.co/Wespeaker/wespeaker-voxceleb-resnet34-LM/resolve/main/avg_model"
WESPEAKER_FILES = ["resnet.py", "pooling_layers.py", "multi_view_attention.py"]
WESPEAKER_RAW = "https://raw.githubusercontent.com/wenet-e2e/wespeaker/master/wespeaker/models/"

WINDOW_FRAMES = 200      # 2.00 s at 10 ms/frame — also SpeakerEmbedder.windowFrames in Swift
MEL_BINS = 80
EMBED_DIM = 256


def fetch():
    pkg = CACHE / "wespeaker" / "models"
    pkg.mkdir(parents=True, exist_ok=True)
    (CACHE / "wespeaker" / "__init__.py").touch()
    (pkg / "__init__.py").touch()
    for name in WESPEAKER_FILES:
        dst = pkg / name
        if not dst.exists():
            print(f"  fetching {name}")
            urllib.request.urlretrieve(WESPEAKER_RAW + name, dst)
    ckpt = CACHE / "avg_model.pt"
    if not ckpt.exists():
        print("  fetching avg_model (43 MB)")
        urllib.request.urlretrieve(CHECKPOINT, ckpt)
    return ckpt


def main():
    import numpy as np
    import torch
    import coremltools as ct

    print("1. sources")
    ckpt = fetch()
    sys.path.insert(0, str(CACHE))
    from wespeaker.models.resnet import ResNet34

    print("2. loading the checkpoint")
    net = ResNet34(feat_dim=MEL_BINS, embed_dim=EMBED_DIM, pooling_func="TSTP", two_emb_layer=False)
    missing, unexpected = net.load_state_dict(
        torch.load(ckpt, map_location="cpu", weights_only=True), strict=False)
    assert not missing, f"checkpoint is missing weights: {missing}"
    # `projection.weight` is the training-time classifier head; the embedding is what we want.
    assert unexpected == ["projection.weight"], unexpected
    net.eval()
    print(f"   {sum(p.numel() for p in net.parameters()) / 1e6:.2f} M parameters")

    class EmbeddingOnly(torch.nn.Module):
        def __init__(self, net):
            super().__init__()
            self.net = net

        def forward(self, fbank):          # (1, 200, 80) mean-normalised log-Mel filterbank
            return self.net(fbank)[-1]     # (1, 256)

    wrapped = EmbeddingOnly(net).eval()
    example = torch.randn(1, WINDOW_FRAMES, MEL_BINS)
    with torch.no_grad():
        reference = wrapped(example).numpy().ravel()

    print("3. converting to Core ML (float16, iOS 18+)")
    traced = torch.jit.trace(wrapped, example)
    model = ct.convert(
        traced,
        inputs=[ct.TensorType(name="fbank", shape=(1, WINDOW_FRAMES, MEL_BINS), dtype=np.float32)],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS18,
    )
    model.short_description = (
        "WeSpeaker voxceleb_resnet34_LM speaker embedding (256-d) from a 200x80 "
        "mean-normalised Kaldi log-Mel filterbank. CC-BY-4.0; VoxCeleb-trained.")
    model.author = "WeSpeaker (wenet-e2e), converted with coremltools"
    if OUT.exists():
        subprocess.run(["rm", "-rf", str(OUT)], check=True)
    model.save(str(OUT))

    got = model.predict({"fbank": example.numpy()})["embedding"].ravel()
    cos = float(reference @ got / (np.linalg.norm(reference) * np.linalg.norm(got)))
    print(f"4. wrote {OUT}")
    print(f"   cosine(PyTorch, Core ML) = {cos:.6f}   max abs diff = {np.abs(reference - got).max():.2e}")
    assert cos > 0.999, "float16 conversion drifted too far from the PyTorch model"


if __name__ == "__main__":
    main()
