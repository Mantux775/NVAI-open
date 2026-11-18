"""Kaldi-Filterbank und Deltas wie in torchaudio, ohne torchaudio, stapelweise (B, Proben).

Quelle: github.com/pytorch/audio, src/torchaudio/compliance/kaldi.py (fbank, _get_window, get_mel_banks) und
src/torchaudio/functional/functional.py (compute_deltas), Version 2.8.0, BSD-2-Clause (LICENSE.torchaudio daneben).
Nur der Zweig, den ClearVoice für MossFormer2_SE_48K nutzt: Hamming, snip_edges, Gleichanteil weg, Vorbetonung
0,97, Leistungsspektrum, log, keine Energie-Spalte, kein VTLN.
"""
import math

import torch
import torch.nn.functional as F

_EPS = torch.finfo(torch.float).eps


def mel_banks(num_bins: int, padded: int, sr: float, low_freq: float = 20.0, high_freq: float = 0.0) -> torch.Tensor:
    """Dreiecksfilter (num_bins, padded // 2 + 1), Rechenweg wie get_mel_banks."""
    num_fft_bins = padded / 2
    nyquist = 0.5 * sr
    if high_freq <= 0.0:
        high_freq += nyquist
    fft_bin_width = sr / padded
    mel_low = 1127.0 * math.log(1.0 + low_freq / 700.0)
    mel_high = 1127.0 * math.log(1.0 + high_freq / 700.0)
    delta = (mel_high - mel_low) / (num_bins + 1)
    b = torch.arange(num_bins).unsqueeze(1)
    left = mel_low + b * delta
    center = mel_low + (b + 1.0) * delta
    right = mel_low + (b + 2.0) * delta
    mel = (1127.0 * (1.0 + (fft_bin_width * torch.arange(num_fft_bins)) / 700.0).log()).unsqueeze(0)
    up = (mel - left) / (center - left)
    down = (right - mel) / (right - center)
    bins = torch.max(torch.zeros(1), torch.min(up, down))
    return F.pad(bins, (0, 1), mode="constant", value=0)


def fbank(wave: torch.Tensor, sr: int, frame_length_ms: float, frame_shift_ms: float, num_mel_bins: int,
          dither: float = 1.0, generator: torch.Generator | None = None) -> torch.Tensor:
    """(B, Proben) -> log-Mel (B, Bilder, num_mel_bins), wie kaldi.fbank(window_type='hamming')."""
    shift = int(sr * frame_shift_ms * 0.001)
    size = int(sr * frame_length_ms * 0.001)
    padded = 1 if size == 0 else 2 ** (size - 1).bit_length()
    frames = wave.unfold(-1, size, shift)  # wie as_strided bei snip_edges
    if dither != 0.0:
        frames = frames + torch.randn(frames.shape, generator=generator, device=wave.device, dtype=wave.dtype) * dither
    frames = frames - frames.mean(dim=-1, keepdim=True)
    prev = F.pad(frames, (1, 0), mode="replicate")[..., :-1]
    frames = frames - 0.97 * prev
    win = torch.hamming_window(size, periodic=False, alpha=0.54, beta=0.46, device=wave.device, dtype=wave.dtype)
    frames = F.pad(frames * win, (0, padded - size), mode="constant", value=0)
    spec = torch.fft.rfft(frames).abs().pow(2.0)
    banks = mel_banks(num_mel_bins, padded, sr).to(device=wave.device, dtype=wave.dtype)
    energies = torch.matmul(spec, banks.T)
    return torch.max(energies, torch.tensor(_EPS, device=wave.device, dtype=wave.dtype)).log()


def deltas(x: torch.Tensor) -> torch.Tensor:
    """compute_deltas(win_length=5, mode='replicate') entlang der letzten Achse (Zeit)."""
    p = F.pad(x.reshape(1, -1, x.shape[-1]), (2, 2), mode="replicate").reshape(*x.shape[:-1], x.shape[-1] + 4)
    t = x.shape[-1]
    return (-2.0 * p[..., 0:t] - p[..., 1:t + 1] + p[..., 3:t + 3] + 2.0 * p[..., 4:t + 4]) / 10.0
