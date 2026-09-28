# On-device speaker diarization

Inkwell can tell voices apart without sending audio anywhere. This folder holds the model
conversion and the reference implementation that the Swift engine is checked against.

## The model

| | |
|---|---|
| Checkpoint | [`Wespeaker/wespeaker-voxceleb-resnet34-LM`](https://huggingface.co/Wespeaker/wespeaker-voxceleb-resnet34-LM) (`avg_model`) |
| Architecture | ResNet-34 + temporal statistics pooling, 256-d embedding, 6.63 M parameters |
| Trained by | the WeSpeaker project (wenet-e2e), on VoxCeleb2 dev, large-margin fine-tuned |
| Reported accuracy | 0.99 % EER on VoxCeleb1-O (the project's own number; not re-measured here) |
| Input | 200 x 80 mean-normalised Kaldi log-Mel filterbank (2.00 s at 16 kHz) |
| In the app | `SpeakerEmbedding.mlmodelc`, float16, **13.0 MB** |

### Licence

* **Checkpoint: CC-BY-4.0**, as published on the model's Hugging Face page. Attribution is
  carried in `ThirdPartyLicenses/WeSpeaker-ResNet34-CC-BY-4.0.txt` and in the model's own
  `author` / `short_description` metadata.
* **Model definition code: Apache-2.0** (`wespeaker/models/resnet.py` and friends, fetched by
  `convert.py`; not vendored into the app).
* **Training data: VoxCeleb 1 + 2, which are CC-BY-NC-4.0 — non-commercial, research use.**
  The CC-BY-4.0 grant on the weights is what WeSpeaker can give; it does not override the
  dataset's own terms. Every competitive open speaker-embedding checkpoint has this problem
  (SpeechBrain ECAPA-TDNN, 3D-Speaker CAM++ and NVIDIA TitaNet are all VoxCeleb-trained), so
  there was no cleanly-licensed alternative performing anywhere close.

  **This is fine for Inkwell as personal software and would need revisiting before any
  commercial release or App Store submission.** If that day comes, the options are: train an
  embedder on permissively-licensed speech (LibriSpeech CC-BY-4.0, People's Speech CC-BY-SA,
  Common Voice CC0), buy a commercial licence, or go back to the cloud path — which is still
  in the app and still works.

## Rebuilding the Core ML model

```bash
python3 -m venv .venv && .venv/bin/pip install "coremltools>=8" torch numpy
.venv/bin/python tools/diarization/convert.py
```

It downloads the checkpoint and the model definition, traces the embedding network, converts
it to a float16 Core ML program with a fixed `(1, 200, 80)` input, and writes
`Inkwell/Inkwell/Resources/SpeakerEmbedding.mlpackage`. Xcode compiles that to
`SpeakerEmbedding.mlmodelc` in the Sources phase. The script asserts that the Core ML output
still agrees with PyTorch (measured: cosine 0.999955, max abs diff 1.4e-3).

Nothing is trained. If the conversion is ever redone, re-run the unit tests — they pin the
filterbank and the first twelve embedding dimensions against PyTorch reference values.

## The Swift pipeline

`Inkwell/Inkwell/Audio/Diarization/`

| File | Job |
|---|---|
| `KaldiFBank.swift` | log-Mel filterbank matching `torchaudio.compliance.kaldi.fbank` (Povey window, pre-emphasis 0.97, 512-pt FFT, 80 bins, `snip_edges`), vDSP |
| `SpeakerEmbedder.swift` | Core ML wrapper, batched, returns L2-normalised 256-d embeddings |
| `LocalDiarizer.swift` | energy VAD -> 2 s windows on 0.75 s hop -> embed -> average-linkage agglomerative clustering at a cosine threshold -> majority-overlap vote onto transcript segments -> `S1`, `S2`, … by first appearance |
| `DiarizationSelfTest.swift` | `INKWELL_DIARIZE_DEMO=1` runs the bundled demo call on-device and logs accuracy + timing |
| `SpeakerDetection+Local.swift` | the app-facing half: status, auto-trigger, writing the transcript sidecar |

`reference_pipeline.py` is the same pipeline in Python against the original PyTorch model. It
exists so a change in Swift can be checked against something independent, and so thresholds can
be swept quickly.

## Why an energy VAD, and why 2-second windows

Speech/silence is gated on this recording's own quiet-to-loud range (10th to 95th percentile of
per-frame log-Mel energy, cut at 45 %), then short gaps are closed and short bursts dropped.
That is deliberately simple: it has no model to ship and no threshold that depends on how
loudly the room was recorded. It does mean a noisy room degrades it — see the caveats.

2 seconds is what the checkpoint was trained on (`num_frms 200`) and is the usual diarization
window. Shorter windows give sharper turn boundaries and blurrier voiceprints.

## Threshold choice

Cosine distance at which two clusters stop being one person. Swept over six cases; the number
in each cell is the speaker count found, and the fraction is per-segment accuracy after the
majority vote. "true" is the real number of voices.

Singleton clusters (a single 2-second window on its own) are folded into the nearest surviving
voice first, unless the whole recording produced fewer than 12 windows. Without that step the
usable threshold range is 0.52–0.54; with it, it is 0.40–0.56, so **0.50** sits in the middle
rather than on a knife edge.

| case | true | 0.44 | 0.48 | **0.50** | 0.54 | 0.58 | 0.62 |
|---|---|---|---|---|---|---|---|
| one voice, 8 lines | 1 | 1 / 1.00 | 1 / 1.00 | **1 / 1.00** | 1 / 1.00 | 1 / 1.00 | 1 / 1.00 |
| two similar male voices (Ralph, Fred) | 2 | 2 / 1.00 | 2 / 1.00 | **2 / 1.00** | 2 / 1.00 | 2 / 1.00 | 1 / 0.50 |
| three voices, clean (the demo call) | 3 | 3 / 1.00 | 3 / 1.00 | **3 / 1.00** | 3 / 1.00 | 3 / 1.00 | 3 / 1.00 |
| three voices through 64 kbps AAC | 3 | 3 / 1.00 | 3 / 1.00 | **3 / 1.00** | 3 / 1.00 | 3 / 1.00 | 3 / 1.00 |
| five voices, 14 lines | 5 | 5 / 1.00 | 5 / 1.00 | **5 / 1.00** | 5 / 1.00 | 4 / 0.79 | 4 / 0.79 |
| fourteen one-word turns, three voices | 3 | 10 / 0.86 | 8 / 0.86 | **8 / 0.86** | 6 / 0.86 | 5 / 0.86 | 4 / 0.86 |

The one-word-turn case over-splits at every threshold; turns under about a second do not carry
a usable voiceprint. That case has only 10 windows, so singleton pruning is skipped on it.
