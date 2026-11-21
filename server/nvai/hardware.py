"""Hardware-Katalog (seit 0.5.28; Nutzer 14.11.2026: „samele dafür ein katalog für unterschiedliche hardware und
platformen“, „nutze dieses hardware katalog auch bei model vorschlägen in Modelle und anderen berreichen“).

`hardware.json` beschreibt 110 Grafikkarten und Chips (NVIDIA RTX 20 bis 50 samt Laptops und Workstation-Karten, AMD
Radeon RX 7000/9000, Apple M1 bis M6) mit Speicher, Bandbreite und dichtem Rechendurchsatz je Genauigkeit, jeweils mit
Quellen und markierten Unsicherheiten (recherchiert 14.11.2026 aus Whitepapern, Datenblättern und Herstellerseiten).

Daraus:
- **profile():** die rechnende Karte mit Katalogeintrag und geschätzter Geschwindigkeit gegenüber der Referenzkarte, auf
  der alle Laufzeiten gemessen sind (RTX 5060 Ti 16 GB mit NVFP4-Fassungen).
- **estimates():** typische Rechenzeit je Modell für diese Karte (Modelle-Seite, Reiter Generieren, Assistent).

Die Geschwindigkeit ist eine grobe Schätzung aus Datenblattwerten: dichter FP4-Durchsatz für RTX 50 (NVFP4-Fassungen),
dichter INT8-Durchsatz für ältere NVIDIA-Karten (INT8-Fassungen), FP8 (RDNA 4) bzw. FP16 (RDNA 3) mit Abschlag für Radeon
unter ROCm. Gegenprobe an einem zweiten Messpunkt: RTX 4060 (INT8, 121 TOPS) gegen 5060 Ti (FP4, 379,5 TFLOPS) sagt
3,1-fach langsamer voraus, gemessen wurde mit FLUX 3 3,2-fach (23.10.2026).
"""
from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path
from typing import Any

from . import gpu

CATALOG_FILE = Path(__file__).with_name("hardware.json")
REFERENCE_ID = "rtx-5060-ti-16"
REFERENCE_NAME = "NVIDIA GeForce RTX 5060 Ti 16 GB"
REF_VRAM_GB = 16.0
# Radeon unter ROCm erreicht weniger vom Datenblatt als CUDA mit fertigen Kernen (experimentell, notizen/gpu.md); grober
# Abschlag, die Zeiten sind dort als grob markiert
AMD_EFFICIENCY = 0.6

# Typische Aufträge je Modellfamilie (oder einzelnem Modell), gemessen auf der Referenzkarte, Sekunden
# (notizen/laufzeiten.md, CLAUDE.md „Laufzeiten“). task benennt die Einheit für die Anzeige.
MODEL_REF: dict[str, tuple[float, str]] = {
    "qwen-image-2512-lightning": (17, "image_1024"),
    "qwenimage": (98, "image_1024"),            # Qwen-Image-2512 NVFP4, 1024², 50 Schritte
    "flux3": (30, "image_1024"),                # FLUX 3 Klein, 1024², neuer Prompt (bekannter 13–16 s)
    "krea2": (20, "image_1mp"),
    "moss_image": (51, "image_1mp"),
    "ltx25": (251, "video_5s_1080"),            # 1920 × 1088, 5 s, Standard (DFR 786 s)
    "wan22-i2v-a14b": (390, "video_5s_560"),    # 1280 × 560, 5 s, mit 4-Schritt-LoRA (ohne 3280 s)
    "kandinsky6-pro-distill-int8": (996, "video_5s_480"),
    "kandinsky6-lite-distill-int8": (294, "video_5s_480"),
    "stable_audio": (12, "sfx_6s"),
    "stable_audio3": (10, "music_60s"),
    "qwen3_tts": (2.3, "line"),
    "triposg": (60, "mesh"),
    "trellis2": (75, "mesh"),
    "relayvsr": (38, "upscale_5s"),             # 1024 × 576 -> 2048 × 1152, 5 s
}


@lru_cache(maxsize=1)
def catalog() -> dict[str, Any]:
    try:
        return json.loads(CATALOG_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"devices": []}


def match_device(name: str, memory_gb: float | None = None) -> dict[str, Any] | None:
    """Eintrag zu einem Gerätenamen: einer der `match`-Teile kommt vor, kein `exclude`-Teil; bei mehreren der genaueste
    (längster Treffer), bei Varianten mit gleichem Namen (RTX 5060 Ti 8/16 GB, 3080 10/12 GB …) die passende Speichergröße."""
    n = " ".join((name or "").lower().split())
    hits = []
    for d in catalog().get("devices", []):
        found = [m for m in d.get("match") or [] if m in n]
        if found and not any(x in n for x in d.get("exclude") or []):
            hits.append((max(len(m) for m in found), d))
    if not hits:
        return None
    if memory_gb:
        sized = [h for h in hits if any(abs(float(g) - memory_gb) <= 1.5 for g in h[1].get("memory_gb") or [])]
        hits = sized or hits
    return max(hits, key=lambda h: h[0])[1]


def metric(dev: dict[str, Any] | None) -> tuple[float | None, str]:
    """Durchsatz für den Rechenweg der Karte und dessen Name (fp4, int8, fp16, amd, apple)."""
    if not dev:
        return None, ""
    vendor = dev.get("vendor")
    if vendor == "nvidia":
        if (dev.get("compute_cap") or 0) >= 12 and dev.get("fp4_tflops"):
            return float(dev["fp4_tflops"]), "fp4"
        if dev.get("int8_tops"):
            return float(dev["int8_tops"]), "int8"
        if dev.get("fp16_tflops"):
            return 2 * float(dev["fp16_tflops"]), "fp16"
    if vendor == "amd":
        v = dev.get("fp8_tflops") or dev.get("fp16_tflops")
        return (float(v) * AMD_EFFICIENCY, "amd") if v else (None, "")
    if vendor == "apple":
        return (float(dev["fp16_tflops"]), "apple") if dev.get("fp16_tflops") else (None, "")
    return None, ""


def speed(dev: dict[str, Any] | None) -> float | None:
    """Wie viel schneller (>1) oder langsamer (<1) als die Referenzkarte; None ohne Katalogwerte."""
    ref = next((d for d in catalog().get("devices", []) if d.get("id") == REFERENCE_ID), None)
    mine, _ = metric(dev)
    base, _ = metric(ref)
    if not mine or not base:
        return None
    return max(0.05, min(20.0, mine / base))


def profile() -> dict[str, Any]:
    """Die rechnende Karte (die stärkste; so rechnet NVAI-open ohne eigene Zuordnung) mit Katalogeintrag."""
    cards = gpu.list_gpus()
    if not cards:
        return {"name": None, "vendor": None, "vram_gb": None, "catalog_id": None, "arch": None, "speed": None,
                "path": None, "uncertain": False, "reference": REFERENCE_NAME}
    card = max(cards, key=gpu.strength)
    vram = card.get("vram_total_gb")
    dev = match_device(card.get("name") or "", vram)
    cpu = bool(gpu.cpu_mode())
    sp = None if cpu else speed(dev)  # rechnet auf dem Prozessor (gpu.cpu_mode): die Werte der Karte gelten nicht
    return {"name": card.get("name"), "vendor": card.get("vendor"), "vram_gb": vram,
            "catalog_id": dev.get("id") if dev else None, "catalog_name": dev.get("name") if dev else None,
            "arch": dev.get("arch") if dev else None, "laptop": bool(dev.get("laptop")) if dev else None,
            "speed": round(sp, 2) if sp else None, "path": metric(dev)[1] or None,
            "uncertain": bool(dev and dev.get("uncertain")), "reference": REFERENCE_NAME, "cpu_mode": cpu}


def _ref_for(model_id: str, family: str) -> tuple[float, str] | None:
    return MODEL_REF.get(model_id) or MODEL_REF.get(family)


def estimates(models: list[Any]) -> dict[str, dict[str, Any]]:
    """Typische Rechenzeit je Modell auf dieser Karte (Referenzmessung geteilt durch die Geschwindigkeit). Nur für die
    Fassung, die der Server für diese Karte empfiehlt, oder Familien ohne Empfehlung: Andere Fassungen (INT8 auf einer
    RTX 50, bf16) liefen auf der Referenz nicht so und bekämen eine falsche Zahl."""
    prof = profile()
    if prof.get("cpu_mode"):
        return {}  # auf dem Prozessor stimmt keine Zeit der Referenzkarte
    sp = prof["speed"] or 1.0
    smaller = bool(prof["vram_gb"]) and prof["vram_gb"] < REF_VRAM_GB - 0.5
    fam_has_rec = {m.family for m in models if getattr(m, "recommended", False)}
    out: dict[str, dict[str, Any]] = {}
    for m in models:
        ref = _ref_for(m.id, m.family)
        if not ref or (m.family in fam_has_rec and not m.recommended):
            continue
        seconds = ref[0] / sp
        if m.fits_vram == "nein" and smaller:
            seconds *= 1.5  # wird je Schritt nachgeladen (gpu.fits); auf der Referenz schon in den Messwerten
        out[m.id] = {"seconds": round(seconds, 1), "task": ref[1], "measured": prof["catalog_id"] == REFERENCE_ID}
    return out
