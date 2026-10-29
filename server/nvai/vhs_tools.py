"""VHS-Videos aufwerten (seit 0.5.16), laeuft im ComfyUI-venv wie video_tools.py (PyAV, numpy, scipy). Nutzer
28.10.2026: „heute digitalisiere ich VHS-Videokassetten … einen neuen Bereich, der das VHS-Video mit der KI entrauscht,
stabilisiert und aufbessert“, „es braucht nur Aufwertungswerkzeuge“. Kein ffmpeg-Programm noetig: Alle Filter stecken
im PyAV von ComfyUI (bwdif, atadenoise, fftdnoiz, nlmeans, deshake, chromashift, normalize, deflicker, afftdn).
Gestreamt Bild fuer Bild; Fortschritt als JSON-Zeilen {"progress": 0..1}, zum Schluss eine JSON-Zeile mit dem Ergebnis.

    python vhs_tools.py analyze <video> <vorschau.jpg>
    python vhs_tools.py run <einstellungen.json>          klassisch aufwerten, ganz oder ein Abschnitt -> MP4
    python vhs_tools.py audio <einstellungen.json>        nur den Ton (Rauschen, Lautheit) -> WAV
    python vhs_tools.py segment <einstellungen.json>      Abschnitt fuer SeedVR2 (klassisch vorbereitet) -> FFV1/MKV
    python vhs_tools.py part <einstellungen.json>         SeedVR2-Abschnitt mit dem vorigen ueberblenden -> Teil-MP4
    python vhs_tools.py concat <einstellungen.json>       Teile ohne neues Kodieren aneinander, Ton dazu -> MP4
    python vhs_tools.py cadence <einstellungen.json>      Takt je Schritt (kurz/lang, Schnitte) fuers Glaetten

Gemessen 28.10. an einem kuenstlichen VHS-Clip (720 x 576 interlaced, MPEG-2, Rauschen, Farbversatz) auf 768 x 576 mit
50 Bildern/s: bwdif + Skalieren 1369 Bilder/s, dazu atadenoise 990, chromashift + deflicker 854, deshake 92, fftdnoiz
58, nlmeans 19,5, bm3d 17,7 (deshake/fftdnoiz/nlmeans: 1 h Band 33 min / 52 min / 2,6 h).
"""
from __future__ import annotations

import json
import sys
import time
from fractions import Fraction
from pathlib import Path
from typing import Any, Iterator

import av
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent / "comfy_nodes"))
import nvai_audio  # noqa: E402  (Limiter wie beim Erzeugen)
import studio_render  # noqa: E402  (Encoderwahl, Lautheit nach BS.1770)

# Entrauschen nach Staerke, nur die Helligkeit (p=1 bzw. planes=1). Bis 28.10. mittelte atadenoise auch die Farbe: am
# echten Band kamen in bewegten Bereichen nur 51-71 % der Farbe aus dem aktuellen Bild, der Rest zog als Schliere nach
# (Helligkeit dagegen 100 %). Die Farbe macht jetzt die Farbstufe (CHROMA_*), die Bewegung beachtet. Zeiten im Moduldoc.
DENOISE = {
    "light": ["atadenoise=0a=0.03:0b=0.05:s=9:p=1"],
    "medium": ["atadenoise=0a=0.03:0b=0.05:s=9:p=1", "fftdnoiz=sigma=5:amount=0.9:prev=1:next=1:planes=1"],
    "strong": ["atadenoise=0a=0.04:0b=0.06:s=9:p=1", "nlmeans=s=3:p=7:pc=5:r=9:rc=7"],
}
# Blockkanten der Aufnahme glaetten (H.264/MPEG-2 aus Wandlern): echtes Band an 8/16-px-Grenzen 18-32 % mehr Sprung als
# dazwischen; mit diesen Werten 0,97-1,08 (weak mit Vorgaben ueberglaettete auf 0,75-0,86), Schaerfe unveraendert.
# Vor allem anderen, im Raster der Aufnahme.
DEBLOCK = "deblock=filter=weak:block=8:alpha=0.04:beta=0.02:gamma=0.02:delta=0.02"
# Farbflecken mindern (Nutzer 28.10. abends: „kannst du die Farbflecken entfernen oder verbessern“, danach „die anderen
# haben Schlieren bekommen“): auf der Farbebene, die Helligkeit fuehrt. Zeitlich ueber +-CHROMA_K Bilder, Gewicht je
# Nachbar exp(-(|Yb_t - Yb_t+k| / CHROMA_T)^2) mit Yb = Helligkeit auf Farbgroesse, leicht weich: wo sich das Bild
# bewegt, ist das Gewicht ~0 und nichts zieht nach. Dann ein Guided Filter (Fuehrung Helligkeit, Radius CHROMA_R): Die
# Farbe glaettet sich, Kanten bleiben nur dort, wo die Helligkeit eine hat (gegen Ausbluten und blaeuliche Saeume).
# Gemessen am echten Band (20-s-Clip, 960 x 720): Farbunruhe zeitlich 1,27 -> 0,18, raeumlich 0,48 -> 0,06, Lage der
# Farbkanten an Helligkeitskanten (Korrelation) 0,32 -> 0,60, Saettigung 14,2 -> 13,9. Der alte Filter (atadenoise
# ueber 15 Bilder + chromanr) nahm in bewegten Bereichen nur 20-41 % der Farbe aus dem aktuellen Bild: die Schlieren.
CHROMA_K, CHROMA_T, CHROMA_R, CHROMA_EPS = 3, 3.0, 4, 30.0
# „kraeftig“: der Farbfilter vom Nachmittag des 28.10., unveraendert (Farbanteil des alten „leicht“ ueber 9 Bilder, dann
# 15 Bilder und chromanr). Der Nutzer zog damit „Variante 3 + Nachschaerfen mittel“ allen anderen Fassungen vor, auch der
# neuen Farbstufe. Glaettet die Farbe staerker und gleichmaessiger, zieht dafuer in Bewegung nach (siehe oben).
CHROMA_STRONG = ["atadenoise=0a=0.03:0b=0.05:1a=0.06:1b=0.10:2a=0.06:2b=0.10:s=9:p=6",
                 "atadenoise=0a=0.02:0b=0.04:1a=0.10:1b=0.20:2a=0.10:2b=0.20:s=15:p=6",
                 "chromanr=thres=30:sizew=5:sizeh=5:threy=24"]


def chroma_mode(s: dict[str, Any]) -> str:
    """Farbflecken: off, clean (ChromaCleaner, auch True) oder strong (CHROMA_STRONG)."""
    v = s.get("chroma_denoise")
    if v is True:
        return "clean"
    return v if v in ("clean", "strong") else "off"
# Nachschaerfen ohne KI (Nutzer 28.10. abends zur KI-Fassung: „die anderen haben Schlieren bekommen. aber es ist immer
# noch sehr weich“): Die KI machte aus unscharfen Koepfen in einer weiten Einstellung kantige Splitter. Klassisch verstaerkt nur
# vorhandene Kanten, nur die Helligkeit. Gemessen am echten Band (Gesichter, 960 x 720): Laplace-Varianz ohne 49,
# leicht 92, mittel 129, stark 188; Rauschen 0,17 / 0,21 / 0,26 / 0,40 (CAS 0,9 allein 300 / 0,55, zu koernig).
SHARPEN = {
    "light": ["unsharp=7:7:0.6:5:5:0"],
    "medium": ["unsharp=7:7:1.0:5:5:0"],
    "strong": ["unsharp=9:9:0.8:5:5:0", "cas=strength=0.4"],
}
PREROLL_S = 1.0  # Vorlauf beim Springen in einen Abschnitt, damit zeitliche Filter eingeschwungen sind
BITRATE = {576: 8_000_000, 720: 14_000_000, 1080: 24_000_000}
# Uebliche Bildraten: Ein Aufnahmegeraet schrieb 29,9998 statt 30 (echtes Band, 28.10.), limit_denominator machte daraus
# 18749/625; die naechste uebliche Rate passt besser zu Spielern und Schnittprogrammen.
STANDARD_RATES = (Fraction(24000, 1001), Fraction(24), Fraction(25), Fraction(30000, 1001), Fraction(30),
                  Fraction(48), Fraction(50), Fraction(60000, 1001), Fraction(60))


def snap_rate(rate: Fraction) -> Fraction:
    best = min(STANDARD_RATES, key=lambda c: abs(float(rate - c)))
    return best if abs(float(rate - best)) / float(best) < 0.002 else rate.limit_denominator(1001)


def emit(**msg: Any) -> None:
    print(json.dumps(msg), flush=True)


# ------------------------------------------------------------------------------------------------ Analyse

def _fields(gray: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Oberes und unteres Halbbild, beide auf dieselbe Bildhoehe gebracht (das untere liegt eine halbe Zeile tiefer)."""
    top, bot = gray[0::2].astype(np.float32), gray[1::2].astype(np.float32)
    n = min(len(top), len(bot))
    top, bot = top[:n], bot[:n]
    return (top[:-1] + top[1:]) / 2, bot[:-1]


def _cadence(path: str, seconds: float | None) -> dict[str, Any]:
    """Bildtakt pruefen, in sechs Fenstern zu 60 Bildern ueber das ganze Video. Wandler, die ein 50-Hz-Band (PAL) mit 30
    Bildern/s aufnehmen, nehmen das jeweils letzte Halbbild: Die Bilder liegen 40, 40 und 20 ms auseinander, jeder dritte
    Schritt ist halb so gross (echtes Band 28.10.: bei Schwenks 0,40-0,46 der Nachbarschritte, Phasenkorrelation).
    Material mit 25 Vollbildern/s bekommt dabei jedes sechste Bild doppelt. Gemessen wird die mittlere Abweichung von Bild
    zu Bild in 160 x 90; Fenster ohne Bewegung zaehlen nicht."""
    if not seconds or seconds < 6:
        return {"kind": "unknown", "windows": 0}
    votes = {"50to30": 0, "25to30": 0, "even": 0}
    with av.open(path) as c:
        vs = c.streams.video[0]
        vs.thread_type = "AUTO"
        span = 61 / 30 + 0.5
        for frac in (0.15, 0.3, 0.45, 0.6, 0.75, 0.9):
            t = min(seconds * frac, max(0.0, seconds - span))
            c.seek(int(t / float(vs.time_base)), stream=vs, backward=True)
            grays: list[np.ndarray] = []
            for f in c.decode(vs):
                if f.pts is not None and float(f.pts * vs.time_base) < t:
                    continue
                grays.append(f.reformat(width=160, height=90, format="gray8").to_ndarray().astype(np.float32))
                if len(grays) >= 61:
                    break
            if len(grays) < 31:
                continue
            m = np.abs(np.diff(np.stack(grays), axis=0)).mean(axis=(1, 2))
            med = float(np.median(m))
            if med < 1.2:
                continue                                     # kaum Bewegung, sagt nichts ueber den Takt
            dups = float((m < 0.35 * med).mean())
            phases = sorted(float(np.median(m[p::3])) for p in range(3))
            if 0.1 <= dups <= 0.25:
                votes["25to30"] += 1
            elif phases[2] / max(phases[0], 1e-6) >= 1.3 and phases[2] / max(phases[1], 1e-6) <= 1.2:
                votes["50to30"] += 1
            else:
                votes["even"] += 1
    windows = sum(votes.values())
    kind = "unknown"
    if windows:
        top = max(votes, key=lambda k: votes[k])
        kind = top if votes[top] * 2 > windows else "mixed"
        if kind == "mixed" and votes["50to30"] + votes["25to30"] > windows / 2:
            kind = "50to30"                                  # Kamerabilder mit Grafikteilen dazwischen: dasselbe Geraet
    return {"kind": kind, "windows": windows, "votes": votes}


def analyze(path: str, thumb: str) -> dict[str, Any]:
    """Format, Verflechtung, Halbbild-Reihenfolge, Raender und ein Vorschaubild aus der Mitte."""
    with av.open(path) as c:
        vs = c.streams.video[0]
        rate = snap_rate(Fraction(vs.average_rate or vs.guessed_rate or 25))
        seconds = float(c.duration / av.time_base) if c.duration else None
        w, h = vs.codec_context.width, vs.codec_context.height
        sar = vs.sample_aspect_ratio or vs.codec_context.sample_aspect_ratio
        audio = None
        if c.streams.audio:
            a = c.streams.audio[0]
            audio = {"codec": a.codec_context.name, "rate": a.codec_context.sample_rate,
                     "channels": a.codec_context.channels}
        codec = vs.codec_context.name
        # Stichprobe: 240 Bilder ab 10 % der Laenge (Vorspann und Bandanfang auslassen)
        if seconds and seconds > 30:
            c.seek(int(seconds * 0.10 / float(vs.time_base)), stream=vs)
        flagged = combs = n = 0
        tff = bff = 0.0
        prev_top = prev_bot = None
        rows_jitter = np.zeros(h, np.float64)
        col_mean = np.zeros(w, np.float64)
        dxs, dys = np.zeros(w - 1, np.float64), np.zeros(h - 1, np.float64)
        prev_gray = None
        mid = None
        for frame in c.decode(vs):
            gray = frame.to_ndarray(format="gray8")
            n += 1
            flagged += bool(frame.interlaced_frame)
            g = gray.astype(np.float32)
            # Kammeffekt: Abweichung jeder ungeraden Zeile vom Mittel ihrer Nachbarn gegen dasselbe fuer gerade Zeilen
            odd = np.abs(g[1:-1:2] - (g[0:-2:2] + g[2::2]) / 2).mean()
            even = np.abs(g[2:-1:2] - (g[1:-2:2] + g[3::2]) / 2).mean()
            combs += odd > 1.25 * even + 0.3
            top, bot = _fields(gray)
            if prev_top is not None:
                # Richtige Reihenfolge = ruhigere Uebergaenge zwischen den Halbbildern aufeinanderfolgender Bilder
                tff += float(np.abs(prev_bot - top).mean())
                bff += float(np.abs(prev_top - bot).mean())
            prev_top, prev_bot = top, bot
            if prev_gray is not None:
                rows_jitter += np.abs(g - prev_gray).mean(axis=1)
            prev_gray = g
            col_mean += g.mean(axis=0)
            dxs += np.abs(np.diff(g, axis=1)).mean(axis=0)
            dys += np.abs(np.diff(g, axis=0)).mean(axis=1)
            if n == 120:
                mid = frame.to_image()
            if n >= 240:
                break
    if mid is None and prev_gray is not None:
        mid = av.VideoFrame.from_ndarray(prev_gray.astype(np.uint8), format="gray8").to_image()
    if mid is not None:
        mid.convert("RGB").save(thumb, quality=90)
    interlaced = h in (480, 486, 576) and (flagged > n * 0.5 or combs > n * 0.15)
    parity = "tff" if tff <= bff else "bff"
    # Kopfumschalt-Stoerung: unterste Zeilen, deren Unruhe von Bild zu Bild weit ueber dem Ueblichen liegt
    jitter = rows_jitter / max(1, n - 1)
    base = float(np.median(jitter[h // 4: 3 * h // 4])) or 1.0
    bottom = 0
    for k in range(1, min(24, h // 8)):
        if jitter[h - k] > 2.5 * base:
            bottom = k
    bottom = min(16, bottom + 2 if bottom else 0)
    # Schwarze Raender links und rechts: Overscan der Aufnahmekarte, bei 16:9-Dateien auch Saeulen um ein 4:3-Bild
    # (1280 x 720 mit 4:3 in der Mitte: je 160 px, deshalb bis zu einem Sechstel der Breite)
    cols = col_mean / max(1, n)
    left = int(np.argmax(cols > 22)) if (cols > 22).any() else 0
    right = int(np.argmax(cols[::-1] > 22)) if (cols[::-1] > 22).any() else 0
    left, right = min(left, w // 6), min(right, w // 6)
    standard = "PAL" if h == 576 else "NTSC" if h in (480, 486) else "other"
    sar_f = float(sar) if sar else 1.0
    dar = w * sar_f / h
    wide = dar > 1.55
    if standard == "PAL":
        square = [1024, 576] if wide else [768, 576]
    elif standard == "NTSC":
        square = [854, 480] if wide else [640, 480]
    else:
        square = [w // 2 * 2, h // 2 * 2]
    # VHS ist fast immer 4:3. Eine 16:9-Datei ohne seitliche Saeulen hat der Wandler meist in die Breite gezogen (echtes
    # Band 28.10.: 1280 x 720, runde Gegenstaende 1,3- bis 1,5-mal breiter als hoch). Nur ein Vorschlag, das Vorschaubild
    # im Reiter zeigt beide Faelle.
    stretched = standard == "other" and abs(dar - 16 / 9) < 0.05 and (left + right) < 0.05 * w
    # Blockkanten der Kompression: Sprung an 8-px-Rastergrenzen gegen den Sprung dazwischen (echtes Band 1,18/1,21)
    def _grid(d: np.ndarray) -> float:
        idx = np.arange(7, len(d), 8)
        rest = np.setdiff1d(np.arange(len(d)), idx)
        return float(d[idx].mean() / max(1e-6, d[rest].mean())) if len(idx) and len(rest) else 1.0
    blockiness = max(_grid(dxs), _grid(dys))
    out_rate = rate * 2 if interlaced else rate
    cadence = (_cadence(path, seconds) if not interlaced and rate in (Fraction(30), Fraction(30000, 1001))
               else {"kind": "native", "windows": 0})
    return {
        "width": w, "height": h, "fps": [rate.numerator, rate.denominator], "seconds": round(seconds, 3) if seconds else None,
        "codec": codec, "standard": standard, "interlaced": interlaced, "parity": parity,
        "flagged_interlaced": round(flagged / max(1, n), 3), "combing": round(combs / max(1, n), 3),
        "field_motion": {"tff": round(tff, 1), "bff": round(bff, 1)}, "sar": [sar.numerator, sar.denominator] if sar else None,
        "aspect": "16:9" if wide else "4:3", "square_size": square,
        "crop": {"left": left, "top": 0, "right": right, "bottom": bottom},
        "out_fps": [out_rate.numerator, out_rate.denominator], "audio": audio, "sampled_frames": n,
        "stretched": stretched, "suggest_aspect": "4:3" if stretched else "source", "cadence": cadence,
        "blockiness": round(blockiness, 3), "blocky": blockiness > 1.1,
    }


# --------------------------------------------------------------------------------------------- Filterkette

def video_filters(s: dict[str, Any], src_w: int, src_h: int) -> list[str]:
    """Filterkette in der Reihenfolge: entflechten, beschneiden, auf quadratische Pixel skalieren, entrauschen, Farbe,
    Flackern, stabilisieren. Entflochten wird vor dem Beschneiden, damit die Halbbilder nicht verrutschen."""
    out: list[str] = [DEBLOCK] if s.get("deblock") else []
    mode = s.get("deinterlace", "double")
    if mode in ("double", "single"):
        parity = s.get("parity") or "auto"
        out.append(f"bwdif=mode={'send_field' if mode == 'double' else 'send_frame'}:parity={parity}:deint=all")
    cl, ct, cr, cb = (int(v) for v in (s.get("crop") or [0, 0, 0, 0]))
    if cl or ct or cr or cb:
        cw, ch = src_w - cl - cr, src_h - ct - cb
        out.append(f"crop={cw // 2 * 2}:{ch // 2 * 2}:{cl}:{ct}")
    w, h = s.get("size") or [src_w, src_h]
    # out_range=limited: Wandler schreiben oft volle Skala (yuvj420p, 0-255). Ohne Umrechnung blieben die Werte voll,
    # das Ergebnis aber ohne Kennzeichen; Spieler lesen es als Videobereich (16-235): echtes Band 28.10. mittlere
    # Helligkeit 32 statt 41, Schwarz lief zu. Bei Quellen im Videobereich aendert sich nichts.
    out += [f"scale={int(w)}:{int(h)}:flags=lanczos:out_range=limited", "setsar=1"]
    out += DENOISE.get(s.get("denoise") or "off", [])
    if chroma_mode(s) == "strong":
        out += CHROMA_STRONG                                   # „clean“ macht ChromaCleaner hinter der Kette
    cs = int(s.get("chroma_shift") or 0)
    if cs:
        out.append(f"chromashift=cbh={cs}:crh={cs}")
    if s.get("levels"):
        out.append("normalize=blackpt=black:whitept=white:smoothing=50:independence=0:strength=0.6")
    if s.get("deflicker"):
        out.append("deflicker=size=5:mode=am")
    if s.get("stabilize"):
        out.append("deshake=rx=32:ry=32:edge=mirror:blocksize=8")
    out += SHARPEN.get(s.get("sharpen") or "off", [])     # zuletzt: nach Entrauschen und Stabilisieren
    out.append("format=yuv420p")
    return out


def _graph(stream: Any, specs: list[str]) -> av.filter.Graph:
    g = av.filter.Graph()
    nodes = [g.add_buffer(template=stream)]
    for spec in specs:
        name, _, args = spec.partition("=")
        nodes.append(g.add(name, args) if args else g.add(name))
    nodes.append(g.add("buffersink"))
    for a, b in zip(nodes, nodes[1:]):
        a.link_to(b)
    g.configure()
    return g


def _guided(guide: np.ndarray, src: np.ndarray, radius: int, eps: float) -> np.ndarray:
    """Guided Filter (He et al.) wie restore_tools.guided: ``src`` glaetten, Kanten nur dort, wo ``guide`` sie hat."""
    from scipy.ndimage import uniform_filter
    size = 2 * radius + 1
    mean_i, mean_p = uniform_filter(guide, size), uniform_filter(src, size)
    cov = uniform_filter(guide * src, size) - mean_i * mean_p
    var = uniform_filter(guide * guide, size) - mean_i * mean_i
    a = cov / (var + eps)
    b = mean_p - a * mean_i
    return uniform_filter(a, size) * guide + uniform_filter(b, size)


class ChromaCleaner:
    """Farbflecken mindern (Werte und Messungen bei CHROMA_*): bekommt die fertig aufbereiteten Bilder (yuv420p) der Reihe
    nach und gibt sie mit CHROMA_K Bildern Verzoegerung zurueck, die Farbe zeitlich (nur wo die Helligkeit ruht) und
    raeumlich (Guided Filter, Fuehrung Helligkeit) geglaettet. Die Helligkeit bleibt unveraendert."""

    def __init__(self, k: int = CHROMA_K) -> None:
        self.k = k
        self.buf: list[tuple[Any, np.ndarray, np.ndarray, np.ndarray, np.ndarray, np.ndarray]] = []
        self.pos = 0                                       # naechstes auszugebendes Bild im Puffer

    @staticmethod
    def _plane(f: av.VideoFrame, i: int) -> np.ndarray:
        p = f.planes[i]
        return np.frombuffer(p, np.uint8).reshape(p.height, p.line_size)[:, :p.width].astype(np.float32)

    def push(self, f: av.VideoFrame) -> list[av.VideoFrame]:
        from scipy.ndimage import gaussian_filter
        y, u, v = (self._plane(f, i) for i in range(3))
        h, w = u.shape
        ys = y[:2 * h, :2 * w].reshape(h, 2, w, 2).mean(axis=(1, 3))
        self.buf.append((f, y, ys, gaussian_filter(ys, 1.0), u, v))
        out = []
        while len(self.buf) - 1 - self.pos >= self.k:
            out.append(self._emit(self.pos))
            self.pos += 1
            drop = self.pos - self.k
            if drop > 0:
                del self.buf[:drop]
                self.pos -= drop
        return out

    def flush(self) -> list[av.VideoFrame]:
        out = []
        while self.pos < len(self.buf):
            out.append(self._emit(self.pos))
            self.pos += 1
        return out

    def _emit(self, i: int) -> av.VideoFrame:
        f, y, ys, yb, u, v = self.buf[i]
        su, sv, sw = u.copy(), v.copy(), np.ones_like(u)
        for j in range(max(0, i - self.k), min(len(self.buf), i + self.k + 1)):
            if j == i:
                continue
            wj = np.exp(-(np.abs(yb - self.buf[j][3]) / CHROMA_T) ** 2)
            su += wj * self.buf[j][4]
            sv += wj * self.buf[j][5]
            sw += wj
        uu = _guided(ys, su / sw, CHROMA_R, CHROMA_EPS)
        vv = _guided(ys, sv / sw, CHROMA_R, CHROMA_EPS)
        nf = av.VideoFrame(f.width, f.height, "yuv420p")
        for k, arr in enumerate((y, uu, vv)):
            p = nf.planes[k]
            dst = np.frombuffer(p, np.uint8).reshape(p.height, p.line_size)
            dst[:, :arr.shape[1]] = np.clip(arr + 0.5, 0, 255).astype(np.uint8)
        nf.pts, nf.time_base = f.pts, f.time_base
        try:
            nf.color_range = f.color_range
        except (AttributeError, TypeError, ValueError):
            pass
        return nf


def frames(s: dict[str, Any], start: float = 0.0, duration: float | None = None) -> Iterator[av.VideoFrame]:
    """Aufbereitete Bilder ab `start` Sekunden (Quellzeit) fuer `duration` Sekunden. Mit Vorlauf: Die zeitlichen Filter
    (bwdif, atadenoise, deshake, Farbstufe) sehen schon die Sekunde davor, deren Bilder fallen weg."""
    with av.open(s["src"]) as c:
        vs = c.streams.video[0]
        vs.thread_type = "AUTO"
        seek_to = max(0.0, start - PREROLL_S)
        if seek_to > 0:
            c.seek(int(seek_to / float(vs.time_base)), stream=vs, backward=True)
        g = _graph(vs, video_filters(s, vs.codec_context.width, vs.codec_context.height))
        clean = ChromaCleaner() if chroma_mode(s) == "clean" else None
        end = None if duration is None else start + duration
        margin = (clean.k + 1) / 25 if clean else 0.0     # Nachlauf, damit die Farbstufe am Ende Nachbarn hat
        t0 = float(vs.start_time * vs.time_base) if vs.start_time is not None else 0.0

        def when(f: av.VideoFrame) -> float | None:
            return float(f.pts * f.time_base) - t0 if f.pts is not None else None

        def drain() -> Iterator[av.VideoFrame]:
            while True:
                try:
                    f = g.pull()
                except (av.BlockingIOError, av.EOFError):
                    return
                yield from (clean.push(f) if clean else (f,))

        def window(fs: Iterator[av.VideoFrame]) -> Iterator[av.VideoFrame | None]:
            """Bilder im Zeitfenster; None = Ende erreicht."""
            for f in fs:
                t = when(f)
                if end is not None and t is not None and t >= end:
                    yield None
                    return
                if t is None or t + 1e-6 >= start:
                    yield f

        for frame in c.decode(vs):
            ft = float(frame.pts * vs.time_base) - t0 if frame.pts is not None else 0.0
            if ft + 1e-6 < seek_to:
                continue
            if end is not None and ft >= end + margin:
                break
            g.push(frame)
            for f in window(drain()):
                if f is None:
                    return
                yield f
        g.push(None)
        tail = list(drain()) + (clean.flush() if clean else [])
        for f in window(iter(tail)):
            if f is None:
                return
            yield f


# ---------------------------------------------------------------------------------------------------- Ton

def audio(s: dict[str, Any]) -> dict[str, Any]:
    """Ton des Abschnitts: Bandrauschen mindern (afftdn), auf `loudness` LUFS bringen und bei -1 dBFS begrenzen.
    Ergebnis als WAV (Float) in s["audio_out"]; ohne Tonspur nichts."""
    start, duration = float(s.get("start") or 0.0), s.get("duration")
    with av.open(s["src"]) as c:
        if not c.streams.audio:
            return {"audio": False}
        ast = c.streams.audio[0]
        rate = ast.codec_context.sample_rate or 48000
        if start > 0:
            c.seek(int(start / av.time_base), backward=True)
        g = av.filter.Graph()
        nodes = [g.add_abuffer(template=ast)]
        if s.get("audio_denoise"):
            nodes.append(g.add("highpass", "f=40"))
            nodes.append(g.add("afftdn", "nr=12:nf=-35:tn=1"))
        nodes += [g.add("aresample", str(rate)), g.add("aformat", f"sample_fmts=fltp:channel_layouts=stereo"),
                  g.add("abuffersink")]
        for a, b in zip(nodes, nodes[1:]):
            a.link_to(b)
        g.configure()
        parts: list[np.ndarray] = []
        t0 = float(ast.start_time * ast.time_base) if ast.start_time is not None else 0.0
        end = None if duration is None else start + float(duration)

        def drain() -> None:
            while True:
                try:
                    parts.append(g.pull().to_ndarray())
                except (av.BlockingIOError, av.EOFError):
                    return

        skip = None
        for frame in c.decode(ast):
            ft = float(frame.pts * ast.time_base) - t0 if frame.pts is not None else 0.0
            if skip is None:
                skip = max(0, int(round((start - ft) * rate)))
            if end is not None and ft >= end:
                break
            g.push(frame)
            drain()
        g.push(None)
        drain()
    data = np.concatenate(parts, axis=1) if parts else np.zeros((2, 0), np.float32)
    data = data[:, skip or 0:]
    if end is not None:
        data = data[:, :int(round(float(duration) * rate))]
    before = studio_render.loudness(data, rate) if data.shape[1] else None
    if s.get("loudnorm") and before is not None and np.isfinite(before):
        data = data * (10 ** ((float(s.get("loudness", -16.0)) - before) / 20))
        data = data * nvai_audio.gain_curve(data, rate, -1.0)
    with av.open(s["audio_out"], "w", format="wav") as dst:
        st = dst.add_stream("pcm_f32le", rate=rate, layout="stereo")
        step = rate
        for k in range(0, data.shape[1], step):
            chunk = np.ascontiguousarray(data[:, k:k + step].T.reshape(1, -1).astype(np.float32))
            af = av.AudioFrame.from_ndarray(chunk, format="flt", layout="stereo")
            af.sample_rate, af.pts = rate, k
            for p in st.encode(af):
                dst.mux(p)
        for p in st.encode(None):
            dst.mux(p)
    return {"audio": True, "rate": rate, "seconds": round(data.shape[1] / rate, 3),
            "lufs_before": round(before, 1) if before is not None and np.isfinite(before) else None}


def _mux_audio(dst: Any, wav: str | None) -> Any:
    if not wav or not Path(wav).exists():
        return None
    with av.open(wav) as c:
        rate = c.streams.audio[0].codec_context.sample_rate
    return dst.add_stream("aac", rate=rate, layout="stereo"), rate


def _write_audio(dst: Any, astream: Any, wav: str) -> None:
    rate = astream.codec_context.sample_rate
    resampler = av.AudioResampler(format="fltp", layout="stereo", rate=rate)
    pos = 0
    with av.open(wav) as c:
        for frame in c.decode(audio=0):
            for af in resampler.resample(frame):
                af.pts, af.time_base = pos, Fraction(1, rate)
                pos += af.samples
                for p in astream.encode(af):
                    dst.mux(p)
    for af in resampler.resample(None):
        af.pts, af.time_base = pos, Fraction(1, rate)
        pos += af.samples
        for p in astream.encode(af):
            dst.mux(p)
    for p in astream.encode(None):
        dst.mux(p)


def _video_stream(dst: Any, codec: str, w: int, h: int, rate: Fraction, bitrate: int | None = None) -> Any:
    bitrate = bitrate or BITRATE.get(min(BITRATE, key=lambda k: abs(k - h)))
    name = studio_render.pick_encoder(codec, w, h, rate, bitrate)
    vs = dst.add_stream(name, rate=rate)
    vs.width, vs.height, vs.pix_fmt = w, h, "yuv420p"
    vs.bit_rate = bitrate
    vs.options = studio_render._encoder_options(name, bitrate)
    return vs


# ------------------------------------------------------------------------------------------------ Befehle

def run(s: dict[str, Any]) -> dict[str, Any]:
    """Klassisch aufwerten: Ton nach s["audio_out"], Bild durch die Filterkette, beides in s["out"] (MP4)."""
    start, duration = float(s.get("start") or 0.0), s.get("duration")
    info = s.get("info") or {}
    total = float(duration) if duration else float(info.get("seconds") or 0) - start
    a = audio(s) if s.get("audio_out") else {"audio": False}
    w, h = (int(v) for v in s["size"])
    fps = Fraction(*s["out_fps"])
    n = 0
    t0 = time.time()
    with av.open(s["out"], "w", options={"movflags": "+faststart"}) as dst:
        vstream = _video_stream(dst, s.get("codec", "h264"), w, h, fps, s.get("bitrate"))
        aud = _mux_audio(dst, s.get("audio_out")) if a.get("audio") else None
        expected = max(1, int(total * float(fps))) if total > 0 else None
        for f in frames(s, start, duration):
            f.pts, f.time_base = n, 1 / fps
            n += 1
            for p in vstream.encode(f):
                dst.mux(p)
            if expected and n % 50 == 0:
                emit(progress=min(0.99, n / expected), frames=n, fps=round(n / max(1e-6, time.time() - t0), 1))
        for p in vstream.encode(None):
            dst.mux(p)
        if aud:
            _write_audio(dst, aud[0], s["audio_out"])
    return {"frames": n, "seconds": round(n / float(fps), 3), "width": w, "height": h, "fps": float(fps),
            "encoder": vstream.codec_context.name, "audio": a, "took": round(time.time() - t0, 1)}


def segment(s: dict[str, Any]) -> dict[str, Any]:
    """Ein Abschnitt fuer SeedVR2: Bilder [first, first + count) der aufbereiteten Folge (Bildnummern bei out_fps),
    verlustfrei als FFV1 in s["out"]."""
    fps = Fraction(*s["out_fps"])
    first, count = int(s["first"]), int(s["count"])
    base = float(s.get("start") or 0.0)
    start = base + first / float(fps)
    w, h = (int(v) for v in s["size"])
    n = 0
    with av.open(s["out"], "w", format="matroska") as dst:
        vs = dst.add_stream("ffv1", rate=fps)
        vs.width, vs.height, vs.pix_fmt = w, h, "yuv420p"
        vs.options = {"level": "3", "slices": "16", "g": "1"}
        for f in frames(s, start, None):
            if n >= count:
                break
            f.pts, f.time_base = n, 1 / fps
            n += 1
            for p in vs.encode(f):
                dst.mux(p)
        for p in vs.encode(None):
            dst.mux(p)
    return {"frames": n, "first": first}


def cadence_map(s: dict[str, Any]) -> dict[str, Any]:
    """Fuer „Takt glaetten“: je Schritt (Bild k -> k+1 der aufbereiteten Folge) kurz (20 ms) oder lang (40 ms), dazu
    Szenenschnitte. Bewegung von Bild zu Bild in 160 x 90, je Fenster von 90 Schritten (Versatz 45) die Phase des
    kurzen Schritts im Dreierrhythmus (kleinstes Verhaeltnis zu den Nachbarschritten); Fenster ohne Bewegung erben die
    letzte sichere Phase. Echtes Band 28.10.: im 20-s-Clip alle 599 Schritte in derselben Phase. Schnitt = Schritt mit
    mehr als 4-facher Bewegung der Umgebung und ueber 12: dort keine Mitte rechnen, sondern das Bild wiederholen."""
    low = {**s, "size": [160, 90], "denoise": "off", "chroma_denoise": False, "sharpen": "off", "deblock": False,
           "levels": False, "deflicker": False,
           "stabilize": False, "chroma_shift": 0}
    grays = [f.to_ndarray()[:90].astype(np.float32) for f in frames(low, float(s.get("start") or 0.0), s.get("duration"))]
    if len(grays) < 3:
        return {"short": "", "cut": "", "steps": max(0, len(grays) - 1)}
    m = np.abs(np.diff(np.stack(grays), axis=0)).mean(axis=(1, 2))
    n = len(m)
    ratio = np.ones_like(m)
    ratio[1:-1] = m[1:-1] / ((m[:-2] + m[2:]) / 2 + 1e-6)
    phase = np.full(n, -1)
    best = np.zeros(n)
    k = np.arange(n)
    win = 90
    for st in range(0, max(1, n - win + 1), win // 2):
        r, kk = ratio[st:st + win], k[st:st + win]
        score = [float(np.median(r[(kk % 3) == p])) if ((kk % 3) == p).any() else 9.0 for p in range(3)]
        order = np.argsort(score)
        sure = score[order[1]] - score[order[0]]
        if sure >= 0.15:
            take = sure > best[st:st + win]
            phase[st:st + win][take] = order[0]
            best[st:st + win][take] = sure
    known = np.nonzero(phase >= 0)[0]
    if len(known):
        last = phase[known[0]]
        for i in range(n):
            if phase[i] >= 0:
                last = phase[i]
            else:
                phase[i] = last
        short = (k % 3) == phase
    else:
        short = (k % 3) == 2                                 # ohne jede Bewegung: egal, Hauptsache 5 auf 3
    local = np.array([np.median(m[max(0, i - 15):i + 16]) for i in range(n)])
    cut = (m > 4 * local) & (m > 12)
    return {"short": "".join("1" if v else "0" for v in short), "cut": "".join("1" if v else "0" for v in cut),
            "steps": n, "cuts": int(cut.sum()), "sure": round(float(best[best > 0].mean()) if (best > 0).any() else 0, 2),
            "phases": {str(p): int((phase == p).sum()) for p in range(3)}}


def _read_frames(path: str) -> list[np.ndarray]:
    with av.open(path) as c:
        return [f.to_ndarray(format="rgb24") for f in c.decode(video=0)]


def part(s: dict[str, Any]) -> dict[str, Any]:
    """SeedVR2-Abschnitt s["src"] (FFV1) kodieren: die ersten s["overlap"] Bilder mit dem Ende des vorigen Abschnitts
    (s["tail_in"]) linear ueberblenden, die letzten s["overlap"] Bilder als s["tail_out"] fuer den naechsten aufheben
    (beim letzten Abschnitt nicht). Gleiche Kodierung fuer alle Teile, damit concat sie ohne neues Kodieren
    aneinanderhaengen kann."""
    fps = Fraction(*s["out_fps"])
    k = int(s.get("overlap") or 0)
    seg = _read_frames(s["src"])
    select = s.get("select")
    if select is not None:
        # Takt glaetten: aus Originalen und RIFE-Mitten (2n-1 Bilder) die gewaehlten, die Ueberlappung zaehlt dann in
        # Ausgabebildern (tail_from), der vorige Abschnitt hat genau so viele als Ende abgelegt
        seg = [seg[min(int(i), len(seg) - 1)] for i in select]
    tail = _read_frames(s["tail_in"]) if s.get("tail_in") and Path(s["tail_in"]).exists() else []
    m = 0
    if tail:
        m = min(len(tail), len(seg)) if select is not None else min(len(tail), k, len(seg))
        for i in range(m):
            a = (i + 1) / (m + 1)
            seg[i] = (tail[i].astype(np.float32) * (1 - a) + seg[i].astype(np.float32) * a + 0.5).astype(np.uint8)
    if s.get("last") or not k:
        keep, rest = seg, []
    elif s.get("tail_from") is not None:
        keep, rest = seg[:int(s["tail_from"])], seg[int(s["tail_from"]):]
    else:
        keep, rest = seg[:-k], seg[-k:]
    h, w = seg[0].shape[:2]
    with av.open(s["out"], "w", format="mp4") as dst:
        vs = _video_stream(dst, s.get("codec", "h264"), w, h, fps, s.get("bitrate"))
        for i, arr in enumerate(keep):
            f = av.VideoFrame.from_ndarray(arr, format="rgb24").reformat(format="yuv420p")
            f.pts, f.time_base = i, 1 / fps
            for p in vs.encode(f):
                dst.mux(p)
        for p in vs.encode(None):
            dst.mux(p)
    if rest:
        with av.open(s["tail_out"], "w", format="matroska") as dst:
            ts = dst.add_stream("ffv1", rate=fps)
            ts.width, ts.height, ts.pix_fmt = w, h, "bgr0"
            ts.options = {"level": "3", "g": "1"}
            for i, arr in enumerate(rest):
                f = av.VideoFrame.from_ndarray(arr, format="rgb24")
                f.pts, f.time_base = i, 1 / fps
                for p in ts.encode(f):
                    dst.mux(p)
            for p in ts.encode(None):
                dst.mux(p)
    return {"frames": len(keep), "tail": len(rest), "blended": m}


def concat(s: dict[str, Any]) -> dict[str, Any]:
    """Teile (gleich kodiert) Paket fuer Paket in eine Datei, Zeitstempel fortlaufend; Ton aus s["audio_out"]."""
    parts = [p for p in s["parts"] if Path(p).exists()]
    if not parts:
        raise SystemExit("keine Teile")
    n = 0
    with av.open(parts[0]) as first:
        template = first.streams.video[0]
        rate = Fraction(template.average_rate or template.guessed_rate).limit_denominator(1001)
        with av.open(s["out"], "w", options={"movflags": "+faststart"}) as dst:
            vs = dst.add_stream_from_template(template)
            aud = _mux_audio(dst, s.get("audio_out"))
            offset = 0
            for path in parts:
                with av.open(path) as c:
                    src = c.streams.video[0]
                    step = int(round(1 / (rate * src.time_base)))
                    last = 0
                    for packet in c.demux(src):
                        if packet.dts is None:
                            continue
                        packet.pts = (packet.pts or 0) + offset
                        packet.dts = packet.dts + offset
                        last = max(last, packet.pts)
                        packet.stream = vs
                        dst.mux(packet)
                        n += 1
                    offset = last + step
            if aud:
                _write_audio(dst, aud[0], s["audio_out"])
    return {"packets": n, "parts": len(parts)}


def main(argv: list[str]) -> None:
    cmd = argv[0] if argv else ""
    if cmd == "analyze" and len(argv) == 3:
        result = analyze(argv[1], argv[2])
    elif cmd in ("run", "audio", "segment", "part", "concat", "cadence") and len(argv) == 2:
        s = json.loads(Path(argv[1]).read_text(encoding="utf-8"))
        result = {"run": run, "audio": audio, "segment": segment, "part": part, "concat": concat,
                  "cadence": cadence_map}[cmd](s)
    else:
        raise SystemExit(__doc__)
    emit(result=result)


if __name__ == "__main__":
    main(sys.argv[1:])
