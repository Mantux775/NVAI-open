"""MossFormer2_SE_48K (Netz), nur Inferenz.

Quelle: github.com/modelscope/ClearerVoice-Studio, clearvoice/clearvoice/models/mossformer2_se/ (mossformer2.py,
mossformer2_block.py, conv_module.py, fsmn.py, layer_norm.py, mossformer2_se_wrapper.py), Commit 6b3774dc79c4
(14.08.2025), Apache-2.0 (LICENSE daneben), Autoren Shengkui Zhao, Zexu Pan. Gekürzt auf den Weg, den
MossFormer2_SE_48K nutzt (nicht kausal, ohne Maske von außen); Rechnung und Namen der Gewichte unverändert.
Geändert: squeeze(1) statt squeeze() in UniDeepFsmn (gleiches Ergebnis, sicher bei jeder Stapelgröße).
rotary-embedding-torch 0.9.2 statt 0.8.3: für 3-D-Eingaben rechnerisch gleich, Gewicht „freqs“ gleich benannt.
"""
import torch
import torch.nn as nn
import torch.nn.functional as F
from einops import rearrange
from rotary_embedding_torch import RotaryEmbedding
from torch import einsum


def _padding_to_multiple_of(n, mult):
    r = n % mult
    return 0 if r == 0 else mult - r


# ------------------------------------------------------------------------------------------------ Bausteine

class ScaleNorm(nn.Module):
    def __init__(self, dim, eps=1e-5):
        super().__init__()
        self.scale = dim ** -0.5
        self.eps = eps
        self.g = nn.Parameter(torch.ones(1))

    def forward(self, x):
        norm = torch.norm(x, dim=-1, keepdim=True) * self.scale
        return x / norm.clamp(min=self.eps) * self.g


class ScaledSinuEmbedding(nn.Module):
    def __init__(self, dim):
        super().__init__()
        self.scale = nn.Parameter(torch.ones(1,))
        inv_freq = 1. / (10000 ** (torch.arange(0, dim, 2).float() / dim))
        self.register_buffer('inv_freq', inv_freq)

    def forward(self, x):
        n, device = x.shape[1], x.device
        t = torch.arange(n, device=device).type_as(self.inv_freq)
        sinu = einsum('i , j -> i j', t, self.inv_freq)
        emb = torch.cat((sinu.sin(), sinu.cos()), dim=-1)
        return emb * self.scale


class OffsetScale(nn.Module):
    def __init__(self, dim, heads=1):
        super().__init__()
        self.gamma = nn.Parameter(torch.ones(heads, dim))
        self.beta = nn.Parameter(torch.zeros(heads, dim))

    def forward(self, x):
        out = einsum('... d, h d -> ... h d', x, self.gamma) + self.beta
        return out.unbind(dim=-2)


class Transpose(nn.Module):
    def __init__(self, shape):
        super().__init__()
        self.shape = shape

    def forward(self, x):
        return x.transpose(*self.shape)


class DepthwiseConv1d(nn.Module):
    def __init__(self, in_channels, out_channels, kernel_size, stride=1, padding=0, bias=False):
        super().__init__()
        self.conv = nn.Conv1d(in_channels, out_channels, kernel_size, groups=in_channels, stride=stride,
                              padding=padding, bias=bias)

    def forward(self, x):
        return self.conv(x)


class ConvModule(nn.Module):
    def __init__(self, in_channels, kernel_size=17):
        super().__init__()
        self.sequential = nn.Sequential(
            Transpose(shape=(1, 2)),
            DepthwiseConv1d(in_channels, in_channels, kernel_size, stride=1, padding=(kernel_size - 1) // 2),
        )

    def forward(self, x):
        return x + self.sequential(x).transpose(1, 2)


class FFConvM(nn.Module):
    def __init__(self, dim_in, dim_out, norm_klass=nn.LayerNorm, dropout=0.1):
        super().__init__()
        self.mdl = nn.Sequential(norm_klass(dim_in), nn.Linear(dim_in, dim_out), nn.SiLU(), ConvModule(dim_out),
                                 nn.Dropout(dropout))

    def forward(self, x):
        return self.mdl(x)


class CLayerNorm(nn.LayerNorm):
    """LayerNorm über die Kanäle einer (B, C, T)-Eingabe."""

    def forward(self, sample):
        sample = torch.transpose(sample, 1, 2)
        sample = super().forward(sample)
        return torch.transpose(sample, 1, 2)


class UniDeepFsmn(nn.Module):
    def __init__(self, input_dim, output_dim, lorder, hidden_size):
        super().__init__()
        self.lorder = lorder
        self.linear = nn.Linear(input_dim, hidden_size)
        self.project = nn.Linear(hidden_size, output_dim, bias=False)
        self.conv1 = nn.Conv2d(output_dim, output_dim, [lorder + lorder - 1, 1], [1, 1], groups=output_dim,
                               bias=False)

    def forward(self, input):
        f1 = F.relu(self.linear(input))
        p1 = self.project(f1)
        x_per = torch.unsqueeze(p1, 1).permute(0, 3, 2, 1)
        y = F.pad(x_per, [0, 0, self.lorder - 1, self.lorder - 1])
        out = x_per + self.conv1(y)
        return input + out.permute(0, 3, 2, 1).squeeze(1)


# ------------------------------------------------------------------------------------------------ MossFormer2

class FLASH_ShareA_FFConvM(nn.Module):
    def __init__(self, *, dim, group_size=256, query_key_dim=128, expansion_factor=1., dropout=0.1,
                 rotary_pos_emb=None, norm_klass=nn.LayerNorm, shift_tokens=True):
        super().__init__()
        hidden_dim = int(dim * expansion_factor)
        self.group_size = group_size
        self.shift_tokens = shift_tokens
        self.rotary_pos_emb = rotary_pos_emb
        self.dropout = nn.Dropout(dropout)
        self.to_hidden = FFConvM(dim_in=dim, dim_out=hidden_dim, norm_klass=norm_klass, dropout=dropout)
        self.to_qk = FFConvM(dim_in=dim, dim_out=query_key_dim, norm_klass=norm_klass, dropout=dropout)
        self.qk_offset_scale = OffsetScale(query_key_dim, heads=4)
        self.to_out = FFConvM(dim_in=dim * 2, dim_out=dim, norm_klass=norm_klass, dropout=dropout)
        self.gateActivate = nn.Sigmoid()

    def forward(self, x):
        normed_x = x
        if self.shift_tokens:
            x_shift, x_pass = normed_x.chunk(2, dim=-1)
            x_shift = F.pad(x_shift, (0, 0, 1, -1), value=0.)
            normed_x = torch.cat((x_shift, x_pass), dim=-1)
        v, u = self.to_hidden(normed_x).chunk(2, dim=-1)
        qk = self.to_qk(normed_x)
        quad_q, lin_q, quad_k, lin_k = self.qk_offset_scale(qk)
        att_v, att_u = self.cal_attention(x, quad_q, lin_q, quad_k, lin_k, v, u)
        out = (att_u * v) * self.gateActivate(att_v * u)
        return x + self.to_out(out)

    def cal_attention(self, x, quad_q, lin_q, quad_k, lin_k, v, u):
        b, n, device, g = x.shape[0], x.shape[-2], x.device, self.group_size
        mask = None
        if self.rotary_pos_emb is not None:
            quad_q, lin_q, quad_k, lin_k = map(self.rotary_pos_emb.rotate_queries_or_keys,
                                               (quad_q, lin_q, quad_k, lin_k))
        padding = _padding_to_multiple_of(n, g)
        if padding > 0:
            quad_q, quad_k, lin_q, lin_k, v, u = map(lambda t: F.pad(t, (0, 0, 0, padding), value=0.),
                                                     (quad_q, quad_k, lin_q, lin_k, v, u))
            mask = torch.ones((b, n), device=device, dtype=torch.bool)
            mask = F.pad(mask, (0, padding), value=False)
        quad_q, quad_k, lin_q, lin_k, v, u = map(lambda t: rearrange(t, 'b (g n) d -> b g n d', n=g),
                                                 (quad_q, quad_k, lin_q, lin_k, v, u))
        if mask is not None:
            mask = rearrange(mask, 'b (g j) -> b g 1 j', j=g)
        # quadratische Aufmerksamkeit je Gruppe
        sim = einsum('... i d, ... j d -> ... i j', quad_q, quad_k) / g
        attn = F.relu(sim) ** 2
        attn = self.dropout(attn)
        if mask is not None:
            attn = attn.masked_fill(~mask, 0.)
        quad_out_v = einsum('... i j, ... j d -> ... i d', attn, v)
        quad_out_u = einsum('... i j, ... j d -> ... i d', attn, u)
        # lineare Aufmerksamkeit über die ganze Folge
        lin_kv = einsum('b g n d, b g n e -> b d e', lin_k, v) / n
        lin_out_v = einsum('b g n d, b d e -> b g n e', lin_q, lin_kv)
        lin_ku = einsum('b g n d, b g n e -> b d e', lin_k, u) / n
        lin_out_u = einsum('b g n d, b d e -> b g n e', lin_q, lin_ku)
        return map(lambda t: rearrange(t, 'b g n d -> b (g n) d')[:, :n],
                   (quad_out_v + lin_out_v, quad_out_u + lin_out_u))


class Gated_FSMN(nn.Module):
    def __init__(self, in_channels, out_channels, lorder, hidden_size):
        super().__init__()
        self.to_u = FFConvM(dim_in=in_channels, dim_out=hidden_size, norm_klass=nn.LayerNorm, dropout=0.1)
        self.to_v = FFConvM(dim_in=in_channels, dim_out=hidden_size, norm_klass=nn.LayerNorm, dropout=0.1)
        self.fsmn = UniDeepFsmn(in_channels, out_channels, lorder, hidden_size)

    def forward(self, x):
        x_u = self.fsmn(self.to_u(x))
        x_v = self.to_v(x)
        return x_v * x_u + x


class Gated_FSMN_Block(nn.Module):
    def __init__(self, dim, inner_channels=256):
        super().__init__()
        self.conv1 = nn.Sequential(nn.Conv1d(dim, inner_channels, kernel_size=1), nn.PReLU())
        self.norm1 = CLayerNorm(inner_channels)
        self.gated_fsmn = Gated_FSMN(inner_channels, inner_channels, lorder=20, hidden_size=inner_channels)
        self.norm2 = CLayerNorm(inner_channels)
        self.conv2 = nn.Conv1d(inner_channels, dim, kernel_size=1)

    def forward(self, input):
        conv1 = self.conv1(input.transpose(2, 1))
        norm1 = self.norm1(conv1)
        seq_out = self.gated_fsmn(norm1.transpose(2, 1))
        norm2 = self.norm2(seq_out.transpose(2, 1))
        conv2 = self.conv2(norm2)
        return conv2.transpose(2, 1) + input


class MossformerBlock_GFSMN(nn.Module):
    def __init__(self, *, dim, depth, group_size=256, query_key_dim=128, expansion_factor=4., attn_dropout=0.1):
        super().__init__()
        rotary_pos_emb = RotaryEmbedding(dim=min(32, query_key_dim))
        self.fsmn = nn.ModuleList([Gated_FSMN_Block(dim) for _ in range(depth)])
        self.layers = nn.ModuleList([
            FLASH_ShareA_FFConvM(dim=dim, group_size=group_size, query_key_dim=query_key_dim,
                                 expansion_factor=expansion_factor, dropout=attn_dropout,
                                 rotary_pos_emb=rotary_pos_emb, norm_klass=ScaleNorm, shift_tokens=True)
            for _ in range(depth)
        ])

    def forward(self, x):
        for flash, fsmn in zip(self.layers, self.fsmn):
            x = fsmn(flash(x))
        return x


class MossFormerM(nn.Module):
    def __init__(self, num_blocks, d_model):
        super().__init__()
        self.mossformerM = MossformerBlock_GFSMN(dim=d_model, depth=num_blocks)
        self.norm = nn.LayerNorm(d_model, eps=1e-6)

    def forward(self, src):
        return self.norm(self.mossformerM(src))


class Computation_Block(nn.Module):
    def __init__(self, num_blocks, out_channels):
        super().__init__()
        self.intra_mdl = MossFormerM(num_blocks=num_blocks, d_model=out_channels)
        self.intra_norm = nn.GroupNorm(1, out_channels, eps=1e-8)

    def forward(self, x):
        intra = x.permute(0, 2, 1).contiguous()
        intra = self.intra_mdl(intra)
        intra = intra.permute(0, 2, 1).contiguous()
        return self.intra_norm(intra) + x


class MossFormer_MaskNet(nn.Module):
    def __init__(self, in_channels, out_channels, out_channels_final, num_blocks=24, num_spks=2):
        super().__init__()
        self.num_spks = num_spks
        self.norm = nn.GroupNorm(1, in_channels, eps=1e-8)
        self.conv1d_encoder = nn.Conv1d(in_channels, out_channels, 1, bias=False)
        self.pos_enc = ScaledSinuEmbedding(out_channels)
        self.mdl = Computation_Block(num_blocks, out_channels)
        self.conv1d_out = nn.Conv1d(out_channels, out_channels * num_spks, kernel_size=1)
        self.conv1_decoder = nn.Conv1d(out_channels, out_channels_final, 1, bias=False)
        self.prelu = nn.PReLU()
        self.activation = nn.ReLU()
        self.output = nn.Sequential(nn.Conv1d(out_channels, out_channels, 1), nn.Tanh())
        self.output_gate = nn.Sequential(nn.Conv1d(out_channels, out_channels, 1), nn.Sigmoid())

    def forward(self, x):
        x = self.norm(x)
        x = self.conv1d_encoder(x)
        base = x
        emb = self.pos_enc(x.transpose(1, -1)).transpose(0, -1)
        x = base + emb
        x = self.mdl(x)
        x = self.prelu(x)
        x = self.conv1d_out(x)
        B, _, S = x.shape
        x = x.view(B * self.num_spks, -1, S)
        x = self.output(x) * self.output_gate(x)
        x = self.conv1_decoder(x)
        _, N, L = x.shape
        x = x.view(B, self.num_spks, N, L)
        x = self.activation(x)
        x = x.transpose(0, 1)
        return x[0].transpose(1, 2)


class MossFormer2SE48K(nn.Module):
    """Entspricht TestNet aus mossformer2_se_wrapper.py: Merkmale (B, Bilder, 180) -> Maske (B, Bilder, 961)."""

    def __init__(self):
        super().__init__()
        self.mossformer = MossFormer_MaskNet(in_channels=180, out_channels=512, out_channels_final=961)

    def forward(self, feats):
        return self.mossformer(feats.transpose(1, 2))
