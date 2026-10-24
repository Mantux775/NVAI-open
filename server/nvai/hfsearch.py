"""Weitere Modelle auf Hugging Face finden -- mit Pruefung vor dem Laden.

Wie in NVAILocal: erst suchen (Repos samt Dateinamen), dann eine Datei pruefen, bevor
Gigabytes fliessen. Geprueft wird der safetensors-Kopf -- je nach Modell einige hundert
KB, per Range-Anfrage -- und daraus die Architektur bestimmt. Zum Laden angeboten wird nur,
was ein vorhandener Workflow sicher rechnet: vollstaendige SDXL-Checkpoints (dazu
gehoeren Pony, Illustrious, NoobAI, Juggernaut, RealVis ...) und SD-1.5-Checkpoints.
LoRAs werden am Dateikopf einer Architektur zugeordnet (loras.detect) und laufen mit jedem
passenden Katalogmodell. Reine Diffusionsmodelle ohne Text-Encoder und VAE und GGUF nicht; die
Suche erkennt sie aber und sagt, was sie sind (Qwen-Image 2.1, FLUX, Wan, Text-Encoder ...)
und welches Katalogmodell dieselbe Architektur rechnet.
"""
from __future__ import annotations

import json
import struct
from typing import Any
from urllib.parse import quote

import httpx
from huggingface_hub import get_token

from . import loras
from .i18n import t

API = "https://huggingface.co/api/models"
# Unterordner des Diffusers-Formats -- deren Einzeldateien sind keine Checkpoints.
_DIFFUSERS_DIRS = ("unet/", "text_encoder/", "text_encoder_2/", "text_encoder_3/", "vae/",
                   "transformer/", "tokenizer/", "tokenizer_2/", "scheduler/", "safety_checker/")
_HEADER_LIMIT = 64 * 1024 * 1024   # groesster plausibler safetensors-Kopf

SD15_SIZES = [
    {"label": "512 × 512 — SD 1.5 nativ", "w": 512, "h": 512},
    {"label": "512 × 768 — Hochformat", "w": 512, "h": 768},
    {"label": "768 × 512 — Querformat", "w": 768, "h": 512},
]


def _auth() -> dict[str, str]:
    token = get_token()
    return {"Authorization": f"Bearer {token}"} if token else {}


# Woran ein Dateiname als Teil eines Modells zu erkennen ist (Ordner im ComfyUI-Layout oder
# typische Namen). Alles andere gilt als moeglicher Checkpoint und laesst sich pruefen.
_PART_HINTS: list[tuple[str, tuple[str, ...]]] = [
    ("lora", ("loras/", "lora")),
    ("text_encoder", ("text_encoders/", "clip/", "t5xxl", "umt5", "clip_l", "clip_g",
                      "qwen_2.5_vl", "qwen2.5_vl", "qwen3vl", "qwen3_", "qwen3.5_", "gemma", "llava",
                      "mistral_3")),
    ("vae", ("vae/", "vae_", "_vae", "vae.")),
    ("controlnet", ("controlnet/", "model_patches/", "controlnet")),
    ("upscaler", ("upscale_models/", "esrgan", "upscaler")),
    ("diffusion", ("diffusion_models/", "unet/")),
]


def part_kind(path: str) -> str:
    """Grobe Art einer Datei nach Pfad und Namen: lora, text_encoder, vae, controlnet,
    upscaler, diffusion -- oder checkpoint, wenn nichts dagegen spricht."""
    low = path.lower()
    for kind, hints in _PART_HINTS:
        if any(h in low for h in hints):
            return kind
    return "checkpoint"


def _base_model(tags: list[str]) -> str:
    for prefix in ("base_model:adapter:", "base_model:finetune:", "base_model:quantized:", "base_model:"):
        for tag in tags:
            if tag.startswith(prefix) and ":" not in tag[len(prefix):]:
                return tag[len(prefix):]
    return ""


def lora_targets(base: str | None) -> list[str]:
    """Namen der Katalogmodelle, die LoRAs dieser Basis nehmen."""
    from . import registry   # spaet, registry importiert dieses Modul

    if not base:
        return []
    return [registry.display_name(e) for e in registry.all_entries()
            if base in loras.bases_for(e) and not e.get("custom")]


async def search(query: str, limit: int = 20, lora_only: bool = False) -> list[dict[str, Any]]:
    """Repos samt ihren safetensors-Dateien, jede Datei mit ihrer vermuteten Art.

    `files` sind moegliche Checkpoints (pruefbar, vielleicht ladbar), `parts` die erkannten
    Modellteile. `kind` sagt, was das Repo im Ganzen ist: "checkpoint", "parts" (Teile eines
    neueren Modells wie Qwen, FLUX, Wan), "lora" oder "other" (nichts Ladbares).
    """
    params = [("search", query), ("limit", str(limit)), ("sort", "downloads"), ("direction", "-1")]
    params += [("expand[]", x) for x in
               ("siblings", "cardData", "downloads", "likes", "gated", "pipeline_tag", "tags")]
    if lora_only:
        params.append(("filter", "lora"))
    async with httpx.AsyncClient(timeout=20, headers=_auth()) as c:
        r = await c.get(API, params=params)
        r.raise_for_status()
    results = []
    for m in r.json():
        tags = m.get("tags") or []
        lora_repo = "lora" in tags or any(x.startswith("base_model:adapter:") for x in tags)
        names = [s["rfilename"] for s in m.get("siblings") or []]
        files, parts = [], []
        for n in names:
            if not n.lower().endswith(".safetensors") or n.startswith(_DIFFUSERS_DIRS):
                continue
            kind = "lora" if lora_repo else part_kind(n)
            if kind == "checkpoint":
                files.append(n)
            else:
                parts.append({"file": n, "kind": kind})
        if files:
            repo_kind = "checkpoint"
        elif any(p["kind"] == "diffusion" for p in parts):
            repo_kind = "parts"
        elif any(p["kind"] == "lora" for p in parts):
            repo_kind = "lora"
        else:
            repo_kind = "other"
        note = ""
        if repo_kind == "parts":
            note = t("Teile eines Modells (Diffusionsmodell, Text-Encoder, VAE) – laden lässt sich so "
                     "etwas nur als Katalogmodell mit eigenem Workflow.",
                     "Parts of a model (diffusion model, text encoder, VAE) – these only load as a "
                     "catalog model with its own workflow.")
        lora_base = loras.hf_base_hint(_base_model(tags)) if repo_kind == "lora" else None
        if repo_kind == "lora":
            targets = lora_targets(lora_base)
            note = (t(f"LoRA, laut Repo für {', '.join(targets)} – vor dem Laden prüfen.",
                      f"LoRA, according to the repo for {', '.join(targets)} – check before loading.")
                    if targets else
                    t("LoRA – Datei prüfen, dann zeigt NVAI-open, zu welchem Modell sie passt.",
                      "LoRA – check a file and NVAI-open shows which model it fits."))
        elif repo_kind == "other":
            if "model_index.json" in names:
                note = t("Nur im Diffusers-Format – NVAI-open lädt Einzeldatei-Checkpoints.",
                         "Diffusers format only – NVAI-open loads single-file checkpoints.")
            elif any(n.lower().endswith(".gguf") for n in names):
                note = t("Nur GGUF – das bräuchte eine ComfyUI-Erweiterung.",
                         "GGUF only – that would need a ComfyUI extension.")
            elif parts:
                note = t("Nur einzelne Bausteine (Text-Encoder, VAE, ControlNet …), kein Modell.",
                         "Only single components (text encoder, VAE, ControlNet …), no model.")
            else:
                note = t("Keine safetensors-Datei.", "No safetensors file.")
        card = m.get("cardData") or {}
        license_ = card.get("license") or ""
        if isinstance(license_, list):
            license_ = ", ".join(license_)
        if license_ == "other" and card.get("license_name"):
            license_ = card["license_name"]
        results.append({
            "repo": m["id"],
            "downloads": m.get("downloads") or 0,
            "likes": m.get("likes") or 0,
            "license": license_,
            "gated": bool(m.get("gated")),
            "pipeline_tag": m.get("pipeline_tag") or "",
            "files": files[:12],
            "parts": parts[:16],
            "kind": repo_kind,
            "base_model": _base_model(tags),
            "lora_base": lora_base,
            "trigger": _card_trigger(card),
            "note": note,
        })
    if lora_only:
        results = [r for r in results if r["kind"] == "lora"]
    return results


async def _read(c: httpx.AsyncClient, url: str, start: int, end: int) -> tuple[bytes, int | None]:
    """Bytes start..end (inklusive). Liefert auch die Gesamtgroesse aus Content-Range.

    Gestreamt und hart begrenzt: Ignoriert ein Server den Range-Header und schickt die
    ganze Datei, bricht das nach den gewuenschten Bytes ab statt Gigabytes zu laden.
    """
    want = end - start + 1
    async with c.stream("GET", url, headers={"Range": f"bytes={start}-{end}"}) as r:
        if r.status_code in (401, 403):
            raise PermissionError(r.status_code)
        r.raise_for_status()
        total = None
        content_range = r.headers.get("content-range", "")
        if "/" in content_range:
            tail = content_range.rsplit("/", 1)[1]
            total = int(tail) if tail.isdigit() else None
        # 200 statt 206: Range ignoriert, die Datei kommt ab Byte 0. Civitais CDN macht das
        # bei derselben Datei mal so, mal so (gemessen) -- dann bis start ueberspringen.
        skip = start if r.status_code == 200 else 0
        if skip and total is None and r.headers.get("content-length", "").isdigit():
            total = int(r.headers["content-length"])
        buf = bytearray()
        async for chunk in r.aiter_bytes():
            buf += chunk
            if len(buf) >= skip + want:
                break
    return bytes(buf[skip:skip + want]), total


def classify(keys: list[str]) -> tuple[str, str]:
    """(Familie, Beschreibung) aus den Tensor-Namen eines Checkpoints."""
    def has(prefix: str) -> bool:
        return any(k.startswith(prefix) for k in keys)

    if loras.is_lora(keys):
        return "lora", t("LoRA.", "LoRA.")
    unet = has("model.diffusion_model.")
    vae = has("first_stage_model.")
    if has("conditioner.embedders.1.") and unet:
        if vae:
            return "sdxl", t("SDXL-Checkpoint (wie Pony, Illustrious, Juggernaut) – läuft mit dem SDXL-Workflow.",
                              "SDXL checkpoint (like Pony, Illustrious, Juggernaut) – runs with the SDXL workflow.")
        return "sdxl-unet", t("Nur die SDXL-UNet ohne Text-Encoder und VAE – nicht unterstützt.",
                                "SDXL UNet only, without text encoder and VAE – not supported.")
    if has("cond_stage_model.transformer.text_model.") and unet and vae:
        return "sd15", t("Stable-Diffusion-1.5-Checkpoint – läuft, am besten mit 512 × 512.",
                          "Stable Diffusion 1.5 checkpoint – runs, best at 512 × 512.")
    if has("cond_stage_model.model."):
        return "sd2", t("Stable Diffusion 2 – nicht unterstützt.", "Stable Diffusion 2 – not supported.")
    if has("model.diffusion_model.double_blocks.") and (has("text_encoders.") or vae):
        return "flux", t("FLUX-Checkpoint mit Text-Encoder und VAE – über die Suche nicht ladbar.",
                         "FLUX checkpoint with text encoder and VAE – cannot be loaded from the search.")
    if has("double_blocks.") or has("model.diffusion_model.double_blocks."):
        return "flux", t("FLUX-Diffusionsmodell ohne Text-Encoder und VAE – nicht unterstützt.",
                          "FLUX diffusion model without text encoder and VAE – not supported.")
    if has("joint_blocks.") or has("model.diffusion_model.joint_blocks."):
        return "sd3", t("SD3-Diffusionsmodell – nicht unterstützt.", "SD3 diffusion model – not supported.")
    part = _classify_part(keys)
    if part:
        return part
    return "unbekannt", t("Unbekannte Architektur – nicht unterstützt.", "Unknown architecture – not supported.")


# Diffusionsmodelle, die nur als Teil laufen: (Familie, Anzeigename, Schluessel, die alle da
# sein muessen). Die Schluessel stammen aus ComfyUIs model_detection.py; geprueft wird ohne
# die ueblichen Praefixe. Reihenfolge zaehlt -- Qwen-Image 2.1 vor Qwen-Image, FLUX.3 und
# FLUX.2 vor FLUX.1.
_DIFFUSION_FAMILIES: list[tuple[str, str, tuple[str, ...]]] = [
    ("qwenimage21", "Qwen-Image 2.1", ("txt_in.text_norm.weight", "modulation.1.weight", "img_in.weight")),
    ("qwenimage", "Qwen-Image", ("txt_norm.weight", "img_in.weight")),
    ("flux3", "FLUX.3", ("content_mode_blocks.image.0.attn_out.weight",)),
    ("flux2", "FLUX.2", ("double_stream_modulation_img.lin.weight",)),
    ("chroma", "Chroma", ("distilled_guidance_layer.",)),
    ("flux", "FLUX.1", ("double_blocks.", "img_in.weight")),
    ("hunyuanvideo", "HunyuanVideo", ("txt_in.individual_token_refiner.blocks.0.norm1.weight",)),
    ("wan", "Wan", ("head.modulation",)),
    ("ltxv", "LTX-Video", ("adaln_single.emb.timestep_embedder.linear_1.bias",)),
    ("hidream", "HiDream", ("caption_projection.0.linear.weight",)),
    ("zimage", "Z-Image / Lumina 2", ("cap_embedder.1.weight",)),
    ("ace", "ACE-Step", ("genre_embedder.weight",)),
    ("stable_audio", "Stable Audio", ("transformer.rotary_pos_emb.inv_freq",)),
]
_PREFIXES = ("model.diffusion_model.", "diffusion_model.", "model.", "")


def _classify_part(keys: list[str]) -> tuple[str, str] | None:
    """Erkennt Bausteine neuerer Modelle: Diffusionsmodell, Text-Encoder, VAE, ControlNet."""
    keyset = set(keys)

    def has(name: str) -> bool:
        for p in _PREFIXES:
            full = p + name
            if name.endswith("."):
                if any(k.startswith(full) for k in keys):
                    return True
            elif full in keyset:
                return True
        return False

    def starts(prefix: str) -> bool:
        return any(k.startswith(prefix) for k in keys)

    for family, label, needed in _DIFFUSION_FAMILIES:
        if all(has(n) for n in needed):
            return f"diffusion:{family}", t(
                f"Diffusionsmodell von {label}, ohne Text-Encoder und VAE. Laden lässt es sich nur "
                "als Katalogmodell mit eigenem Workflow.",
                f"{label} diffusion model, without text encoder and VAE. It only loads as a catalog "
                "model with its own workflow.")
    if starts("controlnet_blocks.") or starts("input_hint_block.") or starts("control_model."):
        return "controlnet", t("ControlNet – nur zusammen mit einem passenden Modell nutzbar.",
                               "ControlNet – only usable together with a matching model.")
    if starts("lora_te") or any(".lora." in k or "lora_" in k for k in keys[:200]):
        return "lora", t("LoRA.", "LoRA.")
    if starts("decoder.") and (starts("encoder.") or starts("decoder.conv_in") or starts("decoder.conv1")
                               or starts("decoder.head")):
        return "vae", t("VAE – Baustein eines Modells, allein nicht nutzbar.",
                        "VAE – a model component, not usable on its own.")
    if starts("encoder.block.0.layer.0.SelfAttention."):
        return "text_encoder", t("Text-Encoder (T5) – Baustein eines Modells, allein nicht nutzbar.",
                                 "Text encoder (T5) – a model component, not usable on its own.")
    if starts("text_model.encoder.") or starts("text_projection"):
        return "text_encoder", t("Text-Encoder (CLIP) – Baustein eines Modells, allein nicht nutzbar.",
                                 "Text encoder (CLIP) – a model component, not usable on its own.")
    if starts("model.layers.") or starts("model.language_model.") or starts("language_model."):
        vision = starts("model.visual.") or starts("visual.") or starts("vision_tower.")
        label = t("Sprachmodell mit Bildverständnis", "vision language model") if vision \
            else t("Sprachmodell", "language model")
        return "text_encoder", t(
            f"Text-Encoder ({label}, z. B. für Qwen-Image oder FLUX) – Baustein eines Modells, "
            "allein nicht nutzbar.",
            f"Text encoder ({label}, e.g. for Qwen-Image or FLUX) – a model component, "
            "not usable on its own.")
    return None


SUPPORTED = {"sdxl", "sd15"}


async def inspect(repo: str, file: str) -> dict[str, Any]:
    url = f"https://huggingface.co/{repo}/resolve/main/{quote(file)}"
    base = {"repo": repo, "file": file, "ok": False, "family": None, "workflow": None,
            "size_gb": None, "verdict": ""}
    if not file.lower().endswith(".safetensors"):
        return {**base, "verdict": t("Nur .safetensors-Dateien lassen sich prüfen und laden.",
                                      "Only .safetensors files can be checked and loaded.")}
    try:
        async with httpx.AsyncClient(timeout=30, follow_redirects=True, headers=_auth()) as c:
            head, total = await _read(c, url, 0, 7)
            (n,) = struct.unpack("<Q", head)
            if not 0 < n <= _HEADER_LIMIT:
                return {**base, "verdict": t("Keine gültige safetensors-Datei.", "Not a valid safetensors file.")}
            raw, _ = await _read(c, url, 8, 8 + n - 1)
    except PermissionError:
        return {**base, "verdict": t("Gesperrt (gated): Lizenz auf Hugging Face akzeptieren "
                                      "und den Token in NVAI-open hinterlegen.",
                                      "Gated: accept the license on Hugging Face "
                                      "and enter your token in NVAI-open.")}
    except (httpx.HTTPError, struct.error) as e:
        return {**base, "verdict": t(f"Prüfung fehlgeschlagen: {e}", f"Check failed: {e}")}
    try:
        header = json.loads(raw)
    except ValueError:
        return {**base, "verdict": t("Keine gültige safetensors-Datei.", "Not a valid safetensors file.")}
    size_gb = round(total / 1e9, 2) if total else None
    if loras.is_lora([k for k in header if k != "__metadata__"]):
        return await _inspect_lora(repo, file, header, size_gb, base)
    family, verdict = classify([k for k in header if k != "__metadata__"])
    catalog = catalog_models(family)
    if catalog:
        verdict += t(f" Im Katalog: {', '.join(catalog)}.", f" In the catalog: {', '.join(catalog)}.")
    elif family.startswith("diffusion:"):
        verdict += t(" Im Katalog gibt es diese Familie noch nicht.",
                     " This family is not in the catalog yet.")
    return {**base, "ok": family in SUPPORTED, "family": family,
            "workflow": "sdxl" if family in SUPPORTED else None,
            "size_gb": size_gb, "verdict": verdict, "catalog": catalog}


def _card_trigger(card: dict[str, Any]) -> str:
    """Trigger-Woerter aus der Modellkarte (Diffusers-Trainer schreiben instance_prompt)."""
    value = card.get("instance_prompt") or ""
    if isinstance(value, list):
        value = ", ".join(str(v) for v in value)
    return str(value).strip()[:200]


async def _inspect_lora(repo: str, file: str, header: dict[str, Any], size_gb: float | None,
                        base: dict[str, Any]) -> dict[str, Any]:
    lora_base, why = loras.detect(header)
    targets = lora_targets(lora_base)
    trigger = ""
    try:
        async with httpx.AsyncClient(timeout=15, headers=_auth()) as c:
            r = await c.get(f"{API}/{repo}", params=[("expand[]", "cardData")])
            if r.status_code == 200:
                trigger = _card_trigger(r.json().get("cardData") or {})
    except httpx.HTTPError:
        pass
    trigger = trigger or loras.trigger_from_metadata(header)
    if lora_base and targets:
        verdict = t(f"{why}. Läuft mit: {', '.join(targets)}.", f"{why}. Runs with: {', '.join(targets)}.")
    elif lora_base:
        verdict = t(f"{why}. Im Katalog gibt es dafür kein Modell.", f"{why}. There is no model for it in the catalog.")
    else:
        verdict = why
    return {**base, "ok": bool(lora_base and targets), "kind": "lora", "family": lora_base,
            "workflow": None, "target": "loras", "size_gb": size_gb, "verdict": verdict,
            "catalog": targets, "trigger": trigger}


# Erkannte Familie -> Familien im Katalog, die dieselbe Architektur rechnen.
_CATALOG_FAMILIES = {
    "qwenimage21": ("qwenimage21",), "qwenimage": ("qwenimage",), "flux3": ("flux3",), "flux": ("flux",), "chroma": ("chroma",),
    "wan": ("wan", "wan22"), "ltxv": ("ltxv",), "zimage": ("zimage",), "ace": ("ace", "ace15"),
    "stable_audio": ("stable_audio",), "hunyuanvideo": ("hunyuanvideo15",), "sd3": ("sd3",),
}


def catalog_models(family: str) -> list[str]:
    """Namen der Katalogmodelle derselben Architektur -- ohne Zubehoer wie ControlNets."""
    from . import registry   # spaet, registry importiert dieses Modul

    wanted = _CATALOG_FAMILIES.get(family.removeprefix("diffusion:"), ())
    return [registry.display_name(e) for e in registry.all_entries()
            if e.get("family") in wanted and e.get("kind") in ("image", "video", "audio")]
