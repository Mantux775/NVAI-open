# SPDX-License-Identifier: Apache-2.0
# Copied unchanged from https://github.com/fuyi25/MiniMax-H3-Tiny (comfyui/__init__.py, Apache License 2.0) for
# NVAI-open since 0.5.35, so the H3-Tiny few-step checkpoint runs with ComfyUI's native MiniMax H3 nodes. Only these
# comment lines were added.
"""ComfyUI nodes for the H3-Tiny few-step checkpoints.

Install: link or copy this folder to ``ComfyUI/custom_nodes/ComfyUI-MiniMax-H3-Tiny``. The full-step H3-Tiny checkpoints need
none of this; they load with the stock "Load Diffusion Model" node.

A few-step student predicts the average velocity over ``[t, r]``, where r is the next point of its step grid, and its
time embedding is ``emb(t) + emb_r(r - t)`` (``r_time_embedder``). ComfyUI's MiniMax H3 model only sees t, so:

* **H3-Tiny Few-Step Loader** builds the model with the interval embedder and the rank-8 AdaLN factors of the
  checkpoint (written by ``scripts/convert_comfyui.py``), and adds r to the time embedding at run time. r comes from
  the sampler's sigma schedule: video rows (and text) use the next sigma, audio rows the same point at the audio
  shift, conditioning rows ``r = t``.
* **H3-Tiny Few-Step Sigmas** gives the grid the students were trained on: ``linspace(1, 0, steps + 1)`` at the video
  shift 12. Use it with ``SamplerCustomAdvanced``, the ``euler`` sampler and ``BasicGuider`` (no CFG).
"""

from __future__ import annotations

import contextlib
import types

import torch
from torch import nn

import comfy.ldm.minimax.model as h3
import comfy.patcher_extension
import comfy.sd
import comfy.utils
import folder_paths

WRAPPER_KEY = "h3tiny_fewstep"
VIDEO_SHIFT = 12.0


class LowRankAdalnProj(nn.Module):
    """AdaLN projection through a rank bottleneck: ``linear_2(linear_1(silu(t_emb)))``."""

    def __init__(self, t_dim, hidden, expand, modalities, rank, apply_silu=True, dtype=None, device=None,
                 operations=None):
        super().__init__()
        self.expand, self.modalities, self.hidden, self.apply_silu = expand, modalities, hidden, apply_silu
        self.linear_1 = operations.Linear(t_dim, rank, bias=True, dtype=dtype, device=device)
        self.linear_2 = operations.Linear(rank, expand * hidden * modalities, bias=True, dtype=dtype, device=device)

    def forward(self, t_emb):
        x = self.linear_2(self.linear_1(nn.functional.silu(t_emb) if self.apply_silu else t_emb))
        x = x.view(x.shape[0] * self.modalities, self.expand * self.hidden)
        return x.chunk(self.expand, dim=-1)


@contextlib.contextmanager
def few_step_build(rank: int):
    """While building the model: low-rank AdaLN in the DiT blocks, and an interval time embedder."""
    stock_adaln, stock_init = h3.AdalnProj, h3.MiniMaxH3Model.__init__

    def adaln(t_dim, hidden, expand, modalities, **kwargs):
        if expand == 6:  # DiT blocks; the final layer keeps its dense projection
            return LowRankAdalnProj(t_dim, hidden, expand, modalities, rank, **kwargs)
        return stock_adaln(t_dim, hidden, expand, modalities, **kwargs)

    def init(self, *args, **kwargs):
        stock_init(self, *args, **kwargs)
        te = self.time_embedder
        self.r_time_embedder = h3.TimeEmbedder(te.freq_dim, te.proj_in.out_features, te.proj_out.out_features,
                                               dtype=torch.float32, device=kwargs.get("device"),
                                               operations=kwargs["operations"])

    h3.AdalnProj, h3.MiniMaxH3Model.__init__ = adaln, init
    try:
        yield
    finally:
        h3.AdalnProj, h3.MiniMaxH3Model.__init__ = stock_adaln, stock_init


def time_embedding(self, unique_t, device, dtype):
    """``emb(t) + emb_r(r - t)`` per distinct t; r from the endpoints staged by the wrapper (``r = t`` otherwise)."""
    endpoints = getattr(self, "_h3tiny_endpoints", {})
    t = torch.tensor(unique_t, dtype=torch.float32, device=device)
    r = torch.tensor([endpoints.get(v, v) for v in unique_t], dtype=torch.float32, device=device)
    return (self.time_embedder(t) + self.r_time_embedder(r - t)).to(dtype)


def stage_endpoints(executor, x, timestep, context, transformer_options, *args, **kwargs):
    """Diffusion-model wrapper: map this step's video / audio t to their endpoints r before the forward runs."""
    model = executor.class_obj
    sigmas = transformer_options.get("sample_sigmas")
    if sigmas is None:
        raise ValueError("H3-Tiny few-step needs the sampler's sigma schedule (use SamplerCustomAdvanced)")
    shift_v = float(transformer_options.get("minimax_h3_sigma_shift_video", model.sigma_shift_video))
    shift_a = float(transformer_options.get("minimax_h3_sigma_shift_audio", model.sigma_shift_audio))
    # the same arithmetic as MiniMaxH3Model._forward, so the t values match its keys exactly
    sigma_v = (timestep.flatten()[0] / 1000.0).float().clamp(min=1e-6)
    t_v = float(1.0 - sigma_v)
    t_a = float(1.0 - h3.time_shift_sigma(sigma_v, shift_v, shift_a))
    grid = sigmas.detach().float().cpu()
    i = int((grid - float(sigma_v)).abs().argmin())
    sigma_next = grid[min(i + 1, grid.numel() - 1)]
    r_v = float(1.0 - sigma_next)
    r_a = float(1.0 - h3.time_shift_sigma(sigma_next, shift_v, shift_a))

    stock_shift = h3.time_shift_sigma
    if t_a == t_v and r_a != r_v:
        # at sigma = 1 both streams sit at t = 0 with different endpoints; nudge audio so it gets its own row
        def nudged(sigma, from_shift, to_shift):
            return stock_shift(sigma, from_shift, to_shift) - 1e-6

        t_a = float(1.0 - nudged(sigma_v, shift_v, shift_a))  # the key _forward will compute
        h3.time_shift_sigma = nudged
    model._h3tiny_endpoints = {t_v: r_v, t_a: r_a}
    try:
        return executor(x, timestep, context, transformer_options, *args, **kwargs)
    finally:
        h3.time_shift_sigma = stock_shift


def load_few_step(path: str, model_options: dict | None = None):
    model_options = model_options or {}
    sd, metadata = comfy.utils.load_torch_file(path, return_metadata=True)
    if "r_time_embedder.proj_in.weight" not in sd:
        raise ValueError(f"{path} is not an H3-Tiny few-step checkpoint; load it with Load Diffusion Model")
    rank = sd["blocks.0.adaln_proj.linear_1.weight"].shape[0]
    with few_step_build(rank):
        model = comfy.sd.load_diffusion_model_state_dict(sd, model_options=model_options, metadata=metadata)
    if model is None:
        raise RuntimeError(f"could not load {path}")
    model.cached_patcher_init = (load_few_step, (path, model_options))
    diffusion_model = model.model.diffusion_model
    diffusion_model._time_embedding = types.MethodType(time_embedding, diffusion_model)
    model.add_wrapper_with_key(comfy.patcher_extension.WrappersMP.DIFFUSION_MODEL, WRAPPER_KEY, stage_endpoints)
    return model


class H3TinyFewStepLoader:
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"unet_name": (folder_paths.get_filename_list("diffusion_models"),)}}

    RETURN_TYPES = ("MODEL",)
    FUNCTION = "load"
    CATEGORY = "loaders/H3-Tiny"
    DESCRIPTION = "Load an H3-Tiny few-step checkpoint (minimax_h3_tiny_*_fewstep_*.safetensors)."

    def load(self, unet_name):
        return (load_few_step(folder_paths.get_full_path_or_raise("diffusion_models", unet_name)),)


class H3TinyFewStepSigmas:
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"steps": ("INT", {"default": 6, "min": 1, "max": 50,
                                               "tooltip": "Model evaluations; 6 by default, 4 or more work"})}}

    RETURN_TYPES = ("SIGMAS",)
    FUNCTION = "sigmas"
    CATEGORY = "sampling/H3-Tiny"
    DESCRIPTION = "The step grid of the H3-Tiny few-step students: linspace(1, 0, steps + 1) at shift 12."

    def sigmas(self, steps):
        grid = torch.linspace(1.0, 0.0, steps + 1, dtype=torch.float64)
        return ((VIDEO_SHIFT * grid / (1.0 + (VIDEO_SHIFT - 1.0) * grid)).to(torch.float32),)


NODE_CLASS_MAPPINGS = {"H3TinyFewStepLoader": H3TinyFewStepLoader, "H3TinyFewStepSigmas": H3TinyFewStepSigmas}
NODE_DISPLAY_NAME_MAPPINGS = {"H3TinyFewStepLoader": "H3-Tiny Few-Step Loader",
                              "H3TinyFewStepSigmas": "H3-Tiny Few-Step Sigmas"}
