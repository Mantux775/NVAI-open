"""MossFormer2_SE_48K (ClearerVoice-Studio, Apache-2.0): Sprache entrauschen, 48 kHz.

Rechenweg wie ClearVoice (utils/decode.py, decode_one_audio_mossformer2_se_48k): Probe × 32768, Kaldi-Filterbank
60 + Deltas -> Netz -> Maske (ReLU) auf das STFT-Spektrum (Hamming 1920/384), ISTFT. Lange Eingaben in Stücken zu
4 s mit 3 s Schritt; ClearVoice schneidet hart in der Mitte jeder Überlappung, hier eine lineare Blende um genau
diese Stelle (fade_seconds, 0 = harter Schnitt wie ClearVoice; benachbarte Stücke weichen dort nur 24 dB unter dem
Signal voneinander ab, der harte Schnitt wäre ein Sprung). Abweichungen von ClearVoice, damit das Ergebnis nicht davon
abhängt, wo die Maschine schneidet: auch unter 20 s in Stücken, und statt Nullen am Ende ein rechtsbündiges letztes
Stück (Nullen im Stück ließen in leisen Stellen 10-18 dB mehr Rest durch). Fenster der Maschine 31 s mit 4 s
Überlappung: Schritt 27 s = 9 Stücke, so liegen die Stücke jedes Fensters auf demselben Raster wie bei einem einzigen
Durchlauf, das letzte Stück eines Fensters ist das erste des nächsten. Das Netz ist mono: jeder Kanal einzeln.

params: precision fp32|bf16 (fp16 läuft über: NaN), tf32 (Vorgabe an, 70 dB zu reinem fp32), fade_seconds (0,5),
dither (1,0 wie ClearVoice; Zufall mit festem seed, damit Fortsetzen dasselbe rechnet), batch (Stücke je Durchlauf;
20 = ein Maschinenfenster Stereo auf einmal, ~0,9 GB).
"""
from __future__ import annotations

import contextlib
from pathlib import Path
from typing import Any

import numpy as np

SAMPLE_RATE = 48000
CHANNELS = 2
STEMS = ["clean"]
CHUNK_SECONDS = 31.0         # 4 + 9 × 3: Fensterschritt 27 s liegt auf dem 3-s-Raster der Stücke
OVERLAP_SECONDS = 4.0

WEIGHTS = "last_best_checkpoint.pt"
WIN_LEN, WIN_INC, NUM_MELS = 1920, 384, 60
DECODE_WINDOW = 4.0          # Sekunden je Stück (ClearVoice decode_window), Schritt 0,75 davon
MAX_WAV_VALUE = 32768.0
_DTYPES = {"bf16": "bfloat16"}  # fp16 gab NaN (Überlauf im Netz), daher nicht angeboten


@contextlib.contextmanager
def _tf32(enabled: bool):
    """TF32 nur, wenn gewollt (die Maschine schaltet es global an); Merkmale immer in vollem fp32."""
    import torch
    old = (torch.backends.cuda.matmul.allow_tf32, torch.backends.cudnn.allow_tf32)
    torch.backends.cuda.matmul.allow_tf32 = torch.backends.cudnn.allow_tf32 = enabled
    try:
        yield
    finally:
        torch.backends.cuda.matmul.allow_tf32, torch.backends.cudnn.allow_tf32 = old


def load(weights_dir: Path, device: str, params: dict[str, Any]) -> dict[str, Any]:
    import torch
    from ._vendor.mossformer2_se48k.net import MossFormer2SE48K
    net = MossFormer2SE48K()
    sd = torch.load(Path(weights_dir) / WEIGHTS, map_location="cpu", weights_only=True)
    if "model" in sd:
        sd = sd["model"]
    net.load_state_dict(sd, strict=True)
    net.eval().to(device)
    return {"net": net, "device": torch.device(device)}


def _enhance(model: dict[str, Any], seg: Any, params: dict[str, Any], gen: Any) -> Any:
    """Stücke (B, Proben) im 16-Bit-Maßstab -> entrauschte Stücke gleicher Länge."""
    import torch
    from ._vendor.mossformer2_se48k import features
    dev = seg.device
    with _tf32(False):
        fb = features.fbank(seg, SAMPLE_RATE, WIN_LEN / SAMPLE_RATE * 1000, WIN_INC / SAMPLE_RATE * 1000, NUM_MELS,
                            dither=float(params.get("dither", 1.0)), generator=gen)
        d1 = features.deltas(fb.transpose(1, 2))
        d2 = features.deltas(d1)
        feats = torch.cat([fb, d1.transpose(1, 2), d2.transpose(1, 2)], dim=2)
    prec = str(params.get("precision", "fp32"))
    with _tf32(bool(params.get("tf32", True))), \
            torch.autocast(device_type=dev.type, dtype=torch.bfloat16, enabled=prec in _DTYPES):
        mask = model["net"](feats)
    mask = mask.float().transpose(1, 2)
    window = torch.hamming_window(WIN_LEN, periodic=False, device=dev)
    spec = torch.stft(seg, WIN_LEN, WIN_INC, WIN_LEN, window=window, center=False, return_complex=True)
    return torch.istft(spec * mask, WIN_LEN, WIN_INC, WIN_LEN, window=window, center=False, length=seg.shape[-1])


def process(model: dict[str, Any], audio: np.ndarray, params: dict[str, Any]) -> dict[str, np.ndarray]:
    import torch
    import torch.nn.functional as F
    dev = model["device"]
    win = int(SAMPLE_RATE * DECODE_WINDOW)
    stride = int(win * 0.75)
    fade = int(round(float(params.get("fade_seconds", 0.5)) * SAMPLE_RATE))
    fade = max(0, min(fade, win - stride))             # höchstens die Überlappung (ClearVoice: 2 × give_up)
    fade -= fade % 2
    n, ch = audio.shape
    if n <= win:
        starts, total = [0], win                       # kurzer Rest: mit Nullen auf ein Stück (wie ClearVoice)
    else:
        starts, total = list(range(0, n - win + 1, stride)), n
        if starts[-1] + win < n:
            starts.append(n - win)                     # rechtsbündig statt Nullen
    x = torch.from_numpy(np.ascontiguousarray(audio.T, dtype=np.float32)).to(dev) * MAX_WAV_VALUE
    x = F.pad(x, (0, total - n))
    segs = torch.stack([x[:, s:s + win] for s in starts], dim=1).reshape(ch * len(starts), win)
    gen = torch.Generator(device=dev)
    gen.manual_seed(int(params.get("seed", 0)))
    batch = max(1, int(params.get("batch", 20)))
    out = torch.empty_like(segs)
    for i in range(0, len(segs), batch):
        out[i:i + batch] = _enhance(model, segs[i:i + batch], params, gen)
    out = out.reshape(ch, len(starts), win)
    # zusammensetzen in fp32: Schnitt in der Mitte jeder Überlappung (bei 3 s Schritt 0,5 s vor Stückende, wie
    # ClearVoice), darum die Blende; die Gewichte ergänzen sich zu 1
    ramp = (torch.arange(fade, device=dev, dtype=torch.float32) + 0.5) / fade if fade else None
    y = torch.zeros(ch, total, device=dev, dtype=torch.float32)
    for k, s in enumerate(starts):
        w = torch.ones(win, device=dev, dtype=torch.float32)
        if k > 0:
            a = (starts[k - 1] + win + s) // 2 - s - fade // 2
            w[:a] = 0
            if fade:
                w[a:a + fade] = ramp
        if k < len(starts) - 1:
            b = (s + win + starts[k + 1]) // 2 - s - fade // 2
            if fade:
                w[b:b + fade] = 1 - ramp
            w[b + fade:] = 0
        y[:, s:s + win] += out[:, k] * w
    clean = (y[:, :n] / MAX_WAV_VALUE).T.contiguous().cpu().numpy().astype(np.float32)
    return {"clean": clean}
