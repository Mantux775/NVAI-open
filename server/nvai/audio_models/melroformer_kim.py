"""Kim Mel-Band RoFormer: Stimme von allem anderen trennen (Gesang und Sprache, 44,1 kHz Stereo). Gewichte
KimberleyJSN/melbandroformer (MIT), Code MIT (_vendor/melroformer_kim). Das Netz ist auf 8-s-Stücke trainiert:
Innerhalb des Fensters der Abschnitts-Maschine läuft die Trennung wie im Original (MSST demix) in 8-s-Stücken mit
Überlappung (Parameter overlap, 2–4), linearen Blenden und fp32-Summen. Den Rest liefert die Maschine als Mischung
minus Stimme."""
from __future__ import annotations

from pathlib import Path
from typing import Any

import numpy as np

SAMPLE_RATE = 44100
CHANNELS = 2
STEMS = ["voice"]
CHUNK_SECONDS = 60.0
OVERLAP_SECONDS = 4.0

MODEL_CHUNK = 352800       # 8 s, chunk_size aus config_vocals_mel_band_roformer.yaml
OVERLAP = 2                # num_overlap des Originals; 4 änderte am Testclip kaum etwas (43 dB) und dauert doppelt
BATCH = 2                  # Stücke je Durchgang (2,2 GB; 4 kaum schneller, 3,5 GB)
PRECISION = "fp16"         # Transformer auf der GPU, wie Kims Original (gemessen 74 dB SNR zu fp32, bf16 55 dB,
                           # läuft auch auf RTX 20); STFT/iSTFT und Summen bleiben fp32, CPU rechnet fp32

# Kims Konfiguration (configs/config_vocals_mel_band_roformer.yaml)
CONFIG = dict(dim=384, depth=6, stereo=True, num_stems=1, time_transformer_depth=1, freq_transformer_depth=1,
              dim_head=64, heads=8, stft_n_fft=2048, stft_hop_length=441, stft_win_length=2048,
              mask_estimator_depth=2)


def load(weights_dir: Path, device: str, params: dict[str, Any]) -> Any:
    import torch
    from ._vendor.melroformer_kim.mel_band_roformer import MelBandRoformer

    path = Path(weights_dir) / "MelBandRoformer.ckpt"
    if not path.exists():
        raise SystemExit(f"Mel-Band RoFormer: keine Gewichte in {weights_dir}")
    net = MelBandRoformer(**CONFIG)
    sd = torch.load(str(path), map_location="cpu", weights_only=True)
    sd = sd.get("state_dict", sd)
    net.load_state_dict(sd, strict=True)
    return net.eval().to(device)


def process(model: Any, audio: np.ndarray, params: dict[str, Any]) -> dict[str, np.ndarray]:
    import torch
    import torch.nn.functional as F

    dev = next(model.parameters()).device
    overlap = min(4, max(2, int(params.get("overlap") or OVERLAP)))
    batch = max(1, int(params.get("batch_size") or BATCH))
    prec = str(params.get("precision") or PRECISION)
    amp = {"bf16": torch.bfloat16, "fp16": torch.float16}.get(prec) if dev.type == "cuda" else None

    C = MODEL_CHUNK
    step = C // overlap
    fade = C // 10
    border = C - step
    mix = torch.from_numpy(np.ascontiguousarray(audio.T, dtype=np.float32)).to(dev)
    n = mix.shape[-1]
    padded = n > 2 * border
    if padded:  # Ränder gespiegelt verlängern, wie im Original
        mix = F.pad(mix[None], (border, border), mode="reflect")[0]
    total = mix.shape[-1]

    win = torch.ones(C, device=dev)
    win[:fade] = torch.linspace(0, 1, fade, device=dev)
    win[-fade:] = torch.linspace(1, 0, fade, device=dev)
    acc = torch.zeros(CHANNELS, total, device=dev, dtype=torch.float32)
    cnt = torch.zeros(1, total, device=dev, dtype=torch.float32)
    starts = list(range(0, total, step))
    for b0 in range(0, len(starts), batch):
        group = starts[b0:b0 + batch]
        parts = []
        for i in group:
            part = mix[:, i:i + C]
            L = part.shape[-1]
            if L < C:
                mode = "reflect" if L > C // 2 + 1 else "constant"
                part = F.pad(part[None], (0, C - L), mode=mode)[0]
            parts.append(part)
        xb = torch.stack(parts)
        y = model(xb, amp)[:, 0].float()   # (B, Kanäle, C)
        if amp is not None and not bool(torch.isfinite(y).all()):
            y = model(xb, None)[:, 0]      # Überlauf in halber Genauigkeit: dieses Stück in fp32
        for j, i in enumerate(group):
            L = min(C, total - i)
            w = win
            if i == 0 or i + C >= total:
                w = win.clone()
                if i == 0:
                    w[:fade] = 1
                if i + C >= total:
                    w[-fade:] = 1
            acc[:, i:i + L] += y[j, :, :L] * w[:L]
            cnt[:, i:i + L] += w[:L]
    est = torch.where(cnt > 0, acc / cnt.clamp(min=1e-12), torch.zeros_like(acc))
    if padded:
        est = est[:, border:total - border]
    return {"voice": est.T.contiguous().cpu().numpy().astype(np.float32)}
