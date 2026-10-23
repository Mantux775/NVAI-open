"""Outpainting: Ergebnis eines Bearbeitungsmodells am Original ausrichten und das Original zurücklegen.

Läuft als eigenes Skript im ComfyUI-venv (numpy und Pillow; der Server-venv hat beides nicht):

    python outpaint_align.py <ergebnis> <original> <links> <oben> <rechts> <unten> <ziel>
                             [<reserve l o r u> <breite> <höhe>]

Die Ränder sind die, mit denen gerechnet wurde. Die optionale Reserve (Pixel je Seite, im Maßstab des
Originals) steckt in ihnen und wird nach dem Ausrichten abgeschnitten: Sie fängt den Versatz ab,
sonst fehlte an der Gegenseite Bildinhalt (gemessen: Streifen am rechten Rand). Danach wird auf
<breite> × <höhe> gebracht.

FLUX 3 rechnet das ganze Bild neu und gibt das Original dabei nie pixelgenau wieder. Gemessen am
Löwenbild (23.10.2026): je Achse Faktor 0,98 bis 1,015 und bis 36 px Versatz. Ein blind
darübergelegtes Original gab deshalb Geisterkonturen und verbaute Kanten im Übergang. Hier wird
erst gemessen (Skalierung und Versatz mit der besten Korrelation), das Ergebnis passend
zurückgerückt und dann das Original mit weichem Übergang zu den neuen Seiten hin eingesetzt.
Ausgabe: eine JSON-Zeile mit den gemessenen Werten.

Dasselbe für „Füllen“ mit Bearbeitungsmodellen (seit 0.5.6), die keine Maske nehmen:

    python outpaint_align.py --inpaint-prepare <bild> <maske> <ziel>
    python outpaint_align.py --inpaint <ergebnis> <bild> <maske> <ziel>

Der erste schneidet die Maske mit 35 % Umgebung aus und färbt den Maskenbereich (etwas vergrößert)
flach grau; das Modell bekommt das als Referenz. Der zweite misst Skalierung und Versatz nur außerhalb
des Graus, rückt das Ergebnis zurück, setzt es mit weichem Rand ein und legt den Ausschnitt ins Bild;
außerhalb bleibt das Bild pixelgleich. Gemessen am Fischmarkt (FLUX 3, 23.10.2026): Kisten entfernt mit
durchlaufendem Pflaster, Möwe aufs Wasser gesetzt; ein vorhandenes Schild umschreiben gelingt dagegen
mit „Überarbeiten“ (Original sichtbar), grau gefärbt malte FLUX ein neues, frontales Schild.
"""
from __future__ import annotations

import json
import sys

import numpy as np
from PIL import Image, ImageFilter

BLEND = 96          # weicher Übergang zum neuen Rand (Pixel)
SEARCH_SIDE = 384   # Kantenlänge der verkleinerten Suchbilder
SCALES = np.arange(0.86, 1.2401, 0.01)   # gemessen bis 1,055 je Achse; Reserve nach oben
SHIFT = 0.06        # gesuchter Versatz: ± 6 % der Bildgröße


def _gray(img: Image.Image, size: tuple[int, int]) -> np.ndarray:
    return np.asarray(img.convert("L").resize(size, Image.BILINEAR), dtype=np.float32)


def _ncc(a: np.ndarray, b: np.ndarray, w: np.ndarray | None = None) -> float:
    """Normierte Kreuzkorrelation; mit Gewichten ``w`` zählen nur die Pixel mit w > 0."""
    if w is None:
        a = a - a.mean()
        b = b - b.mean()
        return float((a * b).sum() / (np.sqrt((a * a).sum() * (b * b).sum()) + 1e-6))
    total = w.sum() + 1e-6
    a = a - (w * a).sum() / total
    b = b - (w * b).sum() / total
    return float((w * a * b).sum() / (np.sqrt((w * a * a).sum() * (w * b * b).sum()) + 1e-6))


def measure(result: Image.Image, original: Image.Image, left: int, top: int,
            weight: Image.Image | None = None, scales: np.ndarray = SCALES) -> tuple[float, float, float, float]:
    """(Skalierung, x, y, Korrelation): wo das Original im Ergebnis liegt, in Ergebnis-Pixeln.

    ``weight`` (Graustufen, Größe des Originals): nur heller Bereich zählt beim Vergleich, der
    neu gemalte Teil beim Füllen bleibt außen vor.
    """
    f = max(result.size) / SEARCH_SIDE
    res = _gray(result, (round(result.width / f), round(result.height / f)))
    best = (-2.0, 1.0, left / f, top / f)
    span_x, span_y = SHIFT * res.shape[1], SHIFT * res.shape[0]

    def try_at(s: float, steps: np.ndarray, steps_y: np.ndarray) -> None:
        nonlocal best
        w, h = round(original.width * s / f), round(original.height * s / f)
        o = _gray(original, (w, h))
        mx, my = w // 10, h // 10            # Rand des Originals nicht vergleichen
        t = o[my:h - my, mx:w - mx]
        wt = None
        if weight is not None:
            wt = _gray(weight, (w, h))[my:h - my, mx:w - mx] / 255.0
        for x in steps:
            for y in steps_y:
                xs, ys = int(round(x)) + mx, int(round(y)) + my
                if xs < 0 or ys < 0 or xs + t.shape[1] > res.shape[1] or ys + t.shape[0] > res.shape[0]:
                    continue
                v = _ncc(t, res[ys:ys + t.shape[0], xs:xs + t.shape[1]], wt)
                if v > best[0]:
                    best = (v, s, int(round(x)), int(round(y)))

    x0, y0 = left / f, top / f
    for s in scales:
        try_at(s, np.arange(x0 - span_x, x0 + span_x + 1, 2), np.arange(y0 - span_y, y0 + span_y + 1, 2))
    _, s, bx, by = best
    for s2 in np.arange(s - 0.01, s + 0.0101, 0.0025):
        try_at(s2, np.arange(bx - 2, bx + 3), np.arange(by - 2, by + 3))
    v, s, bx, by = best
    return s, bx * f, by * f, v


def refine(result: Image.Image, original: Image.Image, s: float, px: float, py: float,
           weight: Image.Image | None = None, side: int = 1152) -> tuple[float, float, float, float]:
    """Nachmessen in dreifacher Suchauflösung um (s, px, py): die grobe Suche trifft auf etwa
    ± 2 px (gemessen am Fischmarkt, 1728 × 832). Beim Füllen sitzt neuer Inhalt mitten im Bild,
    da sähe man das an jeder Kante, die über den Maskenrand läuft."""
    f = max(result.size) / side
    res = _gray(result, (round(result.width / f), round(result.height / f)))
    best = (-2.0, s, px / f, py / f)
    for s2 in np.arange(s - 0.006, s + 0.00601, 0.0015):
        w, h = round(original.width * s2 / f), round(original.height * s2 / f)
        o = _gray(original, (w, h))
        mx, my = w // 10, h // 10
        t = o[my:h - my, mx:w - mx]
        wt = _gray(weight, (w, h))[my:h - my, mx:w - mx] / 255.0 if weight is not None else None
        for x in range(int(round(px / f)) - 4, int(round(px / f)) + 5):
            for y in range(int(round(py / f)) - 4, int(round(py / f)) + 5):
                xs, ys = x + mx, y + my
                if xs < 0 or ys < 0 or xs + t.shape[1] > res.shape[1] or ys + t.shape[0] > res.shape[0]:
                    continue
                v = _ncc(t, res[ys:ys + t.shape[0], xs:xs + t.shape[1]], wt)
                if v > best[0]:
                    best = (v, float(s2), x, y)
    v, s, bx, by = best
    return s, bx * f, by * f, v


def composite(result: Image.Image, original: Image.Image, edges: list[int],
              reserve: list[int] | None = None) -> tuple[Image.Image, dict]:
    left, top, right, bottom = edges
    width, height = result.size
    # Zielraster: Original + Rand, auf die Ergebnisgröße skaliert (Rundung auf 16 px).
    cw, ch = original.width + left + right, original.height + top + bottom
    sx, sy = width / cw, height / ch
    orig = original.convert("RGB").resize((round(original.width * sx), round(original.height * sy)), Image.LANCZOS)
    ox, oy = round(left * sx), round(top * sy)

    s, px, py, score = measure(result, orig, ox, oy)
    # Ergebnis so verschieben und skalieren, dass das Original darin bei (ox, oy) mit Faktor 1 läge.
    pad = 128
    src = np.pad(np.asarray(result.convert("RGB")), ((pad, pad), (pad, pad), (0, 0)), mode="edge")
    padded = Image.fromarray(src)
    # Ausgabepixel q -> Eingabe p = (px, py) + s * (q - (ox, oy)), plus Polsterung
    aligned = padded.transform((width, height), Image.AFFINE,
                               (s, 0, px - s * ox + pad, 0, s, py - s * oy + pad), resample=Image.BICUBIC)

    keep = np.zeros((height, width), dtype=np.float32)
    h0, w0 = orig.height, orig.width
    yy, xx = np.mgrid[0:h0, 0:w0].astype(np.float32) + 0.5
    d = np.full((h0, w0), np.inf, dtype=np.float32)
    if left:
        d = np.minimum(d, xx)
    if right:
        d = np.minimum(d, w0 - xx)
    if top:
        d = np.minimum(d, yy)
    if bottom:
        d = np.minimum(d, h0 - yy)
    k = np.where(d >= BLEND, 1.0, 1.0 - ((BLEND - np.minimum(d, BLEND)) / BLEND) ** 2)
    keep[oy:oy + h0, ox:ox + w0] = k[:height - oy, :width - ox]
    canvas = np.zeros((height, width, 3), dtype=np.float32)
    canvas[oy:oy + h0, ox:ox + w0] = np.asarray(orig, dtype=np.float32)[:height - oy, :width - ox]
    out = keep[..., None] * canvas + (1 - keep[..., None]) * np.asarray(aligned, dtype=np.float32)
    info = {"scale": round(float(s), 4), "dx": round(px - ox, 1), "dy": round(py - oy, 1), "score": round(score, 3)}
    image = Image.fromarray(np.clip(out + 0.5, 0, 255).astype(np.uint8))
    if reserve and any(reserve):
        rl, rt, rr, rb = reserve
        image = image.crop((round(rl * sx), round(rt * sy), width - round(rr * sx), height - round(rb * sy)))
    return image, info


INPAINT_GREY = (128, 128, 128)           # wie ImagePadForOutpaint beim Erweitern
INPAINT_VEIL = 1.0                       # Deckkraft des Graus beim Füllen (1,0 = flach)
INPAINT_MARGIN = 0.35                    # Umgebung um die Maske, Anteil ihrer längeren Seite
INPAINT_SCALES = np.arange(0.92, 1.0901, 0.01)


def _inpaint_masks(mask: Image.Image, size: tuple[int, int]) -> tuple[Image.Image, int]:
    """(markierter Bereich, Saum in Pixeln) in Bildgröße.

    Markiert wird etwas mehr als die Maske, damit das Modell Platz für den Übergang hat. Beim
    Einsetzen zählt der ganze markierte Bereich; nur nach außen läuft ein weicher Saum.
    """
    grow = max(8, round(0.012 * max(size)))
    hard = mask.convert("L").resize(size, Image.BILINEAR).point(lambda v: 255 if v > 127 else 0)
    marked = hard.filter(ImageFilter.GaussianBlur(grow / 4)).point(lambda v: 255 if v > 8 else 0)
    return marked, grow


def inpaint_box(mask: Image.Image, size: tuple[int, int]) -> tuple[int, int, int, int]:
    """Ausschnitt um die Maske mit Umgebung (wie „Füllen“ im PhotoCraft-Add-on). Das Modell sieht
    nur ihn: So bekommt der Bereich genug Pixel, und die Umgebung gibt Licht und Maßstab vor."""
    hard = mask.convert("L").resize(size, Image.BILINEAR).point(lambda v: 255 if v > 127 else 0)
    bbox = hard.getbbox()
    if bbox is None:
        raise ValueError("Die Maske ist leer (kein weißer Bereich).")
    x0, y0, x1, y1 = bbox
    pad = max(32, round(INPAINT_MARGIN * max(x1 - x0, y1 - y0)))
    return max(0, x0 - pad), max(0, y0 - pad), min(size[0], x1 + pad), min(size[1], y1 + pad)


def inpaint_prepare(image: Image.Image, mask: Image.Image, veil: float = INPAINT_VEIL) -> tuple[Image.Image, tuple]:
    """(Referenz, Ausschnitt): der Ausschnitt um die Maske, der Maskenbereich grau. ``veil`` unter 1
    ließe den alten Inhalt durchscheinen; dann hielt FLUX ihn im Test aber einfach fest."""
    img = image.convert("RGB")
    full_mask = mask.convert("L").resize(img.size, Image.BILINEAR)
    box = inpaint_box(full_mask, img.size)
    crop = img.crop(box)
    marked, _ = _inpaint_masks(full_mask.crop(box), crop.size)
    grey = Image.blend(crop, Image.new("RGB", crop.size, INPAINT_GREY), veil)
    return Image.composite(grey, crop, marked), box


def inpaint_composite(result: Image.Image, original: Image.Image, mask: Image.Image) -> tuple[Image.Image, dict]:
    """Ergebnis für den Ausschnitt ausrichten, nur den markierten Bereich einsetzen und den Ausschnitt
    ins ganze Bild zurücklegen. Außerhalb des Saums bleibt das Bild pixelgleich."""
    full = original.convert("RGB")
    full_mask = mask.convert("L").resize(full.size, Image.BILINEAR)
    box = inpaint_box(full_mask, full.size)
    orig = full.crop(box)
    width, height = orig.size
    marked, grow = _inpaint_masks(full_mask.crop(box), orig.size)
    res = result.convert("RGB")
    if res.size != orig.size:
        res = res.resize(orig.size, Image.LANCZOS)
    # Verglichen wird nur, was das Modell unmarkiert sehen konnte.
    keep = marked.point(lambda v: 255 - v)
    s, px, py, score = measure(res, orig, 0, 0, weight=keep, scales=INPAINT_SCALES)
    s, px, py, score = refine(res, orig, s, px, py, weight=keep)
    pad = 128
    src = np.pad(np.asarray(res), ((pad, pad), (pad, pad), (0, 0)), mode="edge")
    aligned = Image.fromarray(src).transform((width, height), Image.AFFINE,
                                             (s, 0, px + pad, 0, s, py + pad), resample=Image.BICUBIC)
    # Hat das Modell hineingezoomt, fehlt am Rand echter Inhalt; statt Randpixel-Streifen
    # (gemessen bei Maske am unteren Rand) dort das unverschobene Ergebnis nehmen.
    valid = Image.new("L", res.size, 255).transform((width, height), Image.AFFINE, (s, 0, px, 0, s, py),
                                                    resample=Image.NEAREST, fillcolor=0)
    aligned = Image.composite(aligned, res, valid.filter(ImageFilter.GaussianBlur(4)))
    # Gewicht: im markierten Bereich ganz das Ergebnis (sonst schnitte der Saum neuen Inhalt an,
    # gemessen: Schild mit unscharfem, angeschnittenem Rand), nach außen weich aufs Original.
    outer = marked.filter(ImageFilter.GaussianBlur(grow / 4)).point(lambda v: 255 if v > 8 else 0)
    soft = np.asarray(outer.filter(ImageFilter.GaussianBlur(grow / 4)), dtype=np.float32) / 255.0
    k = np.maximum(np.asarray(marked, dtype=np.float32) / 255.0, soft)
    out = k[..., None] * np.asarray(aligned, dtype=np.float32) + (1 - k[..., None]) * np.asarray(orig, dtype=np.float32)
    full.paste(Image.fromarray(np.clip(out + 0.5, 0, 255).astype(np.uint8)), box[:2])
    info = {"scale": round(float(s), 4), "dx": round(px, 1), "dy": round(py, 1), "score": round(score, 3),
            "box": list(box)}
    return full, info


def main() -> None:
    if sys.argv[1] == "--inpaint-prepare":
        veil = float(sys.argv[5]) if len(sys.argv) > 5 else INPAINT_VEIL
        ref, box = inpaint_prepare(Image.open(sys.argv[2]), Image.open(sys.argv[3]), veil)
        ref.save(sys.argv[4])
        print(json.dumps({"box": list(box), "size": list(ref.size)}))
        return
    if sys.argv[1] == "--inpaint":
        out, info = inpaint_composite(Image.open(sys.argv[2]), Image.open(sys.argv[3]), Image.open(sys.argv[4]))
        out.save(sys.argv[5])
        print(json.dumps(info))
        return
    result, original = Image.open(sys.argv[1]), Image.open(sys.argv[2])
    edges = [int(v) for v in sys.argv[3:7]]
    reserve = [int(v) for v in sys.argv[8:12]] if len(sys.argv) >= 12 else None
    out, info = composite(result, original, edges, reserve)
    if len(sys.argv) >= 14:
        out = out.resize((int(sys.argv[12]), int(sys.argv[13])), Image.LANCZOS)
    out.save(sys.argv[7])
    print(json.dumps(info))


if __name__ == "__main__":
    main()
