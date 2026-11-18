"""Bandit v2: Filmton in Sprache, Musik und Effekte trennen (DnR v3, 48 kHz). Code Apache-2.0
(_vendor/bandit_v2), Gewichte CC BY-SA 4.0 (Zenodo 12701995). Das Netz ist mono und auf 8-s-Stücke trainiert:
Jeder Kanal läuft einzeln (wie inference_handler.py im Original), innerhalb des Fensters der Abschnitts-Maschine
in 8-s-Stücken mit linearen Blenden (Parameter hop_seconds) und fp32-Summen."""
from __future__ import annotations

from pathlib import Path
from typing import Any

import numpy as np

SAMPLE_RATE = 48000
CHANNELS = 2               # Modell mono, jeder Kanal einzeln; gleiche Kanäle (Mono-Quelle) nur einmal
STEMS = ["speech", "music", "effects"]
CHUNK_SECONDS = 60.0
OVERLAP_SECONDS = 4.0

SEG_SECONDS = 8.0          # Stücklänge im Training und in der Auswertung des Papers
HOP_SECONDS = 2.0          # gemessen gegen Hop 1 (Paper): Sprache 43,7 dB, Musik 28,9 dB; Hop 4 halb so lang, 34,4/20,0 dB
BATCH = 8                  # Stücke je Durchgang (fp16: 3,9 GB; 4 → 2,1 GB, 40 % langsamer)
VARIANT = "multi"          # checkpoint-<variant>.ckpt; „deu“ (nur Deutsch) war am Testclip nicht besser
PRECISION = "fp16"         # Autocast nur im Netz, STFT fp32; gegen fp32: 69/61/55 dB (bf16 58/53/46 dB)

_CKPT_STEMS = ["speech", "music", "sfx"]
_TO_STEM = {"speech": "speech", "music": "music", "sfx": "effects"}


def _checkpoint(weights_dir: Path, variant: str) -> Path:
    p = weights_dir / f"checkpoint-{variant}.ckpt"
    if p.exists():
        return p
    found = sorted(weights_dir.glob("checkpoint-*.ckpt"))
    if not found:
        raise SystemExit(f"Bandit v2: keine Gewichte in {weights_dir}")
    return found[0]


def load(weights_dir: Path, device: str, params: dict[str, Any]) -> dict[str, Any]:
    import torch
    from ._vendor.bandit_v2.model import Bandit

    path = _checkpoint(Path(weights_dir), str(params.get("variant") or VARIANT))
    # Lightning-Checkpoint: nur Tensoren (weights_only), per mmap ohne die Optimierer-Zustände zu lesen
    ck = torch.load(str(path), map_location="cpu", weights_only=True, mmap=True)
    sd = {k[len("model."):]: v for k, v in ck["state_dict"].items() if k.startswith("model.")}
    net = Bandit(stems=_CKPT_STEMS)
    net.load_state_dict(sd, strict=True)
    net.to(device).eval()
    prec = str(params.get("precision") or PRECISION)
    dtype = {"fp16": torch.float16, "bf16": torch.bfloat16}.get(prec) if device == "cuda" else None
    return {"net": net, "device": device, "dtype": dtype, "checkpoint": path.name}


def _weights(seg: int, hop: int) -> np.ndarray:
    """Lineare Blenden über die Überlappung (höchstens halbe Stücklänge), nie ganz null."""
    fade = max(1, min(seg - hop, seg // 2))
    w = np.ones(seg, np.float32)
    ramp = (np.arange(fade, dtype=np.float32) + 0.5) / fade
    w[:fade] = ramp
    w[seg - fade:] = np.minimum(w[seg - fade:], ramp[::-1])
    return w


def process(model: dict[str, Any], audio: np.ndarray, params: dict[str, Any]) -> dict[str, np.ndarray]:
    import torch

    net, device, dtype = model["net"], model["device"], model["dtype"]
    sr = SAMPLE_RATE
    seg = int(round(float(params.get("seg_seconds") or SEG_SECONDS) * sr))
    hop = int(round(min(float(params.get("hop_seconds") or HOP_SECONDS), seg / sr) * sr))
    batch = max(1, int(params.get("batch_size") or BATCH))
    n, ch = audio.shape
    same = ch > 1 and np.array_equal(audio[:, 0], audio[:, 1])
    x = audio[:, :1] if same else audio
    c = x.shape[1]

    # Rand wie im Original spiegeln: vorn eine Überlappung, hinten bis zum letzten vollen Stück
    ov = seg - hop
    k = max(1, int(np.ceil((ov + n) / hop)))
    total = (k - 1) * hop + seg
    pad_mode = "reflect" if n > 1 else "constant"
    xp = np.pad(x, ((ov, total - ov - n), (0, 0)), mode=pad_mode).T.copy()  # (c, total)
    xt = torch.from_numpy(xp).to(device)
    w = torch.from_numpy(_weights(seg, hop)).to(device)
    acc = {s: torch.zeros((c, total), dtype=torch.float32, device=device) for s in _CKPT_STEMS}
    wsum = torch.zeros(total, dtype=torch.float32, device=device)
    jobs = [(i, j) for i in range(k) for j in range(c)]  # (Stück, Kanal)
    for b0 in range(0, len(jobs), batch):
        part = jobs[b0:b0 + batch]
        inp = torch.stack([xt[j, i * hop: i * hop + seg] for i, j in part])[:, None, :]
        out = net(inp, autocast_dtype=dtype)
        for s in _CKPT_STEMS:
            y = out[s][:, 0, :].float()
            for r, (i, j) in enumerate(part):
                acc[s][j, i * hop: i * hop + seg] += y[r] * w
    for i in range(k):
        wsum[i * hop: i * hop + seg] += w
    res = {}
    for s in _CKPT_STEMS:
        y = (acc[s] / wsum.clamp_min(1e-6))[:, ov: ov + n].T.cpu().numpy().astype(np.float32)
        res[_TO_STEM[s]] = np.repeat(y, ch, axis=1) if same else y
    return res
