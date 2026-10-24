"""LoRAs von Civitai finden und pruefen.

Civitai nennt zu jeder Modellversion ihr Basismodell ("SDXL 1.0", "Wan Video 2.2 I2V-A14B" ...),
die Trigger-Woerter und die Dateien. Die Suche uebersetzt das Basismodell in NVAI-opens
LoRA-Basis (loras.BASES). Herunterladen verlangt bei Civitai fast immer einen API-Schluessel
des Nutzers; mit Schluessel prueft check() zusaetzlich den safetensors-Kopf wie bei Hugging
Face, ohne verlaesst sich NVAI-open auf Civitais Angabe.
"""
from __future__ import annotations

import json
import struct
from typing import Any

import httpx

from . import loras, registry
from .hfsearch import _HEADER_LIMIT, _read, lora_targets
from .i18n import t

API = "https://civitai.com/api/v1/models"

# Civitais Basismodell -> LoRA-Basis. Was fehlt, rechnet kein Katalogmodell.
BASE_MODELS: dict[str, str] = {
    "SDXL 1.0": "sdxl", "SDXL 0.9": "sdxl", "SDXL 1.0 LCM": "sdxl", "SDXL Lightning": "sdxl",
    "SDXL Hyper": "sdxl", "SDXL Turbo": "sdxl", "SDXL Distilled": "sdxl", "Pony": "sdxl",
    "Illustrious": "sdxl", "NoobAI": "sdxl",
    "SD 1.5": "sd15", "SD 1.5 LCM": "sd15", "SD 1.5 Hyper": "sd15",
    "Qwen": "qwenimage", "ZImageTurbo": "zimage", "ZImageBase": "zimage",
    "Flux.1 S": "flux1", "Flux.1 D": "flux1", "Flux.1 Krea": "flux1", "Chroma": "flux1",
    "Flux.2 Klein 4B": "flux2", "Flux.2 Klein 4B-base": "flux2",
    "Wan Video 1.3B t2v": "wan-1.3b", "Wan Video 2.2 TI2V-5B": "wan-5b",
    "Wan Video": "wan-14b", "Wan Video 14B t2v": "wan-14b", "Wan Video 14B i2v 480p": "wan-14b",
    "Wan Video 14B i2v 720p": "wan-14b", "Wan Video 2.2 I2V-A14B": "wan-14b",
    "Wan Video 2.2 T2V-A14B": "wan-14b",
    "LTXV2": "ltx2", "LTXV 2.3": "ltx2", "LTXV 2.5": "ltx2", "LTXV": "ltxv",
}


def _civitai_bases(lora_base: str) -> list[str]:
    return [name for name, base in BASE_MODELS.items() if base == lora_base]


async def search(query: str, lora_base: str | None = None, limit: int = 20) -> list[dict[str, Any]]:
    """LoRAs von Civitai, je Modell die neueste Version mit Datei, Basis und Trigger."""
    params: list[tuple[str, str]] = [("types", "LORA"), ("limit", str(limit)), ("nsfw", "true")]
    if query:
        params.append(("query", query))
    else:
        params.append(("sort", "Most Downloaded"))
    for name in _civitai_bases(lora_base) if lora_base else []:
        params.append(("baseModels", name))
    headers = {}
    token = registry.civitai_token()
    if token:
        headers["Authorization"] = f"Bearer {token}"
    async with httpx.AsyncClient(timeout=30, headers=headers) as c:
        r = await c.get(API, params=params)
        r.raise_for_status()
    out = []
    for m in r.json().get("items", []):
        for v in (m.get("modelVersions") or [])[:3]:
            files = [f for f in v.get("files") or []
                     if (f.get("name") or "").lower().endswith(".safetensors")]
            if not files:
                continue
            f = next((x for x in files if x.get("primary")), files[0])
            base = BASE_MODELS.get(v.get("baseModel") or "")
            if lora_base and base != lora_base:
                continue
            commercial = m.get("allowCommercialUse")
            if isinstance(commercial, list):
                commercial = ", ".join(commercial)
            out.append({
                "model_id": m["id"], "version_id": v["id"],
                "name": m.get("name") or "", "version": v.get("name") or "",
                "base_model": v.get("baseModel") or "", "lora_base": base,
                "targets": lora_targets(base),
                "trigger": ", ".join(w.strip() for w in (v.get("trainedWords") or []) if w)[:300],
                "file": f["name"], "size_gb": round((f.get("sizeKB") or 0) / 1e6, 3),
                "url": f.get("downloadUrl") or "",
                "page": f"https://civitai.com/models/{m['id']}?modelVersionId={v['id']}",
                "nsfw": bool(m.get("nsfw")), "commercial": commercial or "",
                "creator": (m.get("creator") or {}).get("username") or "",
                "downloads": (m.get("stats") or {}).get("downloadCount") or 0,
            })
            break   # nur die neueste passende Version je Modell
    return out


async def check(url: str, civitai_base: str = "") -> dict[str, Any]:
    """Prueft eine Civitai-Datei am safetensors-Kopf -- geht nur mit API-Schluessel."""
    base_hint = BASE_MODELS.get(civitai_base)
    token = registry.civitai_token()
    result: dict[str, Any] = {"ok": False, "family": base_hint, "checked": False,
                              "catalog": lora_targets(base_hint), "verdict": ""}
    if not url.startswith("https://civitai.com/api/download/"):
        return {**result, "verdict": t("Keine Civitai-Download-Adresse.", "Not a Civitai download address.")}
    if not token:
        ok = bool(base_hint and result["catalog"])
        return {**result, "ok": ok, "verdict": t(
            "Ohne Civitai-Schlüssel nur nach Civitais Angabe geprüft"
            + (f": läuft mit {', '.join(result['catalog'])}." if ok else ": dafür gibt es kein Modell."),
            "Checked only by Civitai's label without a Civitai key"
            + (f": runs with {', '.join(result['catalog'])}." if ok else ": there is no model for it."))}
    try:
        async with httpx.AsyncClient(timeout=30, follow_redirects=True,
                                     headers={"Authorization": f"Bearer {token}"}) as c:
            head, total = await _read(c, url, 0, 7)
            (n,) = struct.unpack("<Q", head)
            if not 0 < n <= _HEADER_LIMIT:
                return {**result, "verdict": t("Keine gültige safetensors-Datei.", "Not a valid safetensors file.")}
            raw, _ = await _read(c, url, 8, 8 + n - 1)
        header = json.loads(raw)
    except PermissionError:
        return {**result, "verdict": t("Civitai lehnt den Schlüssel ab.", "Civitai rejects the key.")}
    except (httpx.HTTPError, struct.error, ValueError) as e:
        return {**result, "verdict": t(f"Prüfung fehlgeschlagen: {e}", f"Check failed: {e}")}
    family, why = loras.detect(header)
    targets = lora_targets(family)
    note = ""
    if base_hint and family and base_hint != family:
        note = t(f" Civitai sagt {civitai_base}, die Datei ist aber {loras.BASES.get(family, family)}.",
                 f" Civitai says {civitai_base}, but the file is {loras.BASES.get(family, family)}.")
    return {"ok": bool(family and targets), "family": family, "checked": True, "catalog": targets,
            "size_gb": round(total / 1e9, 3) if total else None,
            "trigger": loras.trigger_from_metadata(header),
            "verdict": (t(f"{why}. Läuft mit: {', '.join(targets)}.", f"{why}. Runs with: {', '.join(targets)}.")
                        if family and targets else why) + note}
