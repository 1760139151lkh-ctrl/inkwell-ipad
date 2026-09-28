"""Reference (Python) implementation of the on-device diarization pipeline.
Mirrors what the Swift engine does, so the Swift side can be checked against it."""
import json, sys, numpy as np, torch, torchaudio
import torchaudio.compliance.kaldi as kaldi

SR = 16000
WIN_FRAMES = 200          # 2.00 s of fbank frames
HOP_S = 0.75

def load(path):
    import wave
    w = wave.open(path, 'rb')
    assert w.getframerate() == SR and w.getnchannels() == 1 and w.getsampwidth() == 2
    a = np.frombuffer(w.readframes(w.getnframes()), dtype='<i2').astype(np.float32) / 32768.0
    return torch.from_numpy(a)[None, :]

def fbank(wav):
    # wespeaker convention: 16-bit scale input, 80 mel bins, 25 ms / 10 ms, no dither
    return kaldi.fbank(wav * (1 << 15), num_mel_bins=80, frame_length=25, frame_shift=10,
                       dither=0.0, sample_frequency=SR, window_type='povey',
                       use_energy=False, energy_floor=0.0, snip_edges=True)

def vad(feats, floor_pct=10, top_pct=95, thresh_frac=0.45, min_speech=0.20, min_sil=0.20):
    """Frame-level speech mask from the fbank's own log-energy proxy."""
    e = feats.sum(dim=1).numpy()                     # sum of log-mel ~ log energy
    lo, hi = np.percentile(e, floor_pct), np.percentile(e, top_pct)
    thr = lo + (hi - lo) * thresh_frac
    m = e > thr
    # median-ish smoothing: close short gaps, drop short bursts
    def runs(mask):
        out, i = [], 0
        while i < len(mask):
            j = i
            while j < len(mask) and mask[j] == mask[i]: j += 1
            out.append((mask[i], i, j)); i = j
        return out
    for val, a, b in runs(m.copy()):
        if val == False and (b - a) < min_sil * 100: m[a:b] = True
    for val, a, b in runs(m.copy()):
        if val == True and (b - a) < min_speech * 100: m[a:b] = False
    return m

def speech_regions(mask, pad=0.0):
    regs, i = [], 0
    while i < len(mask):
        if mask[i]:
            j = i
            while j < len(mask) and mask[j]: j += 1
            regs.append((i / 100.0, j / 100.0)); i = j
        else: i += 1
    return regs

def windows(regions, win_s=WIN_FRAMES / 100.0, hop_s=HOP_S, min_s=0.60):
    out = []
    for a, b in regions:
        if b - a < min_s: continue
        if b - a <= win_s:
            out.append((a, b)); continue
        t = a
        while t + win_s <= b + 1e-6:
            out.append((t, t + win_s)); t += hop_s
        if b - (out[-1][1]) > hop_s * 0.5:      # tail
            out.append((max(a, b - win_s), b))
    return out

def embed_all(feats, wins, model, cmn="window", global_mean=None):
    xs = []
    for a, b in wins:
        i, j = int(round(a * 100)), int(round(b * 100))
        f = feats[i:j]
        if f.shape[0] < WIN_FRAMES:                   # pad by tiling
            reps = int(np.ceil(WIN_FRAMES / max(f.shape[0], 1)))
            f = f.repeat(reps, 1)[:WIN_FRAMES]
        f = f[:WIN_FRAMES]
        f = f - (f.mean(dim=0, keepdim=True) if cmn == "window" else global_mean)
        xs.append(f)
    x = torch.stack(xs)
    with torch.no_grad():
        embs = model(x)[-1].numpy()
    return embs / np.linalg.norm(embs, axis=1, keepdims=True)

def ahc(embs, threshold):
    """Average-linkage agglomerative clustering on cosine distance. Returns labels."""
    n = len(embs)
    sim = embs @ embs.T
    dist = 1.0 - sim
    clusters = {i: [i] for i in range(n)}
    # pairwise average distance, maintained by recomputation (n is small)
    while len(clusters) > 1:
        keys = list(clusters)
        best, bi, bj = None, None, None
        for ii in range(len(keys)):
            for jj in range(ii + 1, len(keys)):
                a, b = clusters[keys[ii]], clusters[keys[jj]]
                d = dist[np.ix_(a, b)].mean()
                if best is None or d < best: best, bi, bj = d, keys[ii], keys[jj]
        if best > threshold: break
        clusters[bi] += clusters[bj]; del clusters[bj]
    labels = np.zeros(n, dtype=int)
    for k, (key, idxs) in enumerate(sorted(clusters.items(), key=lambda kv: min(kv[1]))):
        for i in idxs: labels[i] = k
    return labels

def assign(segments, wins, labels, nclusters):
    """Majority label over the windows overlapping each transcript segment."""
    out = []
    for s in segments:
        votes = np.zeros(nclusters)
        for (a, b), l in zip(wins, labels):
            ov = min(s["end"], b) - max(s["start"], a)
            if ov > 0: votes[l] += ov
        out.append(int(votes.argmax()) if votes.sum() > 0 else -1)
    return out
