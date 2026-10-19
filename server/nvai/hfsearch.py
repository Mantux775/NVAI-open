"""Weitere Modelle auf Hugging Face finden -- mit Pruefung vor dem Laden.

Wie in NVAILocal: erst suchen (Repos samt Dateinamen), dann eine Datei pruefen, bevor
Gigabytes fliessen. Geprueft wird der safetensors-Kopf -- je nach Modell einige hundert
KB, per Range-Anfrage -- und daraus die Architektur bestimmt. Zum Laden angeboten wird nur,
was ein vorhandener Workflow sicher rechnet: vollstaendige SDXL-Checkpoints (dazu
gehoeren Pony, Illustrious, NoobAI, Juggernaut, RealVis ...) und SD-1.5-Checkpoints.
Reine Diffusionsmodelle ohne Text-Encoder und VAE, LoRAs und GGUF-Dateien nicht.
"""
from __future__ import annotations

import json
import struct
from typing import Any
from urllib.parse import quote

import httpx
from huggingface_hub import get_token

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


async def search(query: str, limit: int = 20) -> list[dict[str, Any]]:
    params = [("search", query), ("limit", str(limit)), ("sort", "downloads"), ("direction", "-1")]
    params += [("expand[]", x) for x in
               ("siblings", "cardData", "downloads", "likes", "gated", "pipeline_tag")]
    async with httpx.AsyncClient(timeout=20, headers=_auth()) as c:
        r = await c.get(API, params=params)
        r.raise_for_status()
    results = []
    for m in r.json():
        names = [s["rfilename"] for s in m.get("siblings") or []]
        files = [n for n in names if n.lower().endswith(".safetensors")
                 and not n.startswith(_DIFFUSERS_DIRS)]
        note = ""
        if not files:
            if "model_index.json" in names:
                note = t("Nur im Diffusers-Format – NV-AI lädt Einzeldatei-Checkpoints.",
                         "Diffusers format only – NV-AI loads single-file checkpoints.")
            elif any(n.lower().endswith(".gguf") for n in names):
                note = t("Nur GGUF – das bräuchte eine ComfyUI-Erweiterung.",
                         "GGUF only – that would need a ComfyUI extension.")
            else:
                note = t("Keine safetensors-Datei.", "No safetensors file.")
        card = m.get("cardData") or {}
        license_ = card.get("license") or ""
        if isinstance(license_, list):
            license_ = ", ".join(license_)
        results.append({
            "repo": m["id"],
            "downloads": m.get("downloads") or 0,
            "likes": m.get("likes") or 0,
            "license": license_,
            "gated": bool(m.get("gated")),
            "pipeline_tag": m.get("pipeline_tag") or "",
            "files": files[:12],
            "note": note,
        })
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
        buf = bytearray()
        async for chunk in r.aiter_bytes():
            buf += chunk
            if len(buf) >= want:
                break
    return bytes(buf[:want]), total


def classify(keys: list[str]) -> tuple[str, str]:
    """(Familie, Beschreibung) aus den Tensor-Namen eines Checkpoints."""
    def has(prefix: str) -> bool:
        return any(k.startswith(prefix) for k in keys)

    if any("lora_up" in k or "lora_down" in k or ".lora_A." in k or k.startswith("lora_unet_")
           for k in keys):
        return "lora", t("LoRA – NV-AI bindet LoRAs noch nicht ein.", "LoRA – NV-AI does not support LoRAs yet.")
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
    if has("double_blocks.") or has("model.diffusion_model.double_blocks."):
        return "flux", t("FLUX-Diffusionsmodell ohne Text-Encoder und VAE – nicht unterstützt.",
                          "FLUX diffusion model without text encoder and VAE – not supported.")
    if has("joint_blocks.") or has("model.diffusion_model.joint_blocks."):
        return "sd3", t("SD3-Diffusionsmodell – nicht unterstützt.", "SD3 diffusion model – not supported.")
    return "unbekannt", t("Unbekannte Architektur – nicht unterstützt.", "Unknown architecture – not supported.")


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
                                      "und den Token in NV-AI hinterlegen.",
                                      "Gated: accept the license on Hugging Face "
                                      "and enter your token in NV-AI.")}
    except (httpx.HTTPError, struct.error) as e:
        return {**base, "verdict": t(f"Prüfung fehlgeschlagen: {e}", f"Check failed: {e}")}
    try:
        header = json.loads(raw)
    except ValueError:
        return {**base, "verdict": t("Keine gültige safetensors-Datei.", "Not a valid safetensors file.")}
    family, verdict = classify([k for k in header if k != "__metadata__"])
    size_gb = round(total / 1e9, 2) if total else None
    return {**base, "ok": family in SUPPORTED, "family": family,
            "workflow": "sdxl" if family in SUPPORTED else None,
            "size_gb": size_gb, "verdict": verdict}
