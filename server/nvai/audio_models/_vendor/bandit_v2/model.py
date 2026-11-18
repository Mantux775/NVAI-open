# Bandit v2 (Watcharasupat, Wu, Orife: „Remastering Divide and Remaster“, arXiv 2407.07275), nur Inferenz.
# Quelle: github.com/kwatcharasupat/bandit-v2, Commit d5563d9031e95fdaa3e5a73d5020b9a0df61adb6 (29.07.2025),
# Dateien src/models/bandit/{bandit,bandsplit,maskestim,tfmodel,utils}.py; Lizenz Apache-2.0 (LICENSE daneben).
# Geändert: ohne Lightning, torchaudio, librosa und Checkpointing (STFT direkt über torch.stft mit derselben
# Normierung wie torchaudio, MIDI-Umrechnung als Formel wie librosa); Maske vor view_as_complex in fp32 (Autocast).
# Namen der Module und Puffer wie im Original, damit der state_dict der Checkpoints strikt passt.
from typing import Dict, List, Optional, Tuple

import numpy as np
import torch
from torch import nn


# ------------------------------------------------------------------------------------------ Bänder (utils.py)

def _hz_to_midi(f):
    return 12 * (np.log2(np.asanyarray(f)) - np.log2(440.0)) + 69


def _midi_to_hz(m):
    return 440.0 * (2.0 ** ((np.asanyarray(m) - 69.0) / 12.0))


def musical_filterbank(n_bands, fs, f_min, f_max, n_freqs):
    nfft = 2 * (n_freqs - 1)
    df = fs / nfft
    f_max = f_max or fs / 2
    f_min = fs / nfft

    n_octaves = np.log2(f_max / f_min)
    bandwidth_mult = np.power(2.0, n_octaves / n_bands)

    low_midi = max(0, _hz_to_midi(f_min))
    high_midi = _hz_to_midi(f_max)
    hz_pts = _midi_to_hz(np.linspace(low_midi, high_midi, n_bands))

    low_bins = np.floor(hz_pts / bandwidth_mult / df).astype(int)
    high_bins = np.ceil(hz_pts * bandwidth_mult / df).astype(int)

    fb = np.zeros((n_bands, n_freqs))
    for i in range(n_bands):
        fb[i, low_bins[i]: high_bins[i] + 1] = 1.0
    fb[0, : low_bins[0]] = 1.0
    fb[-1, high_bins[-1] + 1:] = 1.0
    return torch.as_tensor(fb)


class MusicalBandsplitSpecification:
    def __init__(self, nfft: int, fs: int, n_bands: int) -> None:
        max_index = nfft // 2 + 1
        filterbank = musical_filterbank(n_bands, fs, 0.0, fs / 2, max_index)
        normalized = filterbank / torch.sum(filterbank, dim=0, keepdim=True)
        self.band_specs: List[Tuple[int, int]] = []
        self.freq_weights: List[torch.Tensor] = []
        for i in range(n_bands):
            active = torch.nonzero(filterbank[i, :]).squeeze().tolist()
            if isinstance(active, int):
                active = (active, active)
            if len(active) == 0:
                continue
            start, end = active[0], active[-1] + 1
            self.band_specs.append((start, end))
            self.freq_weights.append(normalized[i, start:end])

    def get_band_specs(self):
        return self.band_specs

    def get_freq_weights(self):
        return self.freq_weights


# ------------------------------------------------------------------------------------------ STFT (wie torchaudio)

class Spectrogram(nn.Module):
    """torchaudio.transforms.Spectrogram(power=None, normalized=True): komplexes STFT / sqrt(sum(window²))."""

    def __init__(self, n_fft: int, win_length: int, hop_length: int, pad_mode: str, center: bool) -> None:
        super().__init__()
        self.n_fft, self.win_length, self.hop_length = n_fft, win_length, hop_length
        self.pad_mode, self.center = pad_mode, center
        self.register_buffer("window", torch.hann_window(win_length))

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        shape = x.shape
        x = x.reshape(-1, shape[-1])
        s = torch.stft(x, self.n_fft, self.hop_length, self.win_length, self.window, center=self.center,
                       pad_mode=self.pad_mode, normalized=False, onesided=True, return_complex=True)
        s = s.reshape(shape[:-1] + s.shape[-2:])
        return s / self.window.pow(2.0).sum().sqrt()


class InverseSpectrogram(nn.Module):
    def __init__(self, n_fft: int, win_length: int, hop_length: int, center: bool) -> None:
        super().__init__()
        self.n_fft, self.win_length, self.hop_length, self.center = n_fft, win_length, hop_length, center
        self.register_buffer("window", torch.hann_window(win_length))

    def forward(self, s: torch.Tensor, length: int) -> torch.Tensor:
        s = s * self.window.pow(2.0).sum().sqrt()
        shape = s.shape
        s = s.reshape(-1, shape[-2], shape[-1])
        y = torch.istft(s, self.n_fft, self.hop_length, self.win_length, self.window, center=self.center,
                        normalized=False, onesided=True, length=length, return_complex=False)
        return y.reshape(shape[:-2] + y.shape[-1:])


# ------------------------------------------------------------------------------------------ bandsplit.py

class NormFC(nn.Module):
    def __init__(self, emb_dim: int, bandwidth: int, in_channels: int) -> None:
        super().__init__()
        self.combined = nn.Sequential(nn.LayerNorm(in_channels * bandwidth * 2),
                                      nn.Linear(bandwidth * 2 * in_channels, emb_dim))

    def forward(self, xb):
        return self.combined(xb)


class BandSplitModule(nn.Module):
    def __init__(self, band_specs: List[Tuple[int, int]], emb_dim: int, in_channels: int) -> None:
        super().__init__()
        self.band_specs = band_specs
        self.n_bands = len(band_specs)
        self.emb_dim = emb_dim
        self.norm_fc_modules = nn.ModuleList(
            [NormFC(emb_dim=emb_dim, bandwidth=e - s, in_channels=in_channels) for s, e in band_specs])

    def forward(self, x: torch.Tensor):
        # x: komplexes Spektrogramm (batch, in_chan, n_freq, n_time)
        batch, in_chan, _, n_time = x.shape
        z = torch.zeros(size=(batch, self.n_bands, n_time, self.emb_dim), device=x.device)
        x = torch.permute(x, (0, 3, 1, 2)).contiguous()
        for i, nfm in enumerate(self.norm_fc_modules):
            fstart, fend = self.band_specs[i]
            xb = torch.view_as_real(x[:, :, :, fstart:fend])
            xb = torch.reshape(xb, (batch, n_time, -1))
            z[:, i, :, :] = nfm(xb)
        return z


# ------------------------------------------------------------------------------------------ tfmodel.py

class ResidualRNN(nn.Module):
    def __init__(self, emb_dim: int, rnn_dim: int, bidirectional: bool = True, rnn_type: str = "GRU") -> None:
        super().__init__()
        self.norm = nn.LayerNorm(emb_dim)
        self.rnn = getattr(nn, rnn_type)(input_size=emb_dim, hidden_size=rnn_dim, num_layers=1, batch_first=True,
                                         bidirectional=bidirectional)
        self.fc = nn.Linear(in_features=rnn_dim * (2 if bidirectional else 1), out_features=emb_dim)

    def forward(self, z):
        # z: (batch, n_uncrossed, n_across, emb_dim)
        z0 = z
        z = self.norm(z)
        batch, n_uncrossed, n_across, emb_dim = z.shape
        z = torch.reshape(z, (batch * n_uncrossed, n_across, emb_dim))
        z = self.rnn(z)[0]
        z = torch.reshape(z, (batch, n_uncrossed, n_across, -1))
        return self.fc(z) + z0


class Transpose(nn.Module):
    def __init__(self, dim0: int, dim1: int) -> None:
        super().__init__()
        self.dim0, self.dim1 = dim0, dim1

    def forward(self, z):
        return z.transpose(self.dim0, self.dim1)


class SeqBandModellingModule(nn.Module):
    def __init__(self, n_modules: int, emb_dim: int, rnn_dim: int, bidirectional: bool, rnn_type: str) -> None:
        super().__init__()
        seqband: List[nn.Module] = []
        for _ in range(2 * n_modules):
            seqband += [ResidualRNN(emb_dim, rnn_dim, bidirectional, rnn_type), Transpose(1, 2)]
        self.seqband = nn.Sequential(*seqband)

    def forward(self, z):
        return self.seqband(z)  # (batch, n_bands, n_time, emb_dim)


# ------------------------------------------------------------------------------------------ maskestim.py

class NormMLP(nn.Module):
    def __init__(self, emb_dim: int, mlp_dim: int, bandwidth: int, in_channels: int,
                 hidden_activation: str = "Tanh", complex_mask: bool = True) -> None:
        super().__init__()
        self.norm = nn.LayerNorm(emb_dim)
        self.hidden = nn.Sequential(nn.Linear(emb_dim, mlp_dim), getattr(nn, hidden_activation)())
        self.bandwidth = bandwidth
        self.in_channels = in_channels
        self.complex_mask = complex_mask
        self.reim = 2 if complex_mask else 1
        self.output = nn.Sequential(nn.Linear(mlp_dim, bandwidth * in_channels * self.reim * 2), nn.GLU(dim=-1))
        # wie im Original: dieselben Module noch einmal als „combined“ (Schlüssel im Checkpoint)
        self.combined = nn.Sequential(self.norm, self.hidden, self.output)

    def forward(self, qb):
        mb = self.combined(qb)
        batch, n_time, _ = mb.shape
        if self.complex_mask:
            mb = mb.float().reshape(batch, n_time, self.in_channels, self.bandwidth, self.reim).contiguous()
            mb = torch.view_as_complex(mb)
        else:
            mb = mb.reshape(batch, n_time, self.in_channels, self.bandwidth)
        return torch.permute(mb, (0, 2, 3, 1))  # (batch, in_channels, bandwidth, n_time)


class OverlappingMaskEstimationModule(nn.Module):
    def __init__(self, in_channels: int, band_specs: List[Tuple[int, int]], freq_weights: List[torch.Tensor],
                 n_freq: int, emb_dim: int, mlp_dim: int, hidden_activation: str = "Tanh",
                 complex_mask: bool = True, use_freq_weights: bool = True) -> None:
        super().__init__()
        self.norm_mlp = nn.ModuleList([
            NormMLP(emb_dim=emb_dim, mlp_dim=mlp_dim, bandwidth=e - s, in_channels=in_channels,
                    hidden_activation=hidden_activation, complex_mask=complex_mask) for s, e in band_specs])
        self.n_freq = n_freq
        self.band_specs = band_specs
        self.in_channels = in_channels
        self.use_freq_weights = bool(freq_weights is not None and use_freq_weights)
        if self.use_freq_weights:
            for i, fw in enumerate(freq_weights):
                self.register_buffer(f"freq_weights/{i}", fw)

    def forward(self, q):
        # q: (batch, n_bands, n_time, emb_dim)
        batch, n_bands, n_time, _ = q.shape
        masks = torch.zeros((batch, self.in_channels, self.n_freq, n_time), device=q.device, dtype=torch.complex64)
        for im in range(n_bands):
            fstart, fend = self.band_specs[im]
            mask = self.norm_mlp[im](q[:, im, :, :])
            if self.use_freq_weights:
                mask = mask * self.get_buffer(f"freq_weights/{im}")[:, None]
            masks[:, :, fstart:fend, :] += mask
        return masks


# ------------------------------------------------------------------------------------------ bandit.py

class Bandit(nn.Module):
    """Bandit mit gemeinsamem Encoder und je einer Maske je Stem (Konfiguration bandit-mus64)."""

    def __init__(self, stems: List[str], in_channels: int = 1, fs: int = 48000, n_bands: int = 64,
                 n_sqm_modules: int = 8, emb_dim: int = 128, rnn_dim: int = 256, bidirectional: bool = True,
                 rnn_type: str = "GRU", mlp_dim: int = 512, hidden_activation: str = "Tanh",
                 complex_mask: bool = True, use_freq_weights: bool = True, n_fft: int = 2048,
                 win_length: int = 2048, hop_length: int = 512, center: bool = True,
                 pad_mode: str = "reflect") -> None:
        super().__init__()
        self.in_channels = in_channels
        self.stems = stems
        self.stft = Spectrogram(n_fft, win_length, hop_length, pad_mode, center)
        self.istft = InverseSpectrogram(n_fft, win_length, hop_length, center)
        self.band_specs = MusicalBandsplitSpecification(nfft=n_fft, fs=fs, n_bands=n_bands)
        self.band_split = BandSplitModule(band_specs=self.band_specs.get_band_specs(), emb_dim=emb_dim,
                                          in_channels=in_channels)
        self.tf_model = SeqBandModellingModule(n_sqm_modules, emb_dim, rnn_dim, bidirectional, rnn_type)
        self.mask_estim = nn.ModuleDict({
            stem: OverlappingMaskEstimationModule(
                band_specs=self.band_specs.get_band_specs(), freq_weights=self.band_specs.get_freq_weights(),
                n_freq=n_fft // 2 + 1, emb_dim=emb_dim, mlp_dim=mlp_dim, in_channels=in_channels,
                hidden_activation=hidden_activation, complex_mask=complex_mask, use_freq_weights=use_freq_weights)
            for stem in stems})

    def forward(self, audio: torch.Tensor, autocast_dtype: Optional[torch.dtype] = None) -> Dict[str, torch.Tensor]:
        """audio (batch, in_channels, Proben) float32 -> {stem: (batch, in_channels, Proben)}. STFT und iSTFT
        immer in fp32; mit autocast_dtype laufen Bandaufteilung, RNNs und Masken unter Autocast."""
        length = audio.shape[-1]
        x = self.stft(audio.float())
        with torch.autocast(device_type=audio.device.type, dtype=autocast_dtype or torch.bfloat16,
                            enabled=autocast_dtype is not None):
            q = self.tf_model(self.band_split(x))
            masks = {stem: mem(q) for stem, mem in self.mask_estim.items()}
        out = {}
        for stem, m in masks.items():
            s = torch.reshape(x * m.to(x.dtype), x.shape)
            out[stem] = self.istft(s, length)
        return out
