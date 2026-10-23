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
"""
from __future__ import annotations

import json
import sys

import numpy as np
from PIL import Image

BLEND = 96          # weicher Übergang zum neuen Rand (Pixel)
SEARCH_SIDE = 384   # Kantenlänge der verkleinerten Suchbilder
SCALES = np.arange(0.86, 1.2401, 0.01)   # gemessen bis 1,055 je Achse; Reserve nach oben
SHIFT = 0.06        # gesuchter Versatz: ± 6 % der Bildgröße


def _gray(img: Image.Image, size: tuple[int, int]) -> np.ndarray:
    return np.asarray(img.convert("L").resize(size, Image.BILINEAR), dtype=np.float32)


def _ncc(a: np.ndarray, b: np.ndarray) -> float:
    a = a - a.mean()
    b = b - b.mean()
    return float((a * b).sum() / (np.sqrt((a * a).sum() * (b * b).sum()) + 1e-6))


def measure(result: Image.Image, original: Image.Image, left: int, top: int) -> tuple[float, float, float, float]:
    """(Skalierung, x, y, Korrelation): wo das Original im Ergebnis liegt, in Ergebnis-Pixeln."""
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
        for x in steps:
            for y in steps_y:
                xs, ys = int(round(x)) + mx, int(round(y)) + my
                if xs < 0 or ys < 0 or xs + t.shape[1] > res.shape[1] or ys + t.shape[0] > res.shape[0]:
                    continue
                v = _ncc(t, res[ys:ys + t.shape[0], xs:xs + t.shape[1]])
                if v > best[0]:
                    best = (v, s, int(round(x)), int(round(y)))

    x0, y0 = left / f, top / f
    for s in SCALES:
        try_at(s, np.arange(x0 - span_x, x0 + span_x + 1, 2), np.arange(y0 - span_y, y0 + span_y + 1, 2))
    _, s, bx, by = best
    for s2 in np.arange(s - 0.01, s + 0.0101, 0.0025):
        try_at(s2, np.arange(bx - 2, bx + 3), np.arange(by - 2, by + 3))
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


def main() -> None:
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
