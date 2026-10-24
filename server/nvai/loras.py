"""LoRAs: erkennen, einem Modell zuordnen und in den ComfyUI-Graphen einhaengen.

Eine LoRA passt nur zu der Architektur (und Groesse), auf der sie trainiert ist. Welche das
ist, steht im safetensors-Kopf: an den Schluesselnamen (Wan "blocks.N.cross_attn", Qwen
"img_mlp", LTX-2 "attn1" ...) und an der Breite der ersten LoRA-Matrix (Wan 1.3B 1536,
5B 3072, 14B 5120). Die Dateiformate unterscheiden sich (kohya "lora_unet_...", Diffusers
"transformer.", ComfyUI "diffusion_model.", PEFT "base_model.model."); ComfyUI liest alle,
die Erkennung normalisiert sie deshalb nur.

Eingehaengt wird zentral: nach dem Bauen sucht apply() die Modell-Lader des Graphen
(UNETLoader, CheckpointLoaderSimple) und haengt hinter jeden eine Kette aus
LoraLoaderModelOnly. Damit gilt es fuer jeden Workflow, ohne die Builder anzufassen.
"""
from __future__ import annotations

import re
from typing import Any

from .i18n import t

# LoRA-Basis -> Anzeigename
BASES: dict[str, str] = {
    "sdxl": "SDXL (Pony, Illustrious, NoobAI, Juggernaut …)",
    "sd15": "Stable Diffusion 1.5",
    "qwenimage": "Qwen-Image",
    "zimage": "Z-Image",
    "flux1": "FLUX.1 / Chroma",
    "flux2": "FLUX.2 Klein",
    "wan-1.3b": "Wan 2.1 1.3B",
    "wan-5b": "Wan 2.2 TI2V 5B",
    "wan-14b": "Wan 14B (2.1, 2.2 A14B)",
    "ltx2": "LTX-2 / LTX-2.3",
    "ltxv": "LTX-Video 0.9",
}

# Welche LoRA-Basen ein Katalog-Workflow nimmt. Fehlt ein Workflow, nimmt er keine LoRAs.
WORKFLOW_BASES: dict[str, tuple[str, ...]] = {
    "sdxl": ("sdxl",),
    "qwen_image": ("qwenimage",),
    "qwen_image_lightning": ("qwenimage",),
    "zimage": ("zimage",),
    "flux": ("flux1",),
    "chroma": ("flux1",),
    "wan_t2v": ("wan-1.3b",),
    "wan22_ti2v": ("wan-5b",),
    "wan_i2v": ("wan-14b",),
    "wan22_i2v": ("wan-14b",),
    "ltx23": ("ltx2",),
    "ltx25": ("ltx2",),
    "ltxv_t2v": ("ltxv",),
}

# HF-Basismodell (Tag base_model:adapter:...) -> LoRA-Basis. Nur als Hinweis; entschieden
# wird am Dateikopf.
_HF_BASE_HINTS: list[tuple[str, str]] = [
    ("stable-diffusion-xl", "sdxl"), ("sdxl", "sdxl"), ("pony", "sdxl"), ("illustrious", "sdxl"),
    ("noobai", "sdxl"), ("stable-diffusion-v1-5", "sd15"), ("qwen-image", "qwenimage"),
    ("z-image", "zimage"), ("flux.1", "flux1"), ("chroma", "flux1"), ("flux.2-klein", "flux2"),
    ("wan2.1-t2v-1.3b", "wan-1.3b"), ("wan2.2-ti2v-5b", "wan-5b"), ("wan2.1", "wan-14b"),
    ("wan2.2", "wan-14b"), ("ltx-2", "ltx2"), ("ltx-video", "ltxv"),
]

_PREFIXES = ("base_model_model_", "model_diffusion_model_", "diffusion_model_", "transformer_",
             "lora_unet_", "unet_")


def hf_base_hint(base_model: str) -> str | None:
    low = base_model.lower()
    for needle, base in _HF_BASE_HINTS:
        if needle in low:
            return base
    return None


def _norm(key: str) -> str:
    k = re.sub(r"[.\-]", "_", key.lower())
    for p in _PREFIXES:
        # "transformer." ist das Diffusers-Praefix, "transformer_blocks" ein echter Name.
        if k.startswith(p) and not (p == "transformer_" and k.startswith("transformer_blocks")):
            return k[len(p):]
    return k


def _in_dim(header: dict[str, Any], pattern: str) -> int | None:
    """Eingangsbreite der ersten LoRA-Down-Matrix, deren Name auf pattern passt."""
    rx = re.compile(pattern)
    for key, meta in header.items():
        if key == "__metadata__" or not isinstance(meta, dict):
            continue
        n = _norm(key)
        if rx.search(n) and re.search(r"(lora_a|lora_down)_weight$", n):
            shape = meta.get("shape") or []
            if len(shape) >= 2:
                return int(shape[1])
    return None


def is_lora(keys: list[str]) -> bool:
    low = [k.lower() for k in keys]
    return any(".lora_a." in k or ".lora_b." in k or "lora_down" in k or "lora_up" in k
               or ".lora.down." in k or k.startswith("lora_unet_") or k.startswith("lora_te")
               for k in low)


def detect(header: dict[str, Any]) -> tuple[str | None, str]:
    """(LoRA-Basis oder None, Erklaerung) aus einem safetensors-Kopf."""
    keys = [k for k in header if k != "__metadata__"]
    if not is_lora(keys):
        return None, t("Keine LoRA.", "Not a LoRA.")
    norm = [_norm(k) for k in keys]
    joined = "\n".join(norm)

    def has(rx: str) -> bool:
        return re.search(rx, joined, re.M) is not None

    # SD-Familie: kohya-Namen oder Diffusers-UNet
    if any(k.lower().startswith(("lora_unet_", "lora_te")) for k in keys) or has(r"(^|_)(input|down)_blocks_"):
        if has(r"^lora_te2_|^te2_") or has(r"input_blocks_[78]_1_transformer_blocks_[1-9]"):
            return "sdxl", t("SDXL-LoRA", "SDXL LoRA")
        dim = _in_dim(header, r"attn2_to_k")
        if dim == 2048 or has(r"down_blocks_2_attentions_\d_transformer_blocks_[1-9]"):
            return "sdxl", t("SDXL-LoRA", "SDXL LoRA")
        if dim == 768 or has(r"down_blocks_0_attentions_0") or has(r"^lora_te_text_model|^te_text_model"):
            return "sd15", t("SD-1.5-LoRA", "SD 1.5 LoRA")
    # LTX-2 und LTX-Video: transformer_blocks.N.attn1
    if has(r"(^|_)transformer_blocks_\d+_attn1_"):
        dim = _in_dim(header, r"transformer_blocks_\d+_attn1_to_k")
        if dim == 4096 or has(r"audio_attn|audio_ff|audio_to_video"):
            return "ltx2", t("LTX-2-LoRA (LTX-2, 2.3)", "LTX-2 LoRA (LTX-2, 2.3)")
        if dim == 2048:
            return "ltxv", t("LTX-Video-0.9-LoRA", "LTX-Video 0.9 LoRA")
    # Wan: blocks.N.cross_attn / self_attn (ohne transformer_)
    if has(r"(^|_)blocks_\d+_(cross_attn|self_attn)_") and not has(r"transformer_blocks_"):
        dim = _in_dim(header, r"blocks_\d+_(self_attn|cross_attn)_[qkvo]")
        base = {1536: "wan-1.3b", 3072: "wan-5b", 5120: "wan-14b"}.get(dim or 0)
        if base:
            return base, t(f"Wan-LoRA ({BASES[base]})", f"Wan LoRA ({BASES[base]})")
        return None, t(f"Wan-LoRA unbekannter Größe (Breite {dim}).", f"Wan LoRA of unknown size (width {dim}).")
    # Z-Image: layers.N.attention + adaLN
    if has(r"(^|_)layers_\d+_attention_") and has(r"adaln_modulation"):
        return "zimage", t("Z-Image-LoRA", "Z-Image LoRA")
    # FLUX.2 Klein vor FLUX.1: eigene Modulations- und Fused-Schichten
    if has(r"double_stream_modulation|single_stream_modulation|to_qkv_mlp_proj"):
        return "flux2", t("FLUX.2-Klein-LoRA – unter Windows gibt es kein passendes Modell.",
                          "FLUX.2 Klein LoRA – there is no matching model on Windows.")
    if has(r"(^|_)(double_blocks|single_blocks|single_transformer_blocks)_\d+_"):
        # FLUX.2 Klein 4B hat 5 Doppel- und 20 Einzelbloecke, FLUX.1 und Chroma 19 und 38.
        doubles = [int(x) for x in re.findall(r"(?:double_blocks|(?<!single_)transformer_blocks)_(\d+)_", joined)]
        singles = [int(x) for x in re.findall(r"single_(?:transformer_)?blocks_(\d+)_", joined)]
        if (doubles and max(doubles) < 8) and (not singles or max(singles) < 24):
            return "flux2", t("FLUX.2-Klein-LoRA – unter Windows gibt es kein passendes Modell.",
                              "FLUX.2 Klein LoRA – there is no matching model on Windows.")
        dim = _in_dim(header, r"(double_blocks|single_blocks|single_transformer_blocks)_\d+_")
        if dim in (3072, None, 12288, 15360):
            return "flux1", t("FLUX.1-LoRA (läuft auch an Chroma, dort nicht immer gleich gut)",
                              "FLUX.1 LoRA (also runs on Chroma, not always equally well)")
    # Qwen-Image: transformer_blocks.N.attn.(add_)k_proj / img_mlp, 60 Bloecke, Breite 3072
    if has(r"transformer_blocks_\d+_(attn_(add_)?[kqv]_proj|attn_to_[kqv]|img_mlp|txt_mlp)"):
        dim = _in_dim(header, r"transformer_blocks_\d+_attn_")
        if dim in (3072, None) and not has(r"single_transformer_blocks"):
            return "qwenimage", t("Qwen-Image-LoRA", "Qwen-Image LoRA")
    return None, t("LoRA für eine Architektur, die NVAI-open nicht kennt.",
                   "LoRA for an architecture NVAI-open does not know.")


def trigger_from_metadata(header: dict[str, Any]) -> str:
    """Haeufigste Trainings-Tags aus kohya-Metadaten als Trigger-Vorschlag."""
    import json

    meta = header.get("__metadata__") or {}
    raw = meta.get("ss_tag_frequency")
    if not raw:
        return ""
    try:
        freq: dict[str, int] = {}
        for tags in json.loads(raw).values():
            for tag, n in tags.items():
                freq[tag.strip()] = freq.get(tag.strip(), 0) + int(n)
    except (ValueError, AttributeError):
        return ""
    top = sorted(freq.items(), key=lambda x: -x[1])[:3]
    return ", ".join(tag for tag, _ in top if tag)


def bases_for(entry: dict[str, Any]) -> tuple[str, ...]:
    """LoRA-Basen, die ein Katalogmodell nimmt (leer = keine LoRAs)."""
    wf = entry.get("workflow") or ""
    if wf == "sdxl" and entry.get("family") == "sd15":
        return ("sd15",)
    return WORKFLOW_BASES.get(wf, ())


def compatible(lora: dict[str, Any], model: dict[str, Any]) -> bool:
    return lora.get("family") in bases_for(model)


# ------------------------------------------------------------ Graph

_LOADERS = {"UNETLoader", "CheckpointLoaderSimple"}


def apply(graph: dict[str, Any], loras: list[dict[str, Any]]) -> dict[str, Any]:
    """Haengt jede LoRA (file, strength, expert) hinter jeden Modell-Lader.

    expert "high"/"low" bindet eine LoRA nur an den passenden Wan-2.2-A14B-Experten
    (Dateiname des Laders enthaelt high_noise bzw. low_noise); sonst gilt sie fuer alle.
    Alle Verweise auf den Modell-Ausgang des Laders zeigen danach auf das Kettenende.
    """
    if not loras:
        return graph
    loaders = [(nid, n) for nid, n in graph.items() if n.get("class_type") in _LOADERS]
    for nid, node in loaders:
        name = str(node["inputs"].get("unet_name") or node["inputs"].get("ckpt_name") or "").lower()
        expert = "high" if "high_noise" in name else "low" if "low_noise" in name else None
        chain_in: list[Any] = [nid, 0]
        added: list[str] = []
        for i, lo in enumerate(loras):
            if lo.get("expert") and expert and lo["expert"] != expert:
                continue
            new_id = f"lora_{nid}_{i}"
            graph[new_id] = {"class_type": "LoraLoaderModelOnly", "inputs": {
                "model": chain_in, "lora_name": lo["file"], "strength_model": float(lo.get("strength", 1.0))}}
            chain_in = [new_id, 0]
            added.append(new_id)
        if not added:
            continue
        for other_id, other in graph.items():
            if other_id in added:
                continue
            for k, v in other.get("inputs", {}).items():
                if isinstance(v, list) and len(v) == 2 and v[0] == nid and v[1] == 0:
                    other["inputs"][k] = chain_in
    return graph


def expert_of(file_name: str) -> str | None:
    """Wan 2.2 A14B: LoRAs kommen als Paar fuer den High- und Low-Noise-Experten."""
    low = file_name.lower()
    if re.search(r"high[_\-]?noise|(^|[_\-])high([_\-.]|$)|[_\-]h[_\-]e\d", low):
        return "high"
    if re.search(r"low[_\-]?noise|(^|[_\-])low([_\-.]|$)|[_\-]l[_\-]e\d", low):
        return "low"
    return None
