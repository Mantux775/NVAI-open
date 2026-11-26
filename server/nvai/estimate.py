"""Geschätzte Rechenzeit je Auftrag (seit 0.5.42; Konzept „NVAI im Fluss“, 26.11.2026: „Ehrliche Zeit: vorher die
Schätzung aus dem Hardware-Katalog, währenddessen Phase und Restzeit“).

Zuerst aus eigenen Läufen auf diesem Rechner (Median je Einheit wie im Assistenten, nur vergleichbare Läufe desselben
Modells), sonst aus den Referenzmessungen (`hardware.MODEL_REF`, RTX 5060 Ti 16 GB) geteilt durch die geschätzte
Geschwindigkeit der Karte. Getrennt davon, was nur vor dem Rechnen anfällt: GPU-Backend starten und Modell laden
(Oberflächentest 26.11.2026: 32 s Start, 38 s Laden für Qwen-Image-2512).

Quelle je Schätzung: `history` (gemessen bei dir), `estimate` (Referenzmessung), `rough` (aus einer anderen Einstellung
hochgerechnet), `unknown` (keine Zahl, etwa auf dem Prozessor).
"""
from __future__ import annotations

import statistics
import threading
import time
from typing import Any

from . import comfy, db, hardware, registry
from .hardware import MODEL_REF, REF_VRAM_GB

BACKEND_START_S = 32.0   # ComfyUI-Start im Oberflächentest 26.11.2026
LOAD_GB_PER_S = 0.37     # Qwen-Image-2512 NVFP4 (14 GB) lud in 38 s
EXPAND_S = 15.0          # Prompt ausbauen, warm 13–16 s
RESTORE_S = 150.0        # Foto restaurieren, 2 Varianten in 2 MP
RESTORE_EXTRA_S = 50.0   # dazu einfärben und schärfen (~200 s zusammen)
VOICE_LOAD_S = 45.0      # Qwen3-TTS: erster Satz nach dem Start (+20–65 s)
MESH_COLD_S = 120.0      # TripoSG: ~60 s warm, ~180 s kalt

# Bezugsgrößen der Referenzmessungen (Aufgabe aus MODEL_REF): Megapixel und Sekunden je Messung
_TASK: dict[str, dict[str, float]] = {
    "image_1024": {"mp": 1024 * 1024 / 1e6},
    "image_1mp": {"mp": 1.0},
    "video_5s_1080": {"mp": 1920 * 1088 / 1e6, "secs": 5.0},
    "video_5s_560": {"mp": 1280 * 560 / 1e6, "secs": 5.0},
    "video_5s_480": {"mp": 832 * 480 / 1e6, "secs": 5.0},
    "sfx_6s": {"secs": 6.0},
    "music_60s": {"secs": 60.0},
    "line": {},
    "mesh": {},
    "upscale_5s": {"mp": 1024 * 576 / 1e6, "secs": 5.0},
}

# LTX-2.5 je Weg gegenüber Standard mit Text oder Startbild (notizen/laufzeiten.md): DFR 786 statt 251 s; Start- und
# Endbild 154 statt 93–109 s, Schleife 125 s für 4 s; 48 fps kostete im Test kaum mehr (DFR 3 s in 194 s).
_DFR = 786.0 / 251.0
_ENDS = 1.5
_TEMPORAL = 1.1
_LAYOUT = 1.4            # eine Stufe in voller Auflösung, nicht gemessen
_EXTEND = 1.15           # die letzte Sekunde läuft als Vorlage mit, nicht gemessen

_models_cache: tuple[float, dict[str, Any]] | None = None
_models_lock = threading.Lock()


def _models() -> dict[str, Any]:
    """Modellliste mit `fits_vram` und `recommended`, zehn Sekunden zwischengespeichert (die Oberfläche fragt oft)."""
    global _models_cache
    with _models_lock:
        if _models_cache and time.monotonic() - _models_cache[0] < 10.0:
            return _models_cache[1]
    infos = {m.id: m for m in registry.list_models()}
    with _models_lock:
        _models_cache = (time.monotonic(), infos)
    return infos


def _mp(p: dict[str, Any]) -> float:
    return float(p.get("width") or 0) * float(p.get("height") or 0) / 1e6


def _clip_seconds(p: dict[str, Any]) -> float:
    frames = float(p.get("frames") or 0)
    fps = float(p.get("fps") or 24)
    return frames / fps if frames and fps else float(p.get("seconds") or 5.0)


def _video_factor(p: dict[str, Any]) -> tuple[float, bool]:
    """Faktor des Wegs gegenüber Standard und ob er nur grob geschätzt ist."""
    f, rough = 1.0, False
    if (p.get("quality") or "standard") == "dfr":
        f *= _DFR
    if p.get("end_image_asset_id") or p.get("loop"):
        f *= _ENDS
    if p.get("temporal_upscale"):
        f *= _TEMPORAL
    if p.get("guide_asset_id"):
        f, rough = f * _LAYOUT, True
    if p.get("extend_asset_id"):
        f, rough = f * _EXTEND, True
    return f, rough


def _image_factor(p: dict[str, Any]) -> float:
    f = 1.0
    if p.get("hires"):
        f *= 1.5          # ~50 % mehr Zeit (CLAUDE.md, Schalter)
    if p.get("reference_asset_ids"):
        f *= 1.5          # FLUX 3 mit Referenz ~45 s statt ~30 s
    if p.get("outpaint") and any(p.get("outpaint") or []):
        f *= 2.0          # zwei Durchgänge mit Ausrichten
    return f


def _units(kind: str, p: dict[str, Any]) -> float | None:
    """Wie viele Einheiten ein Auftrag umfasst: Bilder × MP, Clip-Sekunden × MP × Weg, Ton-Sekunden, Sätze."""
    if kind == "txt2img":
        mp = _mp(p) or 1.0
        return max(1, int(p.get("batch_size") or 1)) * mp * _image_factor(p)
    if kind == "txt2video":
        mp = _mp(p) or 0.9
        return _clip_seconds(p) * mp * _video_factor(p)[0]
    if kind == "txt2audio":
        return float(p.get("seconds") or 10.0)
    if kind == "tts":
        return 1.0
    if kind in ("img23d", "restore", "video_upscale", "expand_prompt"):
        return 1.0
    return None


def _signature(kind: str, p: dict[str, Any]) -> tuple[Any, ...]:
    """Läufe gelten nur mit derselben Signatur als vergleichbar (Weg, Schalter)."""
    # Schritte und LoRAs gehören dazu: Eine Turbo-LoRA mit 4 statt 50 Schritten (Qwen-Image) drückte die Schätzung an
    # der Installation auf ein Drittel (63 statt ~200 s, 26.11.2026)
    if kind == "txt2video":
        return ((p.get("quality") or "standard"), bool(p.get("end_image_asset_id") or p.get("loop")),
                bool(p.get("guide_asset_id")), bool(p.get("extend_asset_id")), bool(p.get("temporal_upscale")),
                int(p.get("steps") or 0), bool(p.get("loras")))
    if kind == "txt2img":
        return (bool(p.get("hires")), bool(p.get("reference_asset_ids")), bool(p.get("mask_asset_id")),
                bool(p.get("outpaint") and any(p.get("outpaint") or [])), int(p.get("steps") or 0),
                bool(p.get("loras")))
    if kind == "restore":
        return (bool(p.get("colorize")), bool(p.get("sharpen")), bool(p.get("repair", True)))
    return ()


def _history(kind: str, model_id: str, p: dict[str, Any]) -> tuple[float | None, int]:
    """Median Sekunden je Einheit aus den letzten vergleichbaren Läufen (mindestens zwei)."""
    sig = _signature(kind, p)
    mp = _mp(p)
    samples: list[float] = []
    for _k, params, started, finished in db.recent_done_jobs(kind, 300):
        if (params.get("model_id") or "") != model_id or not started or not finished:
            continue
        if _signature(kind, params) != sig:
            continue
        if mp and _mp(params) and not 0.5 <= _mp(params) / mp <= 2.0:
            continue  # zu andere Größe: die Zeit wächst nicht ganz linear
        n = _units(kind, params)
        if n:
            samples.append((finished - started) / n)
        if len(samples) >= 12:
            break
    return (statistics.median(samples), len(samples)) if len(samples) >= 2 else (None, len(samples))


def _reference(kind: str, entry: dict[str, Any], info: Any, p: dict[str, Any], prof: dict[str, Any]
               ) -> tuple[float | None, str]:
    """Sekunden aus der Referenzmessung, auf diese Karte umgerechnet."""
    if prof.get("cpu_mode"):
        return None, "unknown"  # auf dem Prozessor gilt keine Zeit der Referenzkarte
    sp = prof.get("speed")
    source = "estimate" if sp else "rough"
    sp = sp or 1.0
    if kind == "expand_prompt":
        return EXPAND_S / sp, source
    if kind == "restore":
        extra = RESTORE_EXTRA_S if (p.get("colorize") or p.get("sharpen")) else 0.0
        return (RESTORE_S + extra) / sp, source
    ref = MODEL_REF.get(entry["id"]) or MODEL_REF.get(entry.get("family") or "")
    if not ref:
        return None, "unknown"
    seconds, task = ref
    size = _TASK.get(task, {})
    if kind == "txt2img":
        scale = (_mp(p) or size.get("mp", 1.0)) / size.get("mp", 1.0)
        seconds *= max(1, int(p.get("batch_size") or 1)) * scale * _image_factor(p)
    elif kind == "txt2video":
        scale = (_mp(p) or size.get("mp", 1.0)) / size.get("mp", 1.0)
        f, rough = _video_factor(p)
        seconds *= _clip_seconds(p) / size.get("secs", 5.0) * scale * f
        if rough:
            source = "rough"
    elif kind == "txt2audio":
        seconds *= float(p.get("seconds") or 10.0) / size.get("secs", 10.0)
    elif kind == "video_upscale":
        seconds *= 1.0  # Eingang unbekannt: die Referenz (5 s, 1024 × 576)
        source = "rough"
    if info is not None and getattr(info, "fits_vram", "") == "nein" and (prof.get("vram_gb") or 99) < REF_VRAM_GB - 0.5:
        seconds *= 1.5  # passt nicht ganz in den Grafikspeicher, wird je Schritt nachgeladen (hardware.estimates)
    return seconds / sp, source


def _cold(kind: str, entry: dict[str, Any] | None, comfy_up: bool) -> dict[str, float]:
    """Was vor dem Rechnen noch anfällt: GPU-Backend starten, Modell laden (nur grob)."""
    out: dict[str, float] = {}
    if kind in ("txt2img", "txt2video", "txt2audio", "restore", "video_upscale", "expand_prompt"):
        if not comfy_up:
            out["start"] = BACKEND_START_S
        if entry is not None and comfy.loaded_model() != entry.get("name"):
            size = float(entry.get("vram_gb") or entry.get("size_gb") or 0)
            if size:
                out["load"] = round(min(150.0, max(10.0, size / LOAD_GB_PER_S)), 1)
    elif kind == "tts":
        out["load"] = VOICE_LOAD_S if comfy.loaded_model() != (entry or {}).get("name") else 0.0
    elif kind == "img23d":
        out["load"] = MESH_COLD_S
    return {k: v for k, v in out.items() if v}


def one(kind: str, params: dict[str, Any], comfy_up: bool, prof: dict[str, Any] | None = None) -> dict[str, Any]:
    """Schätzung für einen Auftrag, wie ihn /api/generate/* bekäme. Antwort: seconds (Rechenzeit, None = unbekannt),
    source, runs (eigene Läufe in der Schätzung), cold (Sekunden für Start und Laden, nur wenn sie anfallen)."""
    p = params or {}
    prof = prof or hardware.profile()
    kind_of_model = {"txt2img": "image", "txt2video": "video", "txt2audio": "audio", "tts": "speech",
                     "img23d": "3d"}.get(kind)
    model_id = p.get("model_id") or (registry.get_active_model(kind_of_model) if kind_of_model else None) or ""
    entry = registry.get_entry(model_id) if model_id else None
    seconds: float | None = None
    source, runs = "unknown", 0
    units = _units(kind, p)
    if model_id and units:
        per, runs = _history(kind, model_id, p)
        if per is not None:
            seconds, source = per * units, "history"
    if seconds is None and (entry is not None or kind in ("restore", "expand_prompt")):
        seconds, source = _reference(kind, entry or {"id": "", "family": ""}, _models().get(model_id), p, prof)
    cold = _cold(kind, entry, comfy_up)
    return {"seconds": round(seconds, 1) if seconds is not None else None, "source": source, "runs": runs,
            "cold": cold, "model_id": model_id or None}


def many(items: list[dict[str, Any]], comfy_up: bool) -> list[dict[str, Any]]:
    """Mehrere Schätzungen auf einmal (Knöpfe einer Seite), jede so, als liefe sie jetzt allein: Ob Start und Laden
    bei einer Folge mehrmals anfallen, entscheidet die Oberfläche."""
    prof = hardware.profile()
    out = []
    for it in items[:64]:
        kind = str(it.get("kind") or "")
        params = it.get("params") if isinstance(it.get("params"), dict) else {}
        try:
            out.append(one(kind, params, comfy_up, prof))
        except Exception as exc:  # noqa: BLE001 - eine Schätzung darf die anderen nicht mitnehmen
            out.append({"seconds": None, "source": "unknown", "runs": 0, "cold": {}, "error": str(exc)})
    return out
