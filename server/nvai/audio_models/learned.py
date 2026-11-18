"""Gelerntes Geräusch („Geräusch lernen“, seit 17.11.2026): ein kleines Masken-Netz, das der Nutzer in der App aus
markierten Beispielen trainiert (audio_tools.cmd_learn). Es dämpft nur das gelernte Geräusch: Die Maske wirkt auf das
Spektrum des Originals (beide Kanäle gleich), der Rest bleibt, wie er war. Eigener Code (MIT)."""
from __future__ import annotations

from pathlib import Path

import numpy as np

SAMPLE_RATE = 48000
CHANNELS = 2
STEMS = ["clean"]
CHUNK_SECONDS = 30.0
OVERLAP_SECONDS = 2.0
N_FFT = 1024
HOP = 256


def build(bins: int = N_FFT // 2 + 1, hidden: int = 256):
    import torch
    from torch import nn

    class MaskNet(nn.Module):
        def __init__(self) -> None:
            super().__init__()
            self.inp = nn.Sequential(nn.Linear(bins, hidden), nn.LayerNorm(hidden), nn.GELU())
            self.conv = nn.Conv1d(hidden, hidden, 5, padding=2)
            self.gru = nn.GRU(hidden, hidden, num_layers=2, batch_first=True, bidirectional=True)
            self.out = nn.Linear(2 * hidden, bins)

        def forward(self, mag: "torch.Tensor") -> "torch.Tensor":  # (B, T, F) Betrag -> Maske 0…1
            h = self.inp(torch.log1p(mag * 100.0))
            h = h + self.conv(h.transpose(1, 2)).transpose(1, 2)
            h, _ = self.gru(h)
            return torch.sigmoid(self.out(h))

    return MaskNet()


def load(weights_dir: Path, device: str, params: dict):
    import torch
    data = torch.load(params["profile"], map_location="cpu", weights_only=True)
    net = build(hidden=int(data["config"]["hidden"]))
    net.load_state_dict(data["state"], strict=True)
    return {"net": net.to(device).eval(), "device": device}


def process(model, audio: np.ndarray, params: dict) -> dict:
    import torch
    dev = model["device"]
    x = torch.from_numpy(np.ascontiguousarray(audio.T)).to(dev)  # (K, N)
    win = torch.hann_window(N_FFT, device=dev)
    spec = torch.stft(x, N_FFT, HOP, window=win, return_complex=True)  # (K, F, T)
    mono = spec.abs().mean(dim=0).T.unsqueeze(0)  # (1, T, F)
    mask = model["net"](mono)[0].T  # (F, T)
    strength = float(params.get("strength", 1.0))
    mask = 1.0 - strength * (1.0 - mask)
    y = torch.istft(spec * mask.unsqueeze(0), N_FFT, HOP, window=win, length=x.shape[1])
    return {"clean": y.T.float().cpu().numpy()}
