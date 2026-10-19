"""Reine Entscheidungslogik eines Auftrags – ohne PhotoCraft, ohne Netz, ohne Dateien.

Hier steht alles, was aus Modus, Prompt, Einstellungen und den Modellangaben von NV-AI
(``/api/models`` mit ``features``, BILDMODELLE.md Abschnitt 7) folgt: welches Modell, welche
Technik, welche Arbeitsgröße, welcher Request an ``/api/generate/image``. Der Swift-Port
(PhotoCraftKit) bildet genau diese Funktionen nach und prüft sich gegen ``golden/planning.json``.

Warnungen tragen einen festen ``code`` (für Programme und Tests) und einen deutschen Text.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from . import imaging
from .i18n import t

MODES = ("fill", "generate", "refine")


def mode_label(mode: str) -> str:
    """Name des Modus in der gewählten Sprache (Oberfläche, Ebenenname)."""
    return {"fill": t("Füllen", "Fill"), "generate": t("Generieren", "Generate"),
            "refine": t("Überarbeiten", "Refine")}.get(mode, mode)


# Leerer Prompt bei „Füllen“: die Umgebung fortsetzen, wie Photoshops Generative Fill ohne Text.
# Kein Wort wie „background“: Mit „clean, natural background“ komponierte Qwen beim Erweitern
# ein Porträt vor unscharfem Hintergrund (gemessen).
DEFAULT_FILL_PROMPT = (
    "The same scene continues seamlessly. Identical subject matter, lighting, colors, texture, "
    "perspective and photographic style as the visible part of the image."
)
DEFAULT_FILL_NEGATIVE = ("text, watermark, frame, border, collage, split image, new object, "
                         "person, face, portrait, close-up")

# Maskenrand je Modus, in Pixeln der Arbeitsgröße (~1024 px).
MASK_GROW = {"fill": 12, "refine": 4}
MASK_BLUR = {"fill": 10.0, "refine": 8.0}
# Erweitern (transparente Ränder): breiterer, weicherer Übergang, damit das Modell die Naht
# zwischen Bestand und neuer Fläche mitrechnet.
OUTPAINT_GROW, OUTPAINT_BLUR = 24, 20.0
# … und viel Kontext: Nimmt die leere Fläche mehr als rund ein Drittel des Ausschnitts ein,
# komponiert das Modell frei statt fortzusetzen (gemessen: 52 % → fremdes Motiv).
OUTPAINT_MARGIN = 1.0
# Rand um die Auswahl beim Überarbeiten (Dokumentpixel), damit der weiche Maskenrand nicht am
# Bildrand des Ausschnitts abgeschnitten wird.
REFINE_PAD = 16

# Schritte je Workflow, wenn nichts eingetragen ist. Qwen-Image (voll) rechnet ab Werk 50
# Schritte (~100 s je Megapixel); 28 liefern beim Füllen gleichwertige Ergebnisse in gut der
# halben Zeit.
INTERACTIVE_STEPS = {"qwen_image": 28}
# Destillierte Modelle mit cfg 1: Der Prompt drückt kaum gegen den Bildkontext, eine Füllung
# setzt deshalb meist nur die Umgebung fort (gemessen: Gummiente erscheint erst mit cfg 4).
WEAK_PROMPT_WORKFLOWS = {"qwen_image_lightning", "flux"}
# „Native Auflösung“: Qwen ist auf ~1,76 MP trainiert (1328²), FLUX 3 bringt bei 1440² messbar
# mehr Detail (BILDMODELLE.md). Kostet etwa die doppelte Zeit.
NATIVE_PIXELS = {
    "qwen_image": 1328 * 1328, "qwen_image_lightning": 1328 * 1328,
    "flux3_klein": 1440 * 1440, "flux3_klein_base": 1440 * 1440,
}
# Modelle mit festem Format (``features.fixed_size``, etwa Core ML in NV-AI für Mac) rechnen immer
# N×N und strecken das Ergebnis sonst selbst auf die angefragte Größe – verzerrt. Deshalb N×N
# anfragen: Generieren beschneidet dann mittig, Füllen und Überarbeiten skalieren exakt zurück.
# Weicht der Ausschnitt um mehr als diesen Faktor vom Quadrat ab, sagt eine Warnung, was passiert.
FIXED_SIZE_TOLERANCE = 1.1


class PlanError(ValueError):
    """Der Auftrag lässt sich so nicht rechnen (Text für den Nutzer)."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


@dataclass
class Warning:
    code: str
    message: str


@dataclass
class Plan:
    model_id: str | None
    model_name: str
    workflow: str | None
    technique: str  # txt2img | img2img | inpaint | reference
    working: tuple[int, int]
    payload: dict[str, Any]  # ohne die Asset-IDs, die erst beim Hochladen entstehen
    send_image: bool  # Ausschnitt hochladen (als image_asset_id bzw. Referenz)
    send_mask: bool
    mask_grow: int
    mask_blur: float
    warnings: list[Warning] = field(default_factory=list)


# ------------------------------------------------------------------ Modelle

def capable(model: dict[str, Any], need: str, masks_supported: bool) -> bool:
    """Kann ``model`` Bild-zu-Bild (``img2img``), Bilder überarbeiten (``refine``: Bild-zu-Bild
    oder Bearbeiten per Referenzbild wie FLUX 3) bzw. Masken (``mask``)?

    Grundlage ist ``features``. Ältere NV-AI-Versionen liefern es nicht – dann gilt
    Bild-zu-Bild als vorhanden. Masken wirken dort, wo Bild-zu-Bild wirkt, sobald der Server
    ``mask_asset_id`` kennt – es sei denn, das Modell meldet ``mask`` ausdrücklich.
    """
    features = model.get("features") or {}
    img2img = bool(features.get("img2img", True))
    if need == "img2img":
        return img2img
    if need == "refine":
        return img2img or int(features.get("references") or 0) > 0
    if need == "mask":
        return bool(features.get("mask", img2img and masks_supported))
    raise ValueError(f"unbekannte Fähigkeit: {need}")


def need_for(mode: str) -> str | None:
    return {"fill": "mask", "refine": "refine"}.get(mode)


def choose_model(mode: str, wanted: str | None, active: str | None, models: list[dict[str, Any]],
                 masks_supported: bool) -> tuple[dict[str, Any], Warning | None]:
    """Modell für den Auftrag. Passt das aktive nicht zum Modus, wird ein passendes gewählt
    (volle Modelle vor Lightning) und als Warnung vermerkt."""
    runnable = [m for m in models if m.get("runnable", True)]
    need = need_for(mode)
    by_id = {m["id"]: m for m in runnable}
    chosen = by_id.get(wanted or active or "")
    if chosen and (need is None or capable(chosen, need, masks_supported)):
        return chosen, None
    what = (t("keine Masken", "masks") if need == "mask" else t("keine Bilder überarbeiten", "image editing"))
    if wanted and chosen:
        raise PlanError("model_incapable", t(f"„{chosen['name']}“ kann {what} – bitte ein anderes Modell wählen.",
                                             f"\"{chosen['name']}\" does not support {what} – please choose another model."))
    candidates = [m for m in runnable if need is None or capable(m, need, masks_supported)]
    if not candidates:
        reason = {"mask": t("mit Masken arbeiten.", "work with masks."),
                  "refine": t("Bilder überarbeiten.", "edit images.")}.get(need, t("laufen.", "run."))
        raise PlanError("no_capable_model", t("Kein installiertes Bildmodell in NV-AI kann ",
                                              "No image model installed in NV-AI can ") + reason)
    # Stabil sortiert: Reihenfolge von NV-AI, schwache (Lightning/schnell) nach hinten.
    pick = sorted(candidates, key=lambda m: m.get("workflow") in WEAK_PROMPT_WORKFLOWS)[0]
    if wanted:
        code, reason = "model_unavailable", t("Das gewählte Modell ist in NV-AI nicht verfügbar",
                                              "The chosen model is not available in NV-AI")
    elif chosen:
        code, reason = "active_model_incapable", t(f"Das in NV-AI aktive Modell kann {what}",
                                                   f"The model active in NV-AI does not support {what}")
    else:
        code, reason = "no_active_model", t("In NV-AI ist kein Bildmodell aktiv", "No image model is active in NV-AI")
    return pick, Warning(code, t(f"{reason} – verwendet wird „{pick['name']}“.", f"{reason} – using \"{pick['name']}\"."))


def fixed_size(model: dict[str, Any]) -> int | None:
    """Festes quadratisches Format des Modells in Pixeln (``features.fixed_size``) – oder None."""
    value = (model.get("features") or {}).get("fixed_size")
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if isinstance(value, float) and not value.is_integer():
        return None
    return int(value) if value > 0 else None


def technique_for(mode: str, model: dict[str, Any], has_mask: bool, masks_supported: bool) -> str:
    """Wie NV-AI den Auftrag rechnet."""
    if mode == "generate":
        return "txt2img"
    if mode == "fill":
        return "inpaint"
    features = model.get("features") or {}
    if not features.get("img2img", True) and int(features.get("references") or 0) > 0:
        return "reference"
    # Überarbeiten per Bild-zu-Bild: Kennt NV-AI Masken, hält die Maske alles außerhalb der
    # Auswahl fest; sonst begrenzt nur die Ebenenmaske in PhotoCraft das Ergebnis.
    return "inpaint" if has_mask and capable(model, "mask", masks_supported) else "img2img"


# --------------------------------------------------------------- Ausschnitt

def region_for(mode: str, selection: imaging.Rect | None, width: int, height: int,
               margin: float = 0.35) -> imaging.Rect:
    """Dokumentausschnitt, den das Modell zu sehen bekommt (vor dem Export)."""
    canvas = imaging.Rect(0, 0, width, height)
    if selection is None:
        return canvas
    if mode == "fill":
        return imaging.context_region(selection, width, height, margin)
    if mode == "refine":
        return imaging.grow_rect(selection, REFINE_PAD, width, height)
    return selection


def outpaint_region(transparent: imaging.Rect, width: int, height: int, margin: float = 0.35) -> imaging.Rect:
    """Ausschnitt für „Füllen“ ohne Auswahl: transparente Fläche plus reichlich Kontext."""
    return imaging.context_region(transparent, width, height, max(margin, OUTPAINT_MARGIN))


# ------------------------------------------------------------------ Request

def plan(mode: str, prompt: str, params: dict[str, Any], model: dict[str, Any] | None,
         region_size: tuple[int, int], has_mask: bool, alpha_mask: bool,
         masks_supported: bool) -> Plan:
    """Den Request an ``/api/generate/image`` planen (ohne Asset-IDs)."""
    model = model or {}
    features = model.get("features") or {}
    workflow = model.get("workflow")
    prompt = (prompt or "").strip()
    technique = technique_for(mode, model, has_mask, masks_supported)
    warnings: list[Warning] = []

    fixed = fixed_size(model)
    if fixed:
        gw = gh = fixed
        w, h = region_size
        if max(w, h) > FIXED_SIZE_TOLERANCE * min(w, h):
            name = model.get("name") or t("Das Modell", "The model")
            effect = (t("Das Bild wird auf das Format der Auswahl zugeschnitten.",
                        "The image is cropped to the shape of the selection.") if mode == "generate"
                      else t("Der Ausschnitt wird dafür gestaucht, Formen können leicht verzerrt wirken.",
                             "The area is squeezed for it, shapes may look slightly distorted."))
            warnings.append(Warning("fixed_size", t(f"„{name}“ rechnet nur im Format {fixed} × {fixed}. {effect}",
                                                    f"\"{name}\" only works at {fixed} × {fixed}. {effect}")))
    else:
        target = NATIVE_PIXELS.get(workflow, imaging.TARGET_PIXELS) if params.get("native") else imaging.TARGET_PIXELS
        gw, gh = imaging.working_size(region_size[0], region_size[1], target)

    if mode == "generate" and not prompt:
        raise PlanError("prompt_required", t("Zum Generieren bitte beschreiben, was entstehen soll.",
                                             "To generate, please describe what should be created."))
    if technique == "reference" and not prompt:
        raise PlanError("prompt_required", t("Für die Bearbeitung mit FLUX 3 bitte beschreiben, was sich "
                                             "ändern soll – und was gleich bleibt.",
                                             "For editing with FLUX 3, please describe what should change – "
                                             "and what stays the same."))

    payload: dict[str, Any] = {
        "prompt": prompt,
        "negative_prompt": (params.get("negative_prompt") or "").strip(),
        "batch_size": max(1, min(4, int(params.get("variants") or 1))),
        "width": gw,
        "height": gh,
    }
    if model.get("id"):
        payload["model_id"] = model["id"]
    for key in ("steps", "cfg", "seed"):
        if params.get(key) not in (None, ""):
            payload[key] = params[key]
    if "steps" not in payload and workflow in INTERACTIVE_STEPS:
        payload["steps"] = INTERACTIVE_STEPS[workflow]
    if params.get("hires") and features.get("hires", True):
        payload["hires"] = True

    if mode == "fill" and not prompt:
        payload["prompt"] = DEFAULT_FILL_PROMPT
        if not payload["negative_prompt"]:
            # Den Standard-Negativprompt des Modells (Qwen: aus seiner Modellkarte) behalten und
            # nur um das ergänzen, was eine Hintergrund-Füllung zusätzlich stört.
            base = features.get("default_negative") or ""
            payload["negative_prompt"] = f"{base} {DEFAULT_FILL_NEGATIVE}".strip()
    if mode == "fill" and prompt and workflow in WEAK_PROMPT_WORKFLOWS:
        warnings.append(Warning("weak_prompt_fill", t(
            "Schnelle Modelle (Lightning/schnell) setzen beim Füllen meist nur die Umgebung fort. Für neue "
            "Objekte das volle Modell wählen.",
            "Fast models (Lightning/schnell) mostly just continue the surroundings when filling. For new "
            "objects, choose the full model.")))

    send_image = mode in ("fill", "refine")
    if send_image and technique != "reference":
        payload["denoise"] = 1.0 if mode == "fill" else float(params.get("strength") or 0.5)
    send_mask = has_mask and technique == "inpaint"
    grow, blur = (OUTPAINT_GROW, OUTPAINT_BLUR) if alpha_mask else (MASK_GROW.get(mode, 0), MASK_BLUR.get(mode, 0.0))

    return Plan(model_id=model.get("id"), model_name=model.get("name") or "", workflow=workflow,
                technique=technique, working=(gw, gh), payload=payload, send_image=send_image,
                send_mask=send_mask, mask_grow=grow if send_mask else 0,
                mask_blur=blur if send_mask else 0.0, warnings=warnings)


def layer_name(mode: str, prompt: str, k: int, n_variants: int) -> str:
    """Name der eingefügten Ebene, etwa „NV-AI Fill: a red barn (2)“ (Deutsch: „NV-AI Füllen: …“)."""
    text = " ".join((prompt or "").split())
    if len(text) > 48:
        text = text[:47].rstrip() + "…"
    name = f"NV-AI {mode_label(mode)}" + (f": {text}" if text else "")
    return name + (f" ({k + 1})" if n_variants > 1 else "")
