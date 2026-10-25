"""Fotos restaurieren und einfärben: Ergebnis eines Bearbeitungsmodells am Original ausrichten.

Läuft wie outpaint_align.py als eigenes Skript im ComfyUI-venv (numpy, Pillow, scipy):

    python restore_tools.py --align <ergebnis> <original> <ziel> [<mindestkorrelation>]
    python restore_tools.py --merge <restauriert, ausgerichtet> <original> <ziel>
    python restore_tools.py --colorize <farbbild> <helligkeit> <ziel> [--no-guide]

``--merge`` (schonend restaurieren) behält die Feinzeichnung des Originals in voller Auflösung und setzt nur
die Schäden aus dem restaurierten Bild ein: kleine helle oder dunkle Strukturen, die dort fehlen (Staub,
Kratzer), lange dünne Linien (Kratzer, Knicke) und große Flächen mit starkem Unterschied (Riss, Papier,
Lichteinfall). Vom restaurierten Bild kommt dazu nur der großräumige Ton (Kontrast, Verblassen); die
Gesichtszüge bleiben die des Originals.

``--align`` misst, wo das Original im Ergebnis liegt (FLUX 3 gibt ein Bild nie deckungsgleich wieder:
gemessen je Achse 0,97–1,055 und bis 43 px Versatz, siehe outpaint_align.py), und rückt das Ergebnis
zurück: Es deckt sich dann mit dem Original und lässt sich in PhotoCraft als Ebene darüberlegen.
Größe des Ziels = Größe des Ergebnisses im Seitenverhältnis des Originals.

``--colorize`` nimmt nur die Farbe des eingefärbten Bildes (a und b im Lab-Raum) und legt sie auf die
Helligkeit von <helligkeit> in dessen voller Auflösung. So bleiben Schärfe, Korn und jedes Detail des
Originals erhalten, auch wenn das Modell mit 1 MP gerechnet hat (DDColor arbeitet intern genauso, nur
mit 512 px). Die Farbe folgt dabei per Guided Filter den Kanten der Helligkeit.

Ausgabe: eine JSON-Zeile mit den gemessenen Werten.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter
from scipy import ndimage as ndi
from scipy.ndimage import uniform_filter

# Mit python -I fehlt der eigene Ordner in sys.path; outpaint_align.py liegt daneben.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from outpaint_align import measure, refine  # noqa: E402

ALIGN_SCALES = np.arange(0.9, 1.1001, 0.01)


# ------------------------------------------------------------ Farbraum (sRGB, D65)

_M = np.array([[0.4124564, 0.3575761, 0.1804375],
               [0.2126729, 0.7151522, 0.0721750],
               [0.0193339, 0.1191920, 0.9503041]], dtype=np.float32)
_M_INV = np.linalg.inv(_M).astype(np.float32)
_WHITE = np.array([0.95047, 1.0, 1.08883], dtype=np.float32)
_D = 6.0 / 29.0


def rgb_to_lab(rgb: np.ndarray) -> np.ndarray:
    """uint8- oder 0..1-RGB (H, W, 3) nach Lab (L 0..100)."""
    c = rgb.astype(np.float32) / (255.0 if rgb.dtype == np.uint8 else 1.0)
    lin = np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
    xyz = lin @ _M.T / _WHITE
    f = np.where(xyz > _D ** 3, np.cbrt(xyz), xyz / (3 * _D * _D) + 4.0 / 29.0)
    lab = np.empty_like(f)
    lab[..., 0] = 116.0 * f[..., 1] - 16.0
    lab[..., 1] = 500.0 * (f[..., 0] - f[..., 1])
    lab[..., 2] = 200.0 * (f[..., 1] - f[..., 2])
    return lab


def lab_to_rgb(lab: np.ndarray) -> np.ndarray:
    """Lab nach uint8-RGB."""
    fy = (lab[..., 0] + 16.0) / 116.0
    f = np.stack([fy + lab[..., 1] / 500.0, fy, fy - lab[..., 2] / 200.0], axis=-1)
    xyz = np.where(f > _D, f ** 3, 3 * _D * _D * (f - 4.0 / 29.0)) * _WHITE
    lin = np.clip(xyz @ _M_INV.T, 0.0, 1.0)
    c = np.where(lin <= 0.0031308, lin * 12.92, 1.055 * lin ** (1 / 2.4) - 0.055)
    return np.clip(c * 255.0 + 0.5, 0, 255).astype(np.uint8)


def guided(guide: np.ndarray, src: np.ndarray, radius: int, eps: float) -> np.ndarray:
    """Guided Filter (He et al.): ``src`` glätten, Kanten aber dort lassen, wo ``guide`` sie hat."""
    size = 2 * radius + 1
    mean_i = uniform_filter(guide, size)
    mean_p = uniform_filter(src, size)
    cov = uniform_filter(guide * src, size) - mean_i * mean_p
    var = uniform_filter(guide * guide, size) - mean_i * mean_i
    a = cov / (var + eps)
    b = mean_p - a * mean_i
    return uniform_filter(a, size) * guide + uniform_filter(b, size)


# ------------------------------------------------------------------ Ausrichten

def align(result: Image.Image, original: Image.Image, min_score: float = 0.5) -> tuple[Image.Image, dict]:
    """Ergebnis so verschieben und skalieren, dass es sich mit dem Original deckt (Größe des Ergebnisses).

    Das Original wird dafür auf die Größe des Ergebnisses gebracht; gesucht wird Faktor und Versatz mit
    der besten Korrelation (grob, dann in dreifacher Auflösung auf ± 0,5 px). Wo das Modell
    hineingezoomt hat, fehlt am Rand Inhalt -- dort bleibt das unverschobene Ergebnis stehen. Liegt die
    Korrelation unter ``min_score``, hat das Modell das Bild umgebaut: dann bleibt es, wie es ist.
    """
    res = result.convert("RGB")
    width, height = res.size
    orig = original.convert("RGB").resize((width, height), Image.LANCZOS)
    s, px, py, score = measure(res, orig, 0, 0, scales=ALIGN_SCALES)
    s, px, py, score = refine(res, orig, s, px, py)
    if score < min_score:
        return res, {"scale": 1.0, "dx": 0.0, "dy": 0.0, "score": round(score, 3), "aligned": False}
    pad = 128
    src = np.pad(np.asarray(res), ((pad, pad), (pad, pad), (0, 0)), mode="edge")
    aligned = Image.fromarray(src).transform((width, height), Image.AFFINE,
                                             (s, 0, px + pad, 0, s, py + pad), resample=Image.BICUBIC)
    valid = Image.new("L", res.size, 255).transform((width, height), Image.AFFINE, (s, 0, px, 0, s, py),
                                                    resample=Image.NEAREST, fillcolor=0)
    aligned = Image.composite(aligned, res, valid.filter(ImageFilter.GaussianBlur(4)))
    info = {"scale": round(float(s), 4), "dx": round(px, 1), "dy": round(py, 1), "score": round(score, 3)}
    return aligned, info


# ------------------------------------------------- Schonend: nur die Schäden ersetzen

SPOT_LEVEL = 8.0     # Kleinschäden: so viel heller/dunkler (L) als die Umgebung, und im Ergebnis fehlt es
BIG_LEVEL = 25.0     # Großschäden (Riss, Papier, Lichteinfall): so viel Unterschied über eine größere Fläche
SPOT_SIZE = 11       # größte Kleinschäden in Arbeitspixeln (Tophat)
SHIFT_TOLERANCE = 7  # FLUX verschiebt Kleinteile um 1-3 Arbeitspixel: so weit darf das Gegenstück weg sein


def damage_mask(original: np.ndarray, restored: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """(weiche Maske 0..1, Kleinschäden, Großschäden) in der Größe der Eingaben (Arbeitsgröße).

    Kleinschäden (Staub, Kratzer, Schrift auf dem Abzug): Das Original hat dort eine kleine helle oder dunkle
    Struktur (Tophat), das restaurierte Bild in der Nähe keine ähnliche. Was FLUX nur leicht anders zeichnet
    (Augen, Knöpfe, Kanten), hat ein Gegenstück und bleibt. Großschäden: Keime mit starkem Unterschied über
    eine Fläche, die zusammenhängend wachsen -- nachdem die großräumige Tonverschiebung von FLUX
    herausgerechnet ist (sonst lief die Maske über das ganze Bild, gemessen 92 % beim Baseballspieler).
    """
    lo = rgb_to_lab(original)[..., 0]
    lr = rgb_to_lab(restored)[..., 0]
    go, gr = ndi.gaussian_filter(lo, 0.8), ndi.gaussian_filter(lr, 0.8)
    small = np.zeros(lo.shape, dtype=bool)
    for top in (ndi.white_tophat, ndi.black_tophat):
        to = top(go, size=SPOT_SIZE)
        tr = ndi.maximum_filter(top(gr, size=SPOT_SIZE), size=SHIFT_TOLERANCE)
        small |= (to > SPOT_LEVEL) & (tr < 0.35 * to)
    d = go - gr
    seeds = np.abs(ndi.gaussian_filter(d, 20.0)) > BIG_LEVEL
    keep = 1.0 - ndi.binary_dilation(seeds | small, iterations=4).astype(np.float32)
    tone = ndi.gaussian_filter(d * keep, 40.0) / (ndi.gaussian_filter(keep, 40.0) + 1e-4)
    cand = np.abs(ndi.gaussian_filter(d - tone, 2.0)) > BIG_LEVEL * 0.5
    big = ndi.binary_fill_holes(ndi.binary_propagation(seeds & cand, mask=cand))
    small = ndi.binary_dilation(small, iterations=2)
    big = ndi.binary_dilation(big, iterations=3)
    soft = np.maximum(np.clip(ndi.gaussian_filter(small.astype(np.float32), 1.2) * 1.6, 0, 1),
                      np.clip(ndi.gaussian_filter(big.astype(np.float32), 3.0) * 1.6, 0, 1))
    return soft, small, big


LINE_LEVEL = 6.0     # lange Schadenslinien (Kratzer, Knick, Wasserrand): so viel heller/dunkler (L)
LINE_MIN = 0.10      # ... und mindestens so lang, als Anteil der längeren Bildseite
LINE_RIDGE = 9       # größte Linienbreite (Tophat) in Arbeitspixeln
TONE_SIGMA = 24.0    # bis zu dieser Unschärfe kommen Ton und Kontrast von FLUX (Arbeitspixel)


def line_damage(lo: np.ndarray, lr: np.ndarray) -> np.ndarray:
    """Lange dünne Schadenslinien, auch wo das restaurierte Bild daneben eigene Struktur hat (Muster, Laub):
    ein Grat im Original, an derselben Stelle (± 2 px) keiner im Ergebnis, zusammenhängend mindestens
    LINE_MIN der Bildseite lang und dünn. Gesichtszüge sind dafür zu kurz; geprüft an vier Testfotos ohne
    einen Treffer im Gesicht. Findet Kratzer und Knicke stückweise, Wasserränder kaum."""
    go, gr = ndi.gaussian_filter(lo, 0.8), ndi.gaussian_filter(lr, 0.8)
    d = go - gr
    dh = d - ndi.gaussian_filter(d, 6.0)
    mask = np.zeros(lo.shape, dtype=bool)
    for top in (ndi.white_tophat, ndi.black_tophat):
        ridge_o = top(go, size=LINE_RIDGE)
        ridge_r = ndi.maximum_filter(top(gr, size=LINE_RIDGE), size=5)
        mask |= (ridge_o > LINE_LEVEL) & (ridge_r < 0.4 * ridge_o) & (np.abs(dh) > LINE_LEVEL * 0.6)
    mask = ndi.binary_closing(mask, structure=np.ones((3, 3)), iterations=2)
    lab, n = ndi.label(mask, structure=np.ones((3, 3)))
    keep = np.zeros(n + 1, dtype=bool)
    min_len = LINE_MIN * max(lo.shape)
    for i, sl in enumerate(ndi.find_objects(lab), start=1):
        length = float(np.hypot(sl[0].stop - sl[0].start, sl[1].stop - sl[1].start))
        if length >= min_len and float((lab[sl] == i).sum()) / length < 7.0:
            keep[i] = True
    return keep[lab]


def merge_damage(restored: Image.Image, original: Image.Image) -> tuple[Image.Image, dict]:
    """Schonend restaurieren: Feinzeichnung und Gesichter vom Original in voller Auflösung, die Schäden und der
    großräumige Ton (Kontrast, Verblassen, fleckige Belichtung) aus ``restored``.

    ``restored`` muss am Original ausgerichtet sein (``align``). Masken und Ton entstehen in der Arbeitsgröße
    von ``restored``; zusammengesetzt wird in der Größe des Originals. Der Ton ist die stark weichgezeichnete
    Differenz außerhalb der Schäden (normierte Faltung, TONE_SIGMA): Die Gesichtszüge liegen feiner und
    bleiben die des Originals, der Kontrast kommt von FLUX, und eingesetzte Stellen passen ohne Naht dazu.
    Gemessen: Baseballspieler von 1911 mit Streifen, Handschrift, Staub und Papierstück ersetzt, das Gesicht
    blieb das des Originals; stark gealterte Testfotos (25.10.2026) ohne Ton blieben flau und verblasst.
    """
    res = restored.convert("RGB")
    full = original.convert("RGB")
    o_small = np.asarray(full.resize(res.size, Image.LANCZOS), dtype=np.float32)
    r_small = np.asarray(res, dtype=np.float32)
    soft, small, big = damage_mask(o_small / 255.0, r_small / 255.0)
    lines = ndi.binary_dilation(line_damage(rgb_to_lab(o_small / 255.0)[..., 0],
                                            rgb_to_lab(r_small / 255.0)[..., 0]), iterations=2)
    soft = np.maximum(soft, np.clip(ndi.gaussian_filter(lines.astype(np.float32), 1.2) * 1.6, 0, 1))
    damaged = small | big | lines
    keep = 1.0 - ndi.binary_dilation(damaged, iterations=2).astype(np.float32)
    weight = ndi.gaussian_filter(keep, TONE_SIGMA) + 1e-4
    size = full.size
    tone = np.empty((size[1], size[0], 3), dtype=np.float32)
    for c in range(3):
        small_tone = ndi.gaussian_filter((r_small[..., c] - o_small[..., c]) * keep, TONE_SIGMA) / weight
        tone[..., c] = np.asarray(Image.fromarray(small_tone).resize(size, Image.BICUBIC), dtype=np.float32)
    base = np.asarray(full, dtype=np.float32) + tone
    up = np.asarray(res.resize(size, Image.BICUBIC), dtype=np.float32)
    m = np.asarray(Image.fromarray((soft * 255).astype(np.uint8)).resize(size, Image.BILINEAR),
                   dtype=np.float32)[..., None] / 255.0
    out = base + m * (up - base)
    info = {"size": list(size), "damage_percent": round(float((soft > 0.5).mean()) * 100, 2),
            "small_percent": round(float(small.mean()) * 100, 2), "big_percent": round(float(big.mean()) * 100, 2),
            "lines_percent": round(float(lines.mean()) * 100, 2),
            "tone_shift": round(float(np.abs(tone).mean()), 2)}
    return Image.fromarray(np.clip(out + 0.5, 0, 255).astype(np.uint8)), info


# ------------------------------------------------------------------ Einfärben

GUIDE_EPS = 4e-4     # Kanten ab rund 2 % Helligkeitsunterschied halten die Farbe auf
COLOR_GAIN = 1.0     # Sättigung der übernommenen Farbe


def colorize(color: Image.Image, luminance: Image.Image, guide_filter: bool = True) -> tuple[Image.Image, dict]:
    """Farbe (a, b) von ``color`` auf die Helligkeit (L) von ``luminance`` legen, in dessen Größe.

    ``color`` muss mit ``luminance`` deckungsgleich sein (vorher ``align``). Die Farbe wird
    hochskaliert und mit dem Guided Filter an die Kanten der vollen Auflösung angelegt.
    """
    lum = luminance.convert("RGB")
    width, height = lum.size
    lab_full = rgb_to_lab(np.asarray(lum))
    col = color.convert("RGB").resize((width, height), Image.BICUBIC)
    ab = rgb_to_lab(np.asarray(col))[..., 1:]
    factor = max(width, height) / max(color.size)
    if guide_filter:
        guide = lab_full[..., 0] / 100.0
        radius = max(2, round(2 * factor))
        ab = np.stack([guided(guide, ab[..., k], radius, GUIDE_EPS) for k in range(2)], axis=-1)
    out = np.empty_like(lab_full)
    out[..., 0] = lab_full[..., 0]
    out[..., 1:] = ab * COLOR_GAIN
    info = {"size": [width, height], "color_size": list(color.size), "factor": round(factor, 2),
            "chroma": round(float(np.hypot(out[..., 1], out[..., 2]).mean()), 2)}
    return Image.fromarray(lab_to_rgb(out)), info


def main() -> None:
    sys.stdout.reconfigure(encoding="utf-8")
    mode = sys.argv[1]
    if mode == "--align":
        min_score = float(sys.argv[5]) if len(sys.argv) > 5 else 0.5
        out, info = align(Image.open(sys.argv[2]), Image.open(sys.argv[3]), min_score)
        out.save(sys.argv[4])
    elif mode == "--merge":
        out, info = merge_damage(Image.open(sys.argv[2]), Image.open(sys.argv[3]))
        out.save(sys.argv[4])
    elif mode == "--colorize":
        out, info = colorize(Image.open(sys.argv[2]), Image.open(sys.argv[3]),
                             guide_filter="--no-guide" not in sys.argv)
        out.save(sys.argv[4])
    else:
        raise SystemExit(f"unbekannter Modus: {mode}")
    print(json.dumps(info))


if __name__ == "__main__":
    main()
