# Quelle: github.com/ZFTurbo/Music-Source-Separation-Training, models/bs_roformer/mel_band_roformer.py und attend.py,
# Commit 1f700c386e0dd763fe0a57242bb9420dce987354 (MIT, LICENSE). Ursprünglich lucidrains/BS-RoFormer
# (bs_roformer/mel_band_roformer.py, MIT, LICENSE.lucidrains).
# Auf Inferenz gekürzt: ohne Verlust, PoPE, lineare Attention, Checkpointing, Skip-Verbindungen und beartype.
# RotaryEmbedding nachgebaut wie rotary_embedding_torch 0.9 (theta 10000, verschränkte Paare), aber Positionen und
# Drehung immer in fp32 (das Original rechnet die Positionen unter bf16 in bf16, ab 256 ungenau).
# Mel-Bänder als feste Tabelle statt librosa: gleiche Bins wie librosa.filters.mel(44100, 2048, 60) mit den
# Korrekturen des Originals ([0][0] = 1, [-1][-1] = 1). Parameternamen wie im Original, Checkpoints laden strikt.
from __future__ import annotations

import torch
import torch.nn.functional as F
from torch import nn

# Bandgrenzen in STFT-Bins (n_fft 2048, 44,1 kHz, 60 Mel-Bänder): Band k umfasst Bins E[k] bis E[k + 2] - 1
MEL60_EDGES = (
    0, 4, 7, 10, 13, 16, 19, 22, 25, 28, 31, 34, 37, 40, 43, 46, 49, 53, 56, 60, 65, 69, 74, 79, 84, 90, 97, 103, 110,
    118, 126, 135, 145, 155, 165, 177, 189, 203, 217, 232, 248, 265, 284, 304, 325, 348, 372, 398, 426, 455, 487, 521,
    558, 597, 638, 683, 731, 782, 836, 895, 958, 1025,
)


class RMSNorm(nn.Module):
    def __init__(self, dim: int):
        super().__init__()
        self.scale = dim ** 0.5
        self.gamma = nn.Parameter(torch.ones(dim))

    def forward(self, x):
        return F.normalize(x, dim=-1) * (self.gamma * self.scale)


class RotaryEmbedding(nn.Module):
    """Drehung der Paare (2i, 2i+1) um pos * freqs[i]; als komplexe Multiplikation in einem Durchgang
    (gleiche Rechnung wie t * cos + rotate_half(t) * sin, drei statt zehn Speicherdurchgänge)."""

    def __init__(self, dim: int, theta: float = 10000.0):
        super().__init__()
        self.freqs = nn.Parameter(1.0 / (theta ** (torch.arange(0, dim, 2).float() / dim)), requires_grad=False)
        self._cache: tuple | None = None

    def rotate_queries_or_keys(self, t):
        n = t.shape[-2]
        c = self._cache
        if c is None or c[0] != n or c[1].device != t.device:
            pos = torch.arange(n, device=t.device, dtype=torch.float32)
            ang = torch.outer(pos, self.freqs.float())
            c = self._cache = (n, torch.complex(ang.cos(), ang.sin()))
        tc = torch.view_as_complex(t.float().contiguous().unflatten(-1, (-1, 2)))
        return torch.view_as_real(tc * c[1]).flatten(-2).to(t.dtype)


class FeedForward(nn.Module):
    def __init__(self, dim: int, mult: int = 4):
        super().__init__()
        inner = int(dim * mult)
        # Identity an den Stellen der Dropouts, damit die Schlüssel (net.1, net.4) passen
        self.net = nn.Sequential(RMSNorm(dim), nn.Linear(dim, inner), nn.GELU(), nn.Identity(),
                                 nn.Linear(inner, dim), nn.Identity())

    def forward(self, x):
        return self.net(x)


class Attention(nn.Module):
    def __init__(self, dim: int, heads: int = 8, dim_head: int = 64, rotary_embed: RotaryEmbedding | None = None):
        super().__init__()
        self.heads = heads
        inner = heads * dim_head
        self.rotary_embed = rotary_embed
        self.norm = RMSNorm(dim)
        self.to_qkv = nn.Linear(dim, inner * 3, bias=False)
        self.to_gates = nn.Linear(dim, heads)
        self.to_out = nn.Sequential(nn.Linear(inner, dim, bias=False))

    def forward(self, x):
        x = self.norm(x)
        b, n, _ = x.shape
        q, k, v = self.to_qkv(x).view(b, n, 3, self.heads, -1).permute(2, 0, 3, 1, 4)
        if self.rotary_embed is not None:
            q = self.rotary_embed.rotate_queries_or_keys(q)
            k = self.rotary_embed.rotate_queries_or_keys(k)
        out = F.scaled_dot_product_attention(q, k, v)
        gates = self.to_gates(x).transpose(1, 2).unsqueeze(-1).sigmoid()
        out = (out * gates).transpose(1, 2).reshape(b, n, -1)
        return self.to_out(out)


class Transformer(nn.Module):
    def __init__(self, *, dim: int, depth: int, dim_head: int, heads: int, rotary_embed: RotaryEmbedding):
        super().__init__()
        self.layers = nn.ModuleList([
            nn.ModuleList([Attention(dim, heads, dim_head, rotary_embed), FeedForward(dim)]) for _ in range(depth)
        ])
        self.norm = RMSNorm(dim)

    def forward(self, x):
        for attn, ff in self.layers:
            x = attn(x) + x
            x = ff(x) + x
        return self.norm(x)


class BandSplit(nn.Module):
    def __init__(self, dim: int, dim_inputs: tuple[int, ...]):
        super().__init__()
        self.dim_inputs = dim_inputs
        self.to_features = nn.ModuleList([nn.Sequential(RMSNorm(d), nn.Linear(d, dim)) for d in dim_inputs])

    def forward(self, x):
        parts = x.split(self.dim_inputs, dim=-1)
        return torch.stack([f(p) for p, f in zip(parts, self.to_features)], dim=-2)


def _mlp(dim_in: int, dim_out: int, dim_hidden: int, depth: int) -> nn.Sequential:
    dims = (dim_in, *((dim_hidden,) * depth), dim_out)
    net: list[nn.Module] = []
    for i, (a, b) in enumerate(zip(dims[:-1], dims[1:])):
        net.append(nn.Linear(a, b))
        if i < len(dims) - 2:
            net.append(nn.Tanh())
    return nn.Sequential(*net)


class MaskEstimator(nn.Module):
    def __init__(self, dim: int, dim_inputs: tuple[int, ...], depth: int, mlp_expansion_factor: int = 4):
        super().__init__()
        hidden = dim * mlp_expansion_factor
        self.to_freqs = nn.ModuleList([
            nn.Sequential(_mlp(dim, d * 2, hidden, depth), nn.GLU(dim=-1)) for d in dim_inputs
        ])

    def forward(self, x):
        return torch.cat([mlp(band) for band, mlp in zip(x.unbind(dim=-2), self.to_freqs)], dim=-1)


class MelBandRoformer(nn.Module):
    """Eingang (Batch, Kanäle, Proben) float32, Ausgang (Batch, Stems, Kanäle, Proben). STFT, Maskenmittelung und
    iSTFT immer in fp32; amp_dtype (torch.bfloat16/float16) gilt nur für Bandaufteilung, Transformer und Masken."""

    def __init__(self, dim: int, *, depth: int, stereo: bool = True, num_stems: int = 1,
                 time_transformer_depth: int = 1, freq_transformer_depth: int = 1, dim_head: int = 64,
                 heads: int = 8, band_edges: tuple[int, ...] = MEL60_EDGES, stft_n_fft: int = 2048,
                 stft_hop_length: int = 441, stft_win_length: int = 2048, mask_estimator_depth: int = 2,
                 mlp_expansion_factor: int = 4, zero_dc: bool = True):
        super().__init__()
        self.audio_channels = 2 if stereo else 1
        self.num_stems = num_stems
        self.zero_dc = zero_dc
        self.n_fft, self.hop, self.win = stft_n_fft, stft_hop_length, stft_win_length
        kw = dict(dim=dim, heads=heads, dim_head=dim_head)
        time_rot, freq_rot = RotaryEmbedding(dim_head), RotaryEmbedding(dim_head)
        self.layers = nn.ModuleList([
            nn.ModuleList([Transformer(depth=time_transformer_depth, rotary_embed=time_rot, **kw),
                           Transformer(depth=freq_transformer_depth, rotary_embed=freq_rot, **kw)])
            for _ in range(depth)
        ])
        n_freqs = stft_n_fft // 2 + 1
        bands = [torch.arange(band_edges[k], band_edges[k + 2]) for k in range(len(band_edges) - 2)]
        assert bands[-1][-1] == n_freqs - 1
        freq_indices = torch.cat(bands)
        bands_per_freq = torch.bincount(freq_indices, minlength=n_freqs)
        assert bool((bands_per_freq > 0).all())
        s = self.audio_channels
        if stereo:
            freq_indices = (freq_indices[:, None] * 2 + torch.arange(2)).reshape(-1)
        self.register_buffer("freq_indices", freq_indices, persistent=False)
        self.register_buffer("num_bands_per_freq", bands_per_freq.repeat_interleave(s).float(), persistent=False)
        self.register_buffer("window", torch.hann_window(stft_win_length), persistent=False)
        dim_inputs = tuple(2 * len(b) * s for b in bands)
        self.band_split = BandSplit(dim, dim_inputs)
        self.mask_estimators = nn.ModuleList([
            MaskEstimator(dim, dim_inputs, mask_estimator_depth, mlp_expansion_factor) for _ in range(num_stems)
        ])

    def forward(self, raw_audio, amp_dtype: torch.dtype | None = None):
        b, s, n = raw_audio.shape
        spec = torch.stft(raw_audio.reshape(b * s, n).float(), n_fft=self.n_fft, hop_length=self.hop,
                          win_length=self.win, window=self.window, normalized=False, return_complex=True)
        nf, nt = spec.shape[-2:]
        # (b s) f t -> b (f s) t c
        spec = torch.view_as_real(spec).reshape(b, s, nf, nt, 2).permute(0, 2, 1, 3, 4).reshape(b, nf * s, nt, 2)
        x = spec[:, self.freq_indices].permute(0, 2, 1, 3).reshape(b, nt, -1)
        dev = raw_audio.device.type
        with torch.autocast(device_type=dev, dtype=amp_dtype or torch.float32, enabled=amp_dtype is not None):
            x = self.band_split(x)
            nb, d = x.shape[-2:]
            for time_tr, freq_tr in self.layers:
                x = time_tr(x.transpose(1, 2).reshape(b * nb, nt, d))
                x = freq_tr(x.reshape(b, nb, nt, d).transpose(1, 2).reshape(b * nt, nb, d))
                x = x.reshape(b, nt, nb, d)
            masks = torch.stack([fn(x) for fn in self.mask_estimators], dim=1)
        ns = masks.shape[1]
        # b n t (f c) -> b n f t c, Mittel über überlappende Bänder in fp32
        masks = masks.float().reshape(b, ns, nt, -1, 2).permute(0, 1, 3, 2, 4)
        summed = torch.zeros(b, ns, nf * s, nt, 2, device=masks.device, dtype=torch.float32)
        summed.index_add_(2, self.freq_indices, masks)
        summed = summed / self.num_bands_per_freq.clamp(min=1e-8)[:, None, None]
        out = torch.view_as_complex(spec.contiguous()).unsqueeze(1) * torch.view_as_complex(summed.contiguous())
        # b n (f s) t -> (b n s) f t
        out = out.reshape(b, ns, nf, s, nt).permute(0, 1, 3, 2, 4).reshape(b * ns * s, nf, nt)
        if self.zero_dc:
            out[:, 0] = 0
        y = torch.istft(out, n_fft=self.n_fft, hop_length=self.hop, win_length=self.win, window=self.window,
                        normalized=False, length=n)
        return y.reshape(b, ns, s, n)
