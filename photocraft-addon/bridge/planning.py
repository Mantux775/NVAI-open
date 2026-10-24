"""Reine Entscheidungslogik eines Auftrags – ohne PhotoCraft, ohne Netz, ohne Dateien.

Hier steht alles, was aus Modus, Prompt, Einstellungen und den Modellangaben von NVAI-open
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

# Rechenwege; „Erweitern“ (extend) rechnet wie Füllen, siehe base_mode. Die Golden-Daten decken diese ab.
BASE_MODES = ("fill", "generate", "refine")
MODES = BASE_MODES + ("extend",)


def mode_label(mode: str) -> str:
    """Name des Modus in der gewählten Sprache (Oberfläche, Ebenenname)."""
    return {"fill": t("Füllen", "Fill"), "generate": t("Generieren", "Generate"),
            "refine": t("Überarbeiten", "Refine"), "extend": t("Erweitern", "Extend")}.get(mode, mode)


def base_mode(mode: str) -> str:
    """„Erweitern“ rechnet wie „Füllen“ ohne Auswahl, nur mit vergrößerter Arbeitsfläche davor."""
    return "fill" if mode == "extend" else mode


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
# Modelle mit festem Format (``features.fixed_size``, etwa Core ML in NVAI-open für Mac) rechnen immer
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

    Grundlage ist ``features``. Ältere NVAI-open-Versionen liefern es nicht – dann gilt
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
    if need == "outpaint":
        # NVAI-open ab 0.5.4 meldet "reference" (Bearbeitungsmodell, nahtlos) oder "mask".
        if "outpaint" in features:
            return bool(features["outpaint"])
        return capable(model, "mask", masks_supported)
    raise ValueError(f"unbekannte Fähigkeit: {need}")


def need_for(mode: str) -> str | None:
    return {"fill": "mask", "refine": "refine"}.get(mode)


def choose_model(mode: str, wanted: str | None, active: str | None, models: list[dict[str, Any]],
                 masks_supported: bool, extend: bool = False) -> tuple[dict[str, Any], Warning | None]:
    """Modell für den Auftrag. Passt das aktive nicht zum Modus, wird ein passendes gewählt
    (volle Modelle vor Lightning) und als Warnung vermerkt.

    ``extend``: Arbeitsfläche erweitern über NVAI-opens ``outpaint``. Ohne eigene Wahl nimmt das
    ein Bearbeitungsmodell (FLUX 3 & Co.), denn Maskenmodelle hinterließen an der alten
    Bildkante eine harte Naht (gemessen 23.10.2026). Füllen bevorzugt genauso ein Modell, das
    per Referenz füllt (``features.mask == "reference"``), wenn NVAI-open das meldet.
    """
    runnable = [m for m in models if m.get("runnable", True)]
    need = "outpaint" if extend and mode == "fill" else need_for(mode)
    if need == "outpaint" and not wanted:
        seamless = [m for m in runnable if (m.get("features") or {}).get("outpaint") == "reference"]
        if seamless:
            return next((m for m in seamless if m["id"] == active), seamless[0]), None
    if need == "mask" and not wanted:
        # Füllen: NVAI-open ab 0.5.6 füllt auch mit Bearbeitungsmodellen (features.mask "reference", FLUX 3):
        # Bereich grau, ausrichten, einsetzen. Gemessen: Kisten entfernt mit durchlaufendem Pflaster;
        # Qwens Maskenweg malte ein Schild frontal statt in der Perspektive der Kiste.
        by_reference = [m for m in runnable if (m.get("features") or {}).get("mask") == "reference"]
        if by_reference:
            return next((m for m in by_reference if m["id"] == active), by_reference[0]), None
    by_id = {m["id"]: m for m in runnable}
    chosen = by_id.get(wanted or active or "")
    if chosen and (need is None or capable(chosen, need, masks_supported)):
        return chosen, None
    what = (t("keine Masken", "masks") if need == "mask"
            else t("nicht erweitern", "extending") if need == "outpaint"
            else t("keine Bilder überarbeiten", "image editing"))
    if wanted and chosen:
        raise PlanError("model_incapable", t(f"„{chosen['name']}“ kann {what} – bitte ein anderes Modell wählen.",
                                             f"\"{chosen['name']}\" does not support {what} – please choose another model."))
    candidates = [m for m in runnable if need is None or capable(m, need, masks_supported)]
    if not candidates:
        reason = {"mask": t("mit Masken arbeiten.", "work with masks."),
                  "outpaint": t("Bilder erweitern.", "extend images."),
                  "refine": t("Bilder überarbeiten.", "edit images.")}.get(need, t("laufen.", "run."))
        raise PlanError("no_capable_model", t("Kein installiertes Bildmodell in NVAI-open kann ",
                                              "No image model installed in NVAI-open can ") + reason)
    # Stabil sortiert: Reihenfolge von NVAI-open, schwache (Lightning/schnell) nach hinten.
    pick = sorted(candidates, key=lambda m: m.get("workflow") in WEAK_PROMPT_WORKFLOWS)[0]
    if wanted:
        code, reason = "model_unavailable", t("Das gewählte Modell ist in NVAI-open nicht verfügbar",
                                              "The chosen model is not available in NVAI-open")
    elif chosen:
        code, reason = "active_model_incapable", t(f"Das in NVAI-open aktive Modell kann {what}",
                                                   f"The model active in NVAI-open does not support {what}")
    else:
        code, reason = "no_active_model", t("In NVAI-open ist kein Bildmodell aktiv", "No image model is active in NVAI-open")
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
    """Wie NVAI-open den Auftrag rechnet."""
    if mode == "generate":
        return "txt2img"
    if mode == "fill":
        return "inpaint"
    features = model.get("features") or {}
    if not features.get("img2img", True) and int(features.get("references") or 0) > 0:
        return "reference"
    # Überarbeiten per Bild-zu-Bild: Kennt NVAI-open Masken, hält die Maske alles außerhalb der
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


# Je Seite hoechstens so viel neue Arbeitsflaeche (Pixel) beim Erweitern.
EXTEND_MAX = 2048


def extend_steps(extend: list[int] | None) -> list[dict[str, Any]]:
    """Befehle `image.canvasSize`, die die Arbeitsfläche transparent erweitern.

    `extend` ist [links, oben, rechts, unten] in Pixeln. Je Seite ein relativer Schritt mit
    dem Anker auf der Gegenseite, damit das Bild dort bleibt; gleiche Ränder links und
    rechts (oben und unten) gehen in einem Schritt mit mittigem Anker.
    """
    left, top, right, bottom = (max(0, min(EXTEND_MAX, int(v))) for v in (extend or [0, 0, 0, 0]))
    steps: list[dict[str, Any]] = []

    def step(width: int, height: int, anchor: str) -> None:
        steps.append({"width": width, "height": height, "relative": True, "anchor": anchor,
                      "extensionColor": "transparent"})

    for a, b, dim, anchor_a, anchor_b in ((left, right, "w", "right", "left"),
                                          (top, bottom, "h", "bottom", "top")):
        size = (lambda n: (n, 0)) if dim == "w" else (lambda n: (0, n))
        if a and a == b:
            step(*size(a + b), "center")
            continue
        if a:
            step(*size(a), anchor_a)
        if b:
            step(*size(b), anchor_b)
    return steps


def outpaint_edges(context: Any, working: tuple[int, int]
                   ) -> tuple[tuple[int, int, int, int], tuple[int, int], list[int]] | None:
    """Für NVAI-opens ``outpaint``: deckender Teil des Ausschnitts und die Ränder drumherum.

    Gibt (Box im Ausschnitt, Größe des hochzuladenden Bildes, [links, oben, rechts, unten])
    zurück, Bild und Ränder schon auf die Arbeitsgröße skaliert; ``None``, wenn nichts
    durchsichtig ist oder nichts deckt.
    """
    if "A" not in context.getbands():
        return None
    box = context.getchannel("A").point(lambda v: 255 if v >= 250 else 0).getbbox()
    if box is None:
        return None
    w, h = context.size
    x0, y0, x1, y1 = box
    if (x0, y0, x1, y1) == (0, 0, w, h):
        return None
    sx, sy = working[0] / w, working[1] / h
    size = (max(1, round((x1 - x0) * sx)), max(1, round((y1 - y0) * sy)))
    edges = [round(x0 * sx), round(y0 * sy), round((w - x1) * sx), round((h - y1) * sy)]
    return box, size, [min(1024, e) for e in edges]


# ------------------------------------------------------------------ Request

def plan(mode: str, prompt: str, params: dict[str, Any], model: dict[str, Any] | None,
         region_size: tuple[int, int], has_mask: bool, alpha_mask: bool,
         masks_supported: bool, outpaint: bool = False) -> Plan:
    """Den Request an ``/api/generate/image`` planen (ohne Asset-IDs).

    ``outpaint``: Erweitern über NVAI-opens ``outpaint``-Feld (Technik „outpaint“); Rand, Maske
    und denoise setzt dann der Server.
    """
    model = model or {}
    features = model.get("features") or {}
    workflow = model.get("workflow")
    prompt = (prompt or "").strip()
    technique = ("outpaint" if outpaint and mode == "fill"
                 else technique_for(mode, model, has_mask, masks_supported))
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
    if send_image and technique not in ("reference", "outpaint"):
        payload["denoise"] = 1.0 if mode == "fill" else float(params.get("strength") or 0.5)
    send_mask = has_mask and technique == "inpaint"
    grow, blur = (OUTPAINT_GROW, OUTPAINT_BLUR) if alpha_mask else (MASK_GROW.get(mode, 0), MASK_BLUR.get(mode, 0.0))

    return Plan(model_id=model.get("id"), model_name=model.get("name") or "", workflow=workflow,
                technique=technique, working=(gw, gh), payload=payload, send_image=send_image,
                send_mask=send_mask, mask_grow=grow if send_mask else 0,
                mask_blur=blur if send_mask else 0.0, warnings=warnings)


def layer_name(mode: str, prompt: str, k: int, n_variants: int) -> str:
    """Name der eingefügten Ebene, etwa „NVAI-open Fill: a red barn (2)“ (Deutsch: „NVAI-open Füllen: …“)."""
    text = " ".join((prompt or "").split())
    if len(text) > 48:
        text = text[:47].rstrip() + "…"
    name = f"NVAI-open {mode_label(mode)}" + (f": {text}" if text else "")
    return name + (f" ({k + 1})" if n_variants > 1 else "")
