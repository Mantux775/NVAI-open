"""Bildgeometrie und -aufbereitung zwischen PhotoCraft-Dokument und NV-AI.

Bewusst ohne PhotoCraft- oder Netzwerkbezug, damit alles hier ohne laufende Programme
testbar bleibt (tests/test_imaging.py).
"""
from __future__ import annotations

import math
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageFilter, ImageOps, ImageStat

# Die eingesetzten Modelle (Qwen-Image, Chroma, FLUX …) sind auf rund 1 Megapixel trainiert.
# Deutlich größer wird das Bild unruhig, deutlich kleiner verschenkt Detail.
TARGET_PIXELS = 1024 * 1024
MIN_SIDE, MAX_SIDE = 256, 2048
# VAE (8×) mal Patch-Größe (2×) – Vielfache von 16 passen für alle Bildmodelle in NV-AI.
MULTIPLE = 16


@dataclass(frozen=True)
class Rect:
    x: int
    y: int
    w: int
    h: int

    @property
    def x1(self) -> int:
        return self.x + self.w

    @property
    def y1(self) -> int:
        return self.y + self.h

    def as_list(self) -> list[int]:
        return [self.x, self.y, self.w, self.h]

    @classmethod
    def from_list(cls, v: list[int] | tuple[int, ...]) -> Rect:
        return cls(int(v[0]), int(v[1]), int(v[2]), int(v[3]))

    def offset(self, dx: int, dy: int) -> Rect:
        return Rect(self.x + dx, self.y + dy, self.w, self.h)


def grow_rect(r: Rect, margin: int, width: int, height: int) -> Rect:
    """``r`` um ``margin`` Pixel nach allen Seiten erweitern, auf die Arbeitsfläche begrenzt."""
    x0, y0 = max(0, r.x - margin), max(0, r.y - margin)
    x1, y1 = min(width, r.x1 + margin), min(height, r.y1 + margin)
    return Rect(x0, y0, max(1, x1 - x0), max(1, y1 - y0))


def context_region(sel: Rect, width: int, height: int, margin_frac: float = 0.35,
                   min_margin: int = 32) -> Rect:
    """Auswahl plus Umgebung für „Füllen“.

    Das Modell sieht nur diesen Ausschnitt. Ohne genug Umgebung passt die Füllung nicht zu
    Licht, Perspektive und Textur; mit zu viel bekommt die Auswahl selbst zu wenige Pixel.
    """
    margin = max(min_margin, round(max(sel.w, sel.h) * margin_frac))
    return grow_rect(sel, margin, width, height)


def working_size(w: int, h: int, target: int = TARGET_PIXELS) -> tuple[int, int]:
    """Arbeitsgröße fürs Modell: gleiche Proportion, rund ``target`` Pixel, Vielfache von 16."""
    if w <= 0 or h <= 0:
        raise ValueError(f"ungültige Größe {w}×{h}")
    s = math.sqrt(target / (w * h))
    gw, gh = w * s, h * s
    # Extrem schmale Formate: die lange Seite deckeln, die kurze anheben.
    if max(gw, gh) > MAX_SIDE:
        f = MAX_SIDE / max(gw, gh)
        gw, gh = gw * f, gh * f
    if min(gw, gh) < MIN_SIDE:
        f = MIN_SIDE / min(gw, gh)
        gw, gh = gw * f, gh * f

    def snap(v: float) -> int:
        return int(min(MAX_SIDE, max(MIN_SIDE, round(v / MULTIPLE) * MULTIPLE)))

    return snap(gw), snap(gh)


# ----------------------------------------------------------------- Masken

def mask_from_alpha(img: Image.Image, threshold: int = 250) -> Image.Image | None:
    """Durchsichtige Stellen als Maske (weiß = neu erzeugen), ``None`` bei deckendem Bild.

    So füllt „Füllen“ ohne Auswahl die Ränder, die „Arbeitsfläche erweitern“ transparent
    angelegt hat.
    """
    if img.mode not in ("RGBA", "LA", "PA") and "transparency" not in img.info:
        return None
    alpha = img.convert("RGBA").getchannel("A")
    mask = alpha.point(lambda v: 255 if v < threshold else 0)
    return mask if mask.getbbox() else None


def mask_bbox(mask: Image.Image, level: int = 8) -> Rect | None:
    """Begrenzungsrechteck aller Maskenpixel über ``level``."""
    box = mask.point(lambda v: 255 if v > level else 0).getbbox()
    if not box:
        return None
    return Rect(box[0], box[1], box[2] - box[0], box[3] - box[1])


def prepare_model_mask(mask: Image.Image, size: tuple[int, int], grow: int = 0,
                       blur: float = 0.0) -> Image.Image:
    """Maske auf Arbeitsgröße bringen, um ``grow`` Pixel erweitern und den Rand weichzeichnen.

    Ein etwas größerer, weicher Maskenrand lässt das Modell den Übergang zur Umgebung
    mitrechnen – sonst bleibt an der Auswahlkante oft eine sichtbare Naht.
    """
    m = mask.convert("L").resize(size, Image.Resampling.BILINEAR)
    for _ in range(max(0, int(grow))):
        m = m.filter(ImageFilter.MaxFilter(3))
    if blur > 0:
        m = m.filter(ImageFilter.GaussianBlur(blur))
    return m


# ------------------------------------------------------------------ Bilder

def flatten_for_model(img: Image.Image) -> Image.Image:
    """RGB fürs Modell.

    Durchsichtige Stellen bekommen die mittlere Farbe der sichtbaren Pixel: Dort entsteht
    ohnehin neuer Inhalt, aber ein harter schwarzer Rand würde beim VAE-Encoding in die
    Umgebung ausbluten.
    """
    rgba = img.convert("RGBA")
    alpha = rgba.getchannel("A")
    if alpha.getextrema()[0] == 255:
        return rgba.convert("RGB")
    rgb = rgba.convert("RGB")
    opaque = alpha.point(lambda v: 255 if v > 127 else 0)
    if opaque.getbbox():
        mean = tuple(int(c) for c in ImageStat.Stat(rgb, mask=opaque).mean[:3])
    else:
        mean = (128, 128, 128)
    out = Image.new("RGB", rgba.size, mean)
    out.paste(rgb, mask=alpha)
    return out


def fit_exact(img: Image.Image, w: int, h: int) -> Image.Image:
    """Auf genau ``w``×``h`` skalieren, ohne Beschnitt.

    Für Füllen und Überarbeiten: Der Ausschnitt wurde vor dem Upload genauso gestaucht, das
    Zurückskalieren hebt das exakt wieder auf – Ergebnis und Umgebung bleiben deckungsgleich.
    """
    return img.convert("RGB").resize((w, h), Image.Resampling.LANCZOS)


def fit_cover(img: Image.Image, w: int, h: int) -> Image.Image:
    """Auf ``w``×``h`` füllen und mittig beschneiden (für frei generierte Bilder)."""
    return ImageOps.fit(img.convert("RGB"), (w, h), Image.Resampling.LANCZOS)


def bake_alpha(img: Image.Image, mask: Image.Image) -> Image.Image:
    """Maske als Alphakanal ins Bild legen."""
    rgba = img.convert("RGBA")
    rgba.putalpha(mask.convert("L").resize(rgba.size, Image.Resampling.BILINEAR))
    return rgba


def save_thumbnail(img: Image.Image, path: Path, mask: Image.Image | None = None,
                   max_side: int = 384) -> None:
    """Vorschaubild; mit ``mask`` nur der Teil, der in PhotoCraft sichtbar wird (PNG mit Alpha)."""
    thumb = bake_alpha(img, mask) if mask is not None else img.convert("RGB")
    thumb.thumbnail((max_side, max_side), Image.Resampling.LANCZOS)
    if mask is not None:
        thumb.save(path, "PNG", optimize=True)
    else:
        thumb.save(path, "JPEG", quality=85)
