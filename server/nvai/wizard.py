"""Assistent im Studio (seit 0.5.28; Nutzer 14.11.2026: „es soll auch anhand meiner hardware mir die modelle
vorschlagen, mit warscheinlicher berechnungszeit, und eher die top modelle vorschlagen, auch wenn die langsamer
laufen, quallität zählt“).

- **Modelle:** je Aufgabe (Bild, Video, Stimme, Musik) die beste Fassung, die der Server für diese Karte empfiehlt
  (NVFP4 auf RTX 50, INT8 auf älteren, AMD-Fassungen auf Radeon), auch wenn sie langsamer ist. Daneben stehen die
  anderen Modelle, die den Ablauf tragen, zur Wahl (Nutzer 14.11.: „der assistent soll auch model auswählen lassen,
  aber der beste ist vorgewählt, und wenn kein noch da anfragen zum herunterladen“); fehlende lädt die Oberfläche
  nach Rückfrage über den normalen Download.
- **Zeiten:** zuerst aus eigenen Läufen auf diesem Rechner (Median, je Bild, je Clip-Sekunde, je Satz), sonst aus
  Referenzmessungen auf einer RTX 5060 Ti 16 GB geteilt durch die geschätzte Geschwindigkeit der Karte
  (Hardware-Katalog, hardware.py). Reicht der Grafikspeicher nicht (gpu.fits „nein“) und ist er kleiner als bei der
  Referenz, lädt ComfyUI je Schritt nach: grob anderthalbmal so lang (an PCIe 4.0 x8 kaum langsamer, am langsamen
  Anschluss deutlich).
"""
from __future__ import annotations

import re
import statistics
from typing import Any

from . import db, hardware, registry, workflows
from .hardware import MODEL_REF, REF_VRAM_GB

# Gemessen auf RTX 5060 Ti 16 GB (NVFP4-Fassungen), Sekunden; Quellen: Datenbank der Installation 13.11.2026
# (Suomi-Kurzfilm), notizen/laufzeiten.md
REF = {
    "character": 22.0,        # FLUX 3 Klein: 2 Entwürfe in rund 1 MP aus Text (21,4–21,9 s je Auftrag)
    "character_ref": 48.0,    # dasselbe mit einer Vorlage als Referenzbild (47–49 s)
    "start_image": 77.0,      # FLUX 3 Klein mit Referenz: 2 Bilder 1920 × 1088 (74–80 s)
    "video_standard": 52.0,   # LTX-2.5 1920 × 1088 Standard, je Clip-Sekunde (4 s: 163–181 s, 6 s: 272–336 s)
    "video_dfr": 157.0,       # LTX-2.5 1920 × 1088 DFR, je Clip-Sekunde (5 s: 786 s)
    "video_720": 21.0,        # LTX-2.5 1280 × 704 Standard mit Startbild, je Clip-Sekunde (5 s: 93–109 s)
    "voice_line": 7.0,        # Qwen3-TTS 1.7B je Satz, warm
    "voice_load": 45.0,       # erster Satz nach dem Start: Modell laden
    "music": 10.0,            # Stable Audio 3 Medium, 60 s Musik (8–11 s)
    "export": 0.8,            # Studio-Export YouTube 1080p je Sekunde Film (30 s in 24 s), Video-Encoder der Karte
}
# Je Aufgabe: Art im Katalog und die Familien zur Wahl, die beste zuerst (an ihr sind die Zeiten in REF gemessen).
# Bild: die vier empfohlenen Modelle, sie verstehen Prompts in ganzen englischen Sätzen (CLIP-Familien nicht, Qwen-Image
# 2.1 ist nicht kommerziell). Video: dazu jedes andere Modell, das ein Startbild nimmt (jede Szene bekommt eins).
ROLES = {
    "image": ("image", ("flux3", "qwenimage", "krea2", "moss_image")),
    "video": ("video", ("ltx25",)),
    "speech": ("speech", ("qwen3_tts",)),
    "music": ("audio", ("stable_audio3",)),
}
# Base-Fassung von FLUX 3 (brachte nichts) und Qwens Lightning-Fassung (nur für Entwürfe)
SKIP = ("flux3-klein-base", "qwen-image-2512-lightning")
# Videomodelle, die den Ton mit dem Bild erzeugen
SOUND_FAMILIES = {"ltx25", "ltx23", "kandinsky6"}
# Fassungen desselben Modells (NVFP4, INT8 …) stehen nur einmal zur Wahl
_QUANT = re.compile(r"-(nvfp4|int8|fp8|bf16|fp16)$")


def _fits(role: str, m: Any, feats: dict[str, Any], refs: bool) -> bool:
    """Trägt das Modell den Ablauf des Assistenten? `refs`: Die Startbilder entstehen aus einem Entwurf oder Porträt
    als Referenzbild (mit Figur)."""
    kind, families = ROLES[role]
    # Harte Lizenzgrenze (MiniMax: ganze Länder ausgeschlossen, auch die EU) gehört nicht in einen Assistenten
    if m.kind != kind or m.id.startswith(SKIP) or m.license_badge:
        return False
    if role == "video":
        return (m.workflow in workflows.I2V_WORKFLOWS | workflows.OPTIONAL_START_WORKFLOWS
                or bool(feats.get("start_image")))
    if m.family not in families:
        return False
    if role == "image" and refs:
        # Krea 2 nimmt Referenzen nur als Stilvorlage, eine Figur hält es damit nicht
        return int(feats.get("references") or 0) > 0 and feats.get("reference_kind") != "style"
    return True


def _option(m: Any, feats: dict[str, Any]) -> dict[str, Any]:
    gated = [] if m.installed else [r for r in m.gated_repos if m.gated_access.get(r) != "granted"]
    return {"id": m.id, "name": m.name, "family": m.family, "installed": bool(m.installed),
            "runnable": bool(m.runnable), "partial": bool(m.partially_installed), "recommended": bool(m.recommended),
            "size_gb": m.size_gb, "vram_gb": m.vram_gb, "fits_vram": m.fits_vram, "dfr": bool(feats.get("dfr")),
            "commercial_ok": bool(m.commercial_ok), "license": m.license, "sound": m.family in SOUND_FAMILIES,
            "lipsync": bool(feats.get("audio_input")), "loop": bool(feats.get("loop")), "gated": gated}


def options(role: str, refs: bool = False) -> list[dict[str, Any]]:
    """Was der Assistent für eine Aufgabe zur Wahl stellt, die beste Familie zuerst (sie ist vorgewählt). Je Modell eine
    Fassung: die für diese Karte empfohlene, wenn sie geladen ist, sonst eine geladene (die läuft gleich, statt einen
    zweiten Download zu verlangen), sonst die empfohlene, sonst die erste. Qualität vor Tempo: Die beste Familie bleibt
    vorn, auch wenn sie fehlt und eine andere geladen ist."""
    kind, families = ROLES[role]
    groups: dict[str, list[Any]] = {}
    feats: dict[str, dict[str, Any]] = {}
    for m in registry.list_models(kind):
        entry = registry.get_entry(m.id) or {}
        f = registry.features_for(entry) if entry else {}
        if _fits(role, m, f, refs):
            groups.setdefault(_QUANT.sub("", m.id), []).append(m)
            feats[m.id] = f
    out = []
    for cands in groups.values():
        m = (next((x for x in cands if x.recommended and x.installed), None)
             or next((x for x in cands if x.installed), None)
             or next((x for x in cands if x.recommended), None) or cands[0])
        out.append(_option(m, feats[m.id]))
    rank = {f: i for i, f in enumerate(families)}
    out.sort(key=lambda o: rank.get(o["family"], len(families)))  # stabil: sonst Reihenfolge des Katalogs
    return out


def _factor(role: str, model: dict[str, Any] | None) -> float | None:
    """Wie lange dieses Modell gegenüber der Familie braucht, an der REF gemessen ist (1.0 für sie selbst); None = keine
    Schätzung. Bildmodelle grob aus den Referenzzeiten je Modell (alle um 1 MP mit ihren Standardschritten gemessen).
    Andere Videomodelle bekommen keine Zahl: Ihre Messungen liefen in anderer Größe und teils mit Schritt-LoRA (Wan 2.2
    mit 390 s, ohne 3280 s je 5 s), daraus wäre die Zeit im Assistenten geraten."""
    if not model:
        return None
    best_family = ROLES[role][1][0]
    if model["family"] == best_family:
        return 1.0
    if role != "image":
        return None
    own = MODEL_REF.get(model["id"]) or MODEL_REF.get(model["family"])
    base = MODEL_REF.get(best_family)
    return own[0] / base[0] if own and base else None


def _history(model_id: str, kind: str, unit) -> tuple[float | None, int]:
    """Median der letzten Läufe dieses Modells auf diesem Rechner, je Einheit (`unit(params) -> Anzahl` oder None,
    wenn der Lauf nicht vergleichbar ist)."""
    samples = []
    for k, params, started, finished in db.recent_done_jobs(kind, 400):
        if params.get("model_id") != model_id or not started or not finished:
            continue
        n = unit(params)
        if n:
            samples.append((finished - started) / n)
        if len(samples) >= 20:
            break
    return (statistics.median(samples), len(samples)) if len(samples) >= 2 else (None, len(samples))


def _mp(p: dict[str, Any]) -> float:
    return float(p.get("width") or 0) * float(p.get("height") or 0) / 1e6


def plan(req: dict[str, Any]) -> dict[str, Any]:
    """Modelle, Bildgröße, Qualität und geschätzte Rechenzeit für ein Vorhaben des Assistenten.
    req: format ('landscape'|'portrait'), quality ('best'|'fast'), character (bool: Entwürfe kommen noch),
    character_ref (bool), cast (bool: Startbilder mit Figur oder Porträt als Referenz), start_images (Anzahl),
    video_seconds (Summe), voice_lines (Anzahl), music (bool), models ({Aufgabe: Modell-ID}, eigene Wahl; was nicht
    passt, fällt auf die beste zurück). Antwort: models (gewählt), options (zur Wahl), best (vorgewählt)."""
    prof = hardware.profile()
    refs = bool(req.get("cast") or req.get("character") or req.get("character_ref"))
    wanted = req.get("models") if isinstance(req.get("models"), dict) else {}
    opts = {role: options(role, refs) for role in ROLES}
    models = {role: next((o for o in lst if o["id"] == wanted.get(role)), None) or (lst[0] if lst else None)
              for role, lst in opts.items()}
    sp = prof["speed"] or 1.0
    vram = prof["vram_gb"] or 0
    tier = "1080p" if vram >= 15 or not prof["name"] else "720p"
    portrait = req.get("format") == "portrait"
    w, h = (1920, 1088) if tier == "1080p" else (1280, 704)
    if portrait:
        w, h = h, w
    video = models.get("video") or {}
    quality = "dfr" if req.get("quality", "best") == "best" and tier == "1080p" and video.get("dfr") else "standard"
    notes: list[str] = []
    # Nachladen kostet nur gegenüber der Referenz Zeit: dort ist es in den Messwerten schon enthalten (LTX-2.5 meldet auch
    # auf 16 GB „nein“ und wurde so gemessen)
    smaller = bool(prof["vram_gb"]) and prof["vram_gb"] < REF_VRAM_GB - 0.5
    if video and video.get("fits_vram") == "nein" and smaller:
        notes.append("vram_video")
    if not prof["catalog_id"] and prof["name"]:
        notes.append("unknown_gpu")
    if prof["vendor"] == "amd":
        notes.append("amd_rough")

    def est(ref_key: str, n: float, role: str, hist_kind: str | None = None, unit=None):
        """Sekunden, Quelle (history, estimate, rough = aus einem anderen Modell hochgerechnet, unknown), Läufe"""
        model = models.get(role)
        own, count = (_history(model["id"], hist_kind, unit) if model and hist_kind and unit else (None, 0))
        if own is not None:
            return own * n, "history", count
        f = _factor(role, model)
        if f is None:
            return None, "unknown", 0
        base = REF[ref_key] * n / sp * f
        if model and model.get("fits_vram") == "nein" and smaller:
            base *= 1.5  # passt nicht ganz in den Grafikspeicher, wird je Schritt nachgeladen (gpu.fits)
        return base, ("estimate" if f == 1.0 else "rough"), 0

    steps = []

    def add(key: str, s: float | None, src: str, n: int) -> None:
        steps.append({"key": key, "seconds": round(s) if s is not None else None, "source": src, "runs": n})

    if req.get("character"):
        key = "character_ref" if req.get("character_ref") else "character"
        add("character", *est(key, 2, "image", "txt2img",
                              lambda p: (p.get("batch_size") or 1) / 2 if _mp(p) < 1.4 else None))
    if req.get("start_images"):
        add("start_images", *est("start_image", int(req["start_images"]), "image", "txt2img",
                                 lambda p: (p.get("batch_size") or 1) / 2 if _mp(p) > 1.8 else None))
    if req.get("voice_lines"):
        s, src, n = est("voice_line", int(req["voice_lines"]), "speech", "tts", lambda p: 1)
        if src == "estimate":
            s += REF["voice_load"] / sp
        add("voice", s, src, n)
    if req.get("music"):
        add("music", *est("music", 1, "music", "txt2audio", lambda p: 1))
    secs = float(req.get("video_seconds") or 0)
    if secs:
        key = {"dfr": "video_dfr", "standard": "video_standard"}[quality] if tier == "1080p" else "video_720"
        add("videos", *est(key, secs, "video", "txt2video",
                           lambda p: ((p.get("frames") or 0) / float(p.get("fps") or 24)) * (_mp(p) / (w * h / 1e6))
                           if (p.get("quality") or "standard") == quality and abs(_mp(p) - w * h / 1e6) < 0.4
                           else None))
        add("export", REF["export"] * secs, "estimate", 0)
    if any(x["seconds"] is None for x in steps):
        notes.append("time_unknown")
    return {"device": prof, "models": models, "options": opts,
            "best": {role: lst[0]["id"] if lst else None for role, lst in opts.items()},
            "width": w, "height": h, "tier": tier, "quality": quality, "steps": steps,
            "total_seconds": sum(x["seconds"] or 0 for x in steps), "notes": notes}
