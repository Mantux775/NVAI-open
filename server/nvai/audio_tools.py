"""Werkzeuge des Bereichs „Audio“ (seit 17.11.2026). Läuft im ComfyUI-venv (PyAV, soundfile, scipy, numpy, torch),
nicht im Server: python -I audio_tools.py <befehl> <einstellungen.json>. Fortschritt und Ergebnis als JSON-Zeilen
({"progress": 0.4, "stage": "…"} … {"result": {…}}), wie vhs_tools.py.

Für Aufnahmen von mehreren Stunden: Alles läuft in Blöcken (nie die ganze Datei im Speicher), Zwischenstände der
KI-Schritte liegen je Abschnitt im Arbeitsordner, ein abgebrochener Lauf setzt dort fort.
"""
from __future__ import annotations

import json
import math
from fractions import Fraction
import os
import sys
import time
from pathlib import Path
from typing import Any, Callable, Iterator

# Eigene kleine Umgebung (external/audio/.venv) ohne PyTorch: torch, numpy, scipy, soundfile und PyAV kommen aus dem
# venv von ComfyUI, hinten an sys.path (eigene Pakete gehen vor), wie beim Stimm-Worker.
_torch_site = os.environ.get("NVAI_AUDIO_TORCH_SITE", "")
if _torch_site and Path(_torch_site).is_dir() and _torch_site not in sys.path:
    sys.path.append(_torch_site)

import numpy as np  # noqa: E402

BLOCK_SECONDS = 20.0          # Lesen/Schreiben in Blöcken
PEAK_SPB = 256                # Proben je Wellenform-Balken (48 kHz: 187,5 Balken je Sekunde)
PROXY_KBPS = 128              # Opus-Vorschau in WebM zum Abspielen im Browser (Sprungverzeichnis, 4,5-mal schneller
                              # kodiert als MP3 160: 0,5 statt 2,3 s je Minute Ton, gemessen 17.11.2026)


def emit(**kw: Any) -> None:
    # nur ASCII: mit -I gilt PYTHONIOENCODING nicht, Umlaute kämen in der Codepage an („Töne suchen“ → „T�ne suchen“)
    print(json.dumps(kw, ensure_ascii=True), flush=True)


def progress(frac: float, stage: str = "") -> None:
    emit(progress=round(max(0.0, min(1.0, frac)), 4), stage=stage)


_LANG = "de"


def set_lang(code: Any) -> None:
    """Sprache der Meldungen (der Server gibt sie in den Einstellungen mit); die Modell-Bausteine lesen NVAI_LANG."""
    global _LANG
    _LANG = "en" if str(code or "de").lower().startswith("en") else "de"
    os.environ["NVAI_LANG"] = _LANG


def L(de: str, en: str) -> str:
    return de if _LANG == "de" else en


# --------------------------------------------------------------------------------------------- Lesen, Schreiben

def probe(path: str) -> dict[str, Any]:
    import av
    with av.open(path) as c:
        a = next((s for s in c.streams if s.type == "audio"), None)
        v = next((s for s in c.streams if s.type == "video"), None)
        dur = None
        if c.duration:
            dur = float(c.duration) / 1_000_000
        elif a is not None and a.duration and a.time_base:
            dur = float(a.duration * a.time_base)
        out: dict[str, Any] = {"duration": dur, "has_audio": a is not None, "has_video": v is not None,
                               "container": c.format.name, "bit_rate": c.bit_rate}
        if a is not None:
            out.update({"sample_rate": a.rate, "channels": a.channels, "codec": a.codec_context.name,
                        "audio_streams": sum(1 for s in c.streams if s.type == "audio")})
        if v is not None:
            out["video"] = {"codec": v.codec_context.name, "width": v.codec_context.width,
                            "height": v.codec_context.height,
                            "fps": float(v.average_rate) if v.average_rate else None}
        return out


def decode_blocks(path: str, sr: int, channels: int, block_seconds: float = BLOCK_SECONDS,
                  start: float = 0.0, end: float | None = None, stats: dict[str, Any] | None = None) -> Iterator[np.ndarray]:
    """Tonspur in Blöcken als float32 (Proben, Kanäle) mit Rate sr; start/end in Sekunden (Auswahl). Ein beschädigtes
    Paket (kaputter AAC- oder MP3-Rahmen) bricht das Lesen nicht ab: Es wird Stille seiner Länge, damit die Zeit danach
    stimmt, gezählt in stats["decode_errors"]."""
    import av
    layout = "mono" if channels == 1 else "stereo"
    target = max(1, int(block_seconds * sr))
    first = int(round(start * sr))
    last = int(round(end * sr)) if end is not None else None
    pos = 0  # Probe der Ausgabe ab Dateianfang
    bad = good = 0
    with av.open(path) as c:
        a = next(s for s in c.streams if s.type == "audio")
        # Zeit 0 = erste Probe der Spur. Die Zeitstempel beginnen bei der Startzeit des Tonstroms: bei MP3 der Vorlauf
        # des Kodierers (1105 Proben, ffmpeg schneidet ihn per LAME-Tag ab), bei MPEG-TS z. B. 1,4 s. Ohne Abzug lag
        # ein Ausschnitt ab 2 s um diese Zeit falsch (MP3: 23 ms bei 48 kHz), der Lauf von vorn nicht.
        t0 = float(a.start_time * a.time_base) if a.start_time is not None and a.time_base else 0.0
        if start > 2:
            c.seek(int((max(0.0, start - 1) + t0) / a.time_base), stream=a, any_frame=False, backward=True)
        res = av.AudioResampler(format="flt", layout=layout, rate=sr)
        buf: list[np.ndarray] = []
        n = 0
        started = start <= 2
        done = False
        frame_len = 0  # Länge des letzten Rahmens in Proben der Ausgabe (für Pakete ohne Dauer)

        def frames() -> Iterator[Any]:
            nonlocal bad, good, frame_len
            for packet in c.demux(a):
                try:
                    got = packet.decode()
                except av.error.FFmpegError:
                    bad += 1
                    dur = float(packet.duration * packet.time_base) if packet.duration and packet.time_base else 0.0
                    yield int(round(dur * sr)) if dur > 0 else frame_len
                    continue
                for frame in got:
                    good += 1
                    if frame.sample_rate:
                        frame_len = int(round(frame.samples * sr / frame.sample_rate))
                    yield frame
            yield None  # Resampler leeren

        def chunks(frame: Any) -> list[np.ndarray]:
            if isinstance(frame, int):  # Stille für ein beschädigtes Paket (erst, wenn die Lage feststeht)
                return [np.zeros((frame, channels), np.float32)] if frame > 0 and started else []
            return [f.to_ndarray().reshape(-1, channels).astype(np.float32, copy=False) for f in res.resample(frame)]

        for frame in frames():
            if frame is not None and not isinstance(frame, int) and not started:
                pos = int(round((float(frame.pts * frame.time_base) - t0) * sr)) if frame.pts is not None else 0
                started = True
            for arr in chunks(frame):
                lo, hi = pos, pos + len(arr)
                pos = hi
                if hi <= first:
                    continue
                if lo < first:
                    arr = arr[first - lo:]
                if last is not None and pos > last:
                    arr = arr[: max(0, len(arr) - (pos - last))]
                    done = True
                if len(arr):
                    buf.append(arr)
                    n += len(arr)
                while n >= target:
                    data = np.concatenate(buf)
                    yield data[:target]
                    rest = data[target:]
                    buf, n = ([rest] if len(rest) else []), len(rest)
                if done:
                    break
            if done:
                break
        if n:
            yield np.concatenate(buf)
    if stats is not None:
        stats["decode_errors"] = bad
    if bad and not good:
        raise SystemExit(L("Die Tonspur lässt sich nicht dekodieren (jedes Paket beschädigt).",
                           "The audio track cannot be decoded (every packet is damaged)."))


def read_blocks(path: str, block_seconds: float = BLOCK_SECONDS, start: int = 0,
                frames: int | None = None) -> Iterator[np.ndarray]:
    """Eine Arbeitsdatei (FLAC/WAV) blockweise lesen, float32 (Proben, Kanäle)."""
    import soundfile as sf
    with sf.SoundFile(path) as f:
        step = int(block_seconds * f.samplerate)
        f.seek(start)
        left = frames if frames is not None else f.frames - start
        while left > 0:
            data = f.read(min(step, left), dtype="float32", always_2d=True)
            if not len(data):
                break
            left -= len(data)
            yield data


def info(path: str) -> tuple[int, int, int]:
    import soundfile as sf
    i = sf.info(path)
    return i.samplerate, i.channels, i.frames


class Peaks:
    """Wellenform: je PEAK_SPB Proben ein Paar (min, max) als int8, Kanäle zusammengefasst."""

    def __init__(self) -> None:
        self.rest = np.zeros(0, np.float32)
        self.rest_min = np.zeros(0, np.float32)
        self.parts: list[np.ndarray] = []

    def add(self, block: np.ndarray) -> None:
        mono = block.max(axis=1) if block.ndim == 2 else block
        mono_min = block.min(axis=1) if block.ndim == 2 else block
        data_max = np.concatenate([self.rest, mono]) if len(self.rest) else mono
        data_min = np.concatenate([self.rest_min, mono_min]) if len(self.rest) else mono_min
        whole = len(data_max) // PEAK_SPB * PEAK_SPB
        if whole:
            mx = data_max[:whole].reshape(-1, PEAK_SPB).max(axis=1)
            mn = data_min[:whole].reshape(-1, PEAK_SPB).min(axis=1)
            pair = np.empty((len(mx), 2), np.int8)
            pair[:, 0] = np.clip(np.round(mn * 127), -127, 127)
            pair[:, 1] = np.clip(np.round(mx * 127), -127, 127)
            self.parts.append(pair)
        self.rest = data_max[whole:].copy()
        self.rest_min = data_min[whole:].copy()

    def save(self, path: Path) -> int:
        if len(self.rest):
            pair = np.array([[np.clip(round(float(self.rest_min.min()) * 127), -127, 127),
                              np.clip(round(float(self.rest.max()) * 127), -127, 127)]], np.int8)
            self.parts.append(pair)
            self.rest = np.zeros(0, np.float32)
        data = np.concatenate(self.parts) if self.parts else np.zeros((0, 2), np.int8)
        path.parent.mkdir(parents=True, exist_ok=True)
        data.tofile(path)
        return len(data)


class Proxy:
    """Abspiel-Vorschau (Opus in WebM, mit Sprungverzeichnis) blockweise schreiben."""

    def __init__(self, path: Path, sr: int, channels: int, kbps: int | None = None, rate: int = 48000,
                 options: dict[str, str] | None = None) -> None:
        # rate/kbps/options: VDR-Spuren (vdr.py) mit 16 kHz mono, 24 kbit/s, compression_level 5
        import av
        path.parent.mkdir(parents=True, exist_ok=True)
        self.tmp = path.with_name(path.stem + ".part.webm")
        self.path = path
        self.c = av.open(str(self.tmp), "w", format="webm")
        self.s = self.c.add_stream("libopus", rate=rate if rate in (8000, 12000, 16000, 24000, 48000) else 48000,
                                   options=options or {})
        self.s.layout = "mono" if channels == 1 else "stereo"
        self.s.bit_rate = (kbps or PROXY_KBPS) * 1000
        self.sr_in = sr
        self.channels = channels
        self.res = av.AudioResampler(format="fltp", layout=self.s.layout, rate=self.s.rate)

    def add(self, block: np.ndarray) -> None:
        import av
        frame = av.AudioFrame.from_ndarray(np.ascontiguousarray(block.reshape(1, -1), dtype=np.float32),
                                           format="flt", layout="mono" if self.channels == 1 else "stereo")
        frame.sample_rate = self.sr_in
        for f in self.res.resample(frame):
            for p in self.s.encode(f):
                self.c.mux(p)

    def close(self) -> None:
        for f in self.res.resample(None):
            for p in self.s.encode(f):
                self.c.mux(p)
        for p in self.s.encode(None):
            self.c.mux(p)
        self.c.close()
        os.replace(self.tmp, self.path)


class Writer:
    """Spur schreiben: FLAC (24 bit) + Wellenform + MP3-Vorschau in einem Durchgang."""

    def __init__(self, flac: Path, sr: int, channels: int, peaks: Path | None, proxy: Path | None,
                 subtype: str = "PCM_24", proxy_kbps: int | None = None, proxy_rate: int = 48000,
                 proxy_options: dict[str, str] | None = None) -> None:
        import soundfile as sf
        flac.parent.mkdir(parents=True, exist_ok=True)
        self.tmp = flac.with_name(flac.stem + ".part.flac")
        self.flac = flac
        self.f = sf.SoundFile(str(self.tmp), "w", samplerate=sr, channels=channels, format="FLAC", subtype=subtype)
        self.peaks = Peaks() if peaks else None
        self.peaks_path = peaks
        self.proxy = Proxy(proxy, sr, channels, proxy_kbps, proxy_rate, proxy_options) if proxy else None
        self.frames = 0
        self.peak = 0.0

    def add(self, block: np.ndarray) -> None:
        block = np.clip(block, -1.0, 1.0)
        if np.isnan(block).any():  # NaN (beschädigte Float-Quelle, Modell): als Stille, PCM kennt kein NaN
            block = np.nan_to_num(block, copy=False, nan=0.0)
        self.f.write(block)
        self.frames += len(block)
        if len(block):
            self.peak = max(self.peak, float(np.abs(block).max()))
        if self.peaks:
            self.peaks.add(block)
        if self.proxy:
            self.proxy.add(block)

    def close(self) -> dict[str, Any]:
        self.f.close()
        os.replace(self.tmp, self.flac)
        bars = self.peaks.save(self.peaks_path) if self.peaks and self.peaks_path else 0
        if self.proxy:
            self.proxy.close()
        return {"frames": self.frames, "bars": bars, "peak": round(self.peak, 4)}


# --------------------------------------------------------------------------------------------- Messen

class Loudness:
    """Integrierte Lautheit nach ITU-R BS.1770-4 (K-Filter, 400-ms-Fenster, absolutes und relatives Gate),
    blockweise; dazu Rauschboden (10. Perzentil der 100-ms-Pegel), Spitze und übersteuerte Proben."""

    def __init__(self, sr: int, channels: int) -> None:
        from scipy import signal
        self.sr = sr
        # Hochregal (Kopf) und Hochpass (RLB), Koeffizienten für beliebige Raten über die Analogvorlage
        f0, g, q = 1681.974450955533, 3.999843853973347, 0.7071752369554196
        k = math.tan(math.pi * f0 / sr)
        vh = 10 ** (g / 20)
        vb = vh ** 0.4996667741545416
        a0 = 1 + k / q + k * k
        shelf_b = [(vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0]
        shelf_a = [1.0, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0]
        f0, q = 38.13547087602444, 0.5003270373238773
        k = math.tan(math.pi * f0 / sr)
        hp_b = [1.0, -2.0, 1.0]
        hp_a = [1.0, 2 * (k * k - 1) / (1 + k / q + k * k), (1 - k / q + k * k) / (1 + k / q + k * k)]
        self.sos = np.array([shelf_b + shelf_a, hp_b + hp_a])
        self.zi = np.zeros((channels, 2, 2))
        self.signal = signal
        self.slice = int(sr * 0.1)
        self.rest = np.zeros((0, channels), np.float32)
        self.rest_raw = np.zeros((0, channels), np.float32)
        self.ms: list[float] = []      # gewichtete mittlere Quadrate je 100 ms
        self.rms: list[float] = []     # ungewichteter Pegel je 100 ms
        self.peak = 0.0
        self.clipped = 0

    def add(self, block: np.ndarray) -> None:
        if not np.isfinite(block).all():
            # NaN/Unendlich aus Float-Quellen: Sonst wurden Spitze und Pegel NaN/Infinity, und jede Antwort mit dem
            # Projekt scheiterte (JSON kennt beides nicht). Wie in der geschriebenen Spur: NaN als Stille, ±∞ als ±1
            block = np.nan_to_num(block, nan=0.0, posinf=1.0, neginf=-1.0)
        self.peak = max(self.peak, float(np.abs(block).max()) if len(block) else 0.0)
        self.clipped += int((np.abs(block) >= 0.999).sum())
        w = np.empty_like(block, dtype=np.float64)
        for ch in range(block.shape[1]):
            w[:, ch], self.zi[ch] = self.signal.sosfilt(self.sos, block[:, ch], zi=self.zi[ch])
        data = np.concatenate([self.rest, w]) if len(self.rest) else w
        raw = np.concatenate([self.rest_raw, block]) if len(self.rest_raw) else block
        whole = len(data) // self.slice * self.slice
        if whole:
            sl = data[:whole].reshape(-1, self.slice, data.shape[1])
            self.ms.extend((sl ** 2).mean(axis=1).sum(axis=1).tolist())
            rl = raw[:whole].reshape(-1, self.slice, raw.shape[1]).astype(np.float64)
            self.rms.extend(np.sqrt((rl ** 2).mean(axis=(1, 2))).tolist())
        self.rest = data[whole:]
        self.rest_raw = raw[whole:]

    def result(self) -> dict[str, Any]:
        ms = np.array(self.ms)
        if len(ms) < 4:
            return {"lufs": None, "noise_floor_db": None, "peak_db": None, "clipped": self.clipped}
        win = np.convolve(ms, np.ones(4) / 4, mode="valid")  # 400 ms, 75 % Überlappung
        lk = -0.691 + 10 * np.log10(np.maximum(win, 1e-12))
        gated = win[lk > -70]
        lufs = None
        if len(gated):
            rel = -0.691 + 10 * np.log10(gated.mean()) - 10
            g2 = gated[(-0.691 + 10 * np.log10(np.maximum(gated, 1e-12))) > rel]
            if len(g2):
                lufs = round(float(-0.691 + 10 * np.log10(g2.mean())), 1)
        rms = np.array(self.rms)
        floor = float(np.percentile(rms[rms > 1e-7], 10)) if (rms > 1e-7).any() else 0.0
        return {"lufs": lufs, "noise_floor_db": round(20 * math.log10(max(floor, 1e-7)), 1),
                "peak_db": round(20 * math.log10(max(self.peak, 1e-7)), 1), "clipped": self.clipped,
                "levels_db": [round(20 * math.log10(max(x, 1e-7)), 1) for x in rms[:: max(1, len(rms) // 2000)]]}


def detect_hum(path: str, sr: int, channels: int, duration: float) -> dict[str, Any]:
    """Netzbrummen: Spektrum über bis zu 10 Stellen à 6 s; Pegel bei 50/60 Hz und Oberwellen gegen die Nachbarn."""
    from scipy import signal
    picks = np.linspace(0, max(0.0, duration - 6), num=min(10, max(1, int(duration // 6))))
    spec = None
    for t0 in picks:
        block = next(decode_blocks(path, sr, channels, 6.0, start=float(t0), end=float(t0) + 6.0), None)
        if block is None or len(block) < sr:
            continue
        f, p = signal.welch(block.mean(axis=1), fs=sr, nperseg=sr * 2)
        spec = p if spec is None else spec + p
    if spec is None:
        return {"hum": None}
    res: dict[str, Any] = {}
    for base in (50, 60):
        excess = []
        for h in range(1, 6):
            fr = base * h
            i = int(round(fr / (f[1] - f[0])))
            if i + 6 >= len(spec):
                break
            around = np.median(np.r_[spec[i - 6:i - 2], spec[i + 3:i + 7]])
            excess.append(10 * math.log10(max(spec[i - 1:i + 2].max(), 1e-20) / max(around, 1e-20)))
        res[base] = excess
    best = max(res, key=lambda b: sum(sorted(res[b], reverse=True)[:3]))
    strength = sum(sorted(res[best], reverse=True)[:3]) / 3
    return {"hum": {"freq": best, "db_over_floor": round(strength, 1), "harmonics_db": [round(x, 1) for x in res[best]],
                    "present": strength > 8}}


# --------------------------------------------------------------------------------------------- Befehle

def cmd_probe(s: dict[str, Any]) -> dict[str, Any]:
    return probe(s["src"])


def cmd_prepare(s: dict[str, Any]) -> dict[str, Any]:
    """Quelle (Audio oder Video) einlesen: Arbeitsdatei FLAC, Wellenform, MP3-Vorschau, Messwerte."""
    pr = probe(s["src"])
    if not pr.get("has_audio"):
        raise SystemExit(L("Die Datei hat keine Tonspur.", "The file has no audio track."))
    sr = int(s.get("sr") or pr["sample_rate"] or 48000)
    sr = sr if sr in (44100, 48000) else (44100 if sr % 11025 == 0 else 48000)
    channels = 1 if (pr.get("channels") or 2) == 1 else 2
    duration = float(pr.get("duration") or 0) or None
    w = Writer(Path(s["flac"]), sr, channels, Path(s["peaks"]), Path(s["proxy"]))
    loud = Loudness(sr, channels)
    done = 0
    stats: dict[str, Any] = {}
    for block in decode_blocks(s["src"], sr, channels, start=float(s.get("start") or 0), end=s.get("end"), stats=stats):
        w.add(block)
        loud.add(block)
        done += len(block)
        if duration:
            progress(0.95 * done / (duration * sr), L("einlesen", "reading"))
    out = w.close()
    real = out["frames"] / sr
    progress(0.96, L("Brummen", "hum"))
    hum = detect_hum(str(s["flac"]), sr, channels, real)
    analysis = {**loud.result(), **hum}
    if stats.get("decode_errors"):
        analysis["decode_errors"] = stats["decode_errors"]
    return {"probe": pr, "sample_rate": sr, "channels": channels, "duration": round(real, 3), **out,
            "analysis": analysis}


def _filter_graph(chain: list[dict[str, Any]], sr: int, channels: int, gain_db: float) -> tuple[Any, Any, Any]:
    """ffmpeg-Filter über PyAV: Brummen (Kerbfilter je Oberwelle), Trittschall, klassisches Entrauschen, Pegel."""
    import av
    g = av.filter.Graph()
    layout = "mono" if channels == 1 else "stereo"
    src = g.add_abuffer(format="flt", sample_rate=sr, layout=layout, time_base=f"1/{sr}")
    last = src
    for step in chain:
        kind = step.get("type")
        nodes: list[tuple[str, str]] = []
        if kind == "hum":
            base = float(step.get("freq") or 50)
            for h in range(1, int(step.get("harmonics") or 5) + 1):
                if base * h < sr / 2 - 100:
                    nodes.append(("bandreject", f"f={base * h}:width_type=q:w={float(step.get('q') or 30)}"))
        elif kind == "highpass":
            nodes.append(("highpass", f"f={float(step.get('freq') or 80)}:poles=2"))
        elif kind == "linewhistle":
            # Zeilenfrequenz von Röhrenfernsehern/Videorekordern: PAL 15 625 Hz, NTSC 15 734 Hz
            fr = float(step.get("freq") or 15625)
            if fr < sr / 2 - 50:
                nodes.append(("bandreject", f"f={fr}:width_type=q:w=40"))
        elif kind == "lowpass":
            # unter der Nyquist-Grenze bleiben (VDR-Spuren haben 16 kHz)
            nodes.append(("lowpass", f"f={min(float(step.get('freq') or 12000), sr / 2 - 200)}:poles=2"))
        elif kind == "denoise":
            nr = {"light": 8, "medium": 14, "strong": 22}.get(step.get("strength") or "light", 8)
            nodes.append(("afftdn", f"nr={nr}:nf={float(step.get('floor_db') or -50)}:tn=1"))
        elif kind == "declick":
            nodes.append(("adeclick", ""))
        elif kind == "level":
            nodes.append(("dynaudnorm", "f=500:g=31:p=0.9:m=8"))
        elif kind == "deess":
            nodes.append(("deesser", "i=0.4"))
        for name, args in nodes:
            n = g.add(name, args) if args else g.add(name)
            last.link_to(n)
            last = n
    if abs(gain_db) > 0.01:
        n = g.add("volume", f"volume={gain_db}dB")
        last.link_to(n)
        last = n
    if any(st.get("type") == "loudness" for st in chain):
        n = g.add("alimiter", "limit=0.891:level=false")  # −1 dBFS
        last.link_to(n)
        last = n
    # Ausgabe immer verschränkt als float32: Die meisten Filter liefern planar (fltp, dblp), _through liest verschränkt.
    # Ohne diesen Schritt kamen bei Stereo die Proben beider Kanäle durcheinander (gemessen 21.11.: links ein Sinus,
    # rechts Stille ergab nach dem Trittschallfilter auf beiden Seiten denselben Pegel)
    n = g.add("aformat", f"sample_fmts=flt:channel_layouts={layout}")
    last.link_to(n)
    last = n
    sink = g.add("abuffersink")
    last.link_to(sink)
    g.configure()
    return g, src, sink


def _through(abuf: Any, sink: Any, blocks: Iterator[np.ndarray], sr: int, channels: int,
             out: Callable[[np.ndarray], None], step: Callable[[int], None]) -> None:
    """Blöcke (Proben, Kanäle) durch einen Filtergraphen aus _filter_graph; out bekommt die Ausgabe, step die Zahl der
    eingespeisten Proben."""
    import av
    layout = "mono" if channels == 1 else "stereo"
    pts = 0

    def pull() -> None:
        while True:
            try:
                f = sink.pull()
            except (av.BlockingIOError, av.EOFError):
                return
            out(f.to_ndarray().reshape(-1, channels).astype(np.float32, copy=False))

    for block in blocks:
        frame = av.AudioFrame.from_ndarray(np.ascontiguousarray(block.reshape(1, -1)), format="flt", layout=layout)
        frame.sample_rate = sr
        frame.pts = pts
        frame.time_base = Fraction(1, sr)
        pts += len(block)
        abuf.push(frame)
        pull()
        step(pts)
    abuf.push(None)
    pull()


def cmd_process(s: dict[str, Any]) -> dict[str, Any]:
    """Klassische Bearbeitung einer Spur (ohne KI): Filterkette, dann Lautheit auf ein Ziel (zwei Durchgänge:
    erst messen, dann mit festem Pegel und Begrenzer)."""
    src = s["src"]
    sr, channels, frames = info(src)
    first, frames = (int(s["region"][0]), int(s["region"][1])) if s.get("region") else (0, frames)
    chain = s.get("chain") or []
    gain = 0.0
    target = next((float(st.get("target") or -16) for st in chain if st.get("type") == "loudness"), None)
    if target is not None:
        # Gemessen wird hinter derselben Filterkette (ohne Pegel und Begrenzer): Die Kette ändert die Lautheit
        # („Pegel angleichen“ hebt leise Stellen kräftig an). An der unbearbeiteten Spur gemessen verfehlte das Ergebnis
        # das Ziel und lief in den Begrenzer.
        loud = Loudness(sr, channels)
        _g0, abuf0, sink0 = _filter_graph([st for st in chain if st.get("type") != "loudness"], sr, channels, 0.0)
        _through(abuf0, sink0, read_blocks(src, start=first, frames=frames), sr, channels, loud.add,
                 lambda done: progress(0.25 * min(1.0, done / max(1, frames)), L("messen", "measuring")))
        lufs = loud.result()["lufs"]
        gain = (target - lufs) if lufs is not None else 0.0
    _g, abuf, sink = _filter_graph(chain, sr, channels, gain)
    w = Writer(Path(s["flac"]), sr, channels, Path(s["peaks"]), Path(s["proxy"]))
    loud2 = Loudness(sr, channels)

    def keep(arr: np.ndarray) -> None:
        w.add(arr)
        loud2.add(arr)

    base = 0.25 if target is not None else 0.0
    _through(abuf, sink, read_blocks(src, start=first, frames=frames), sr, channels, keep,
             lambda done: progress(base + (0.98 - base) * min(1.0, done / max(1, frames)), L("bearbeiten", "processing")))
    out = w.close()
    return {**out, "sample_rate": sr, "channels": channels, "gain_db": round(gain, 2),
            "analysis": loud2.result()}


def cmd_export(s: dict[str, Any]) -> dict[str, Any]:
    """Spuren mischen (Pegel je Spur) und schreiben: wav/flac/mp3/opus, oder den Ton eines Videos ersetzen."""
    import av
    import soundfile as sf
    tracks = [t for t in s["tracks"] if not t.get("mute")]
    if not tracks:
        raise SystemExit(L("Keine Spur zum Mischen.", "No track to mix."))
    sr, channels, frames = info(tracks[0]["file"])
    for t in tracks[1:]:
        sr2, _, fr2 = info(t["file"])
        if sr2 != sr:
            raise SystemExit(L("Spuren mit verschiedener Abtastrate.", "Tracks with different sample rates."))
        frames = max(frames, fr2)
    # Ausschnitt (Ton-Forensik: Export einer Auswahl)
    first = 0
    if s.get("region"):
        a0, b0 = (float(x) for x in s["region"][:2])
        first = max(0, min(frames, int(round(a0 * sr))))
        frames = max(0, min(frames, int(round(b0 * sr))) - first)
    readers = [read_blocks(t["file"], start=first, frames=frames) for t in tracks]
    gains = [10 ** (float(t.get("gain_db") or 0) / 20) for t in tracks]
    if s.get("mono"):
        channels = 1
    fmt = s.get("format") or "wav"
    out = Path(s["out"])
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_name(out.stem + ".part" + out.suffix)
    peak = 0.0

    def mixed() -> Iterator[np.ndarray]:
        while True:
            blocks = []
            for r in readers:
                b = next(r, None)
                blocks.append(b)
            if all(b is None for b in blocks):
                return
            n = max(len(b) for b in blocks if b is not None)
            acc = np.zeros((n, channels), np.float32)
            for b, gn in zip(blocks, gains):
                if b is None:
                    continue
                if b.shape[1] != channels:
                    b = np.repeat(b.mean(axis=1, keepdims=True), channels, axis=1)
                acc[: len(b)] += b * gn
            yield acc

    done = 0
    if fmt in ("wav", "flac"):
        sub = "PCM_24" if fmt == "flac" or s.get("bits") == 24 else "PCM_16"
        container = fmt.upper()
        if fmt == "wav" and frames * channels * (3 if sub == "PCM_24" else 2) > 4_000_000_000:
            container = "RF64"  # über 4 GB kann RIFF-WAV nicht; RF64 lesen Audacity, Reaper, ffmpeg u. a.
        with sf.SoundFile(str(tmp), "w", samplerate=sr, channels=channels, format=container, subtype=sub) as f:
            for acc in mixed():
                peak = max(peak, float(np.abs(acc).max()))
                f.write(np.clip(acc, -1, 1))
                done += len(acc)
                progress(done / max(1, frames), L("mischen", "mixing"))
    else:
        video_src = s.get("video_src")
        c = av.open(str(tmp), "w")
        vin = None
        if video_src:
            vin = av.open(video_src)
            vs = next(st for st in vin.streams if st.type == "video")
            vout = c.add_stream_from_template(vs)
        codec = {"mp3": "libmp3lame", "opus": "libopus", "m4a": "aac", "mp4": "aac", "mkv": "aac"}.get(fmt, "aac")
        rate = 48000 if codec == "libopus" else sr
        st_a = c.add_stream(codec, rate=rate)
        st_a.layout = "mono" if channels == 1 else "stereo"
        st_a.bit_rate = int(s.get("kbps") or (256 if codec == "aac" else 192)) * 1000
        res = av.AudioResampler(format=st_a.codec_context.format.name if st_a.codec_context.format else "fltp",
                                layout=st_a.layout, rate=rate)
        for acc in mixed():
            peak = max(peak, float(np.abs(acc).max()))
            frame = av.AudioFrame.from_ndarray(np.ascontiguousarray(np.clip(acc, -1, 1).reshape(1, -1)), format="flt",
                                               layout="mono" if channels == 1 else "stereo")
            frame.sample_rate = sr
            # Zeitstempel setzen: Dann weist die Datei den Vorlauf des Kodierers aus und der Ton beginnt bei 0 (ohne lag
            # er bei AAC 1024 Proben zu spät: 21 ms bei 48 kHz, 64 ms bei 16 kHz; wie forensic_tools.cmd_videoexport)
            frame.pts = done
            frame.time_base = Fraction(1, sr)
            for f in res.resample(frame):
                for p in st_a.encode(f):
                    c.mux(p)
            done += len(acc)
            progress((0.6 if vin else 1.0) * done / max(1, frames), L("mischen", "mixing"))
        for f in res.resample(None):
            for p in st_a.encode(f):
                c.mux(p)
        for p in st_a.encode(None):
            c.mux(p)
        if vin is not None:
            vs = next(st for st in vin.streams if st.type == "video")
            total = vs.frames or 0
            for i, packet in enumerate(vin.demux(vs)):
                if packet.dts is None:
                    continue
                packet.stream = vout
                c.mux(packet)
                if total and i % 200 == 0:
                    progress(0.6 + 0.4 * min(1.0, i / total), L("Video übernehmen", "copying the video"))
            vin.close()
        c.close()
    os.replace(tmp, out)
    return {"file": str(out), "frames": frames, "sample_rate": sr, "peak": round(peak, 4),
            "size_mb": round(out.stat().st_size / 1024**2, 1)}


def cmd_peaks(s: dict[str, Any]) -> dict[str, Any]:
    sr, channels, frames = info(s["src"])
    pk = Peaks()
    done = 0
    for block in read_blocks(s["src"]):
        pk.add(block)
        done += len(block)
        progress(done / max(1, frames), L("Wellenform", "waveform"))
    return {"bars": pk.save(Path(s["peaks"]))}



# --------------------------------------------------------------------------------------------- KI in Abschnitten

def _adapter(name: str) -> Any:
    """Modell-Baustein aus audio_models/<name>.py: SAMPLE_RATE, CHANNELS, STEMS, CHUNK_SECONDS, OVERLAP_SECONDS,
    load(weights_dir, device, params) und process(model, audio (Proben, Kanäle) float32, params) -> {stem: array}."""
    import importlib
    sys.path.insert(0, str(Path(__file__).parent))
    return importlib.import_module(f"audio_models.{name}")


def _resample(x: np.ndarray, sr_from: int, sr_to: int) -> np.ndarray:
    if sr_from == sr_to:
        return x
    from math import gcd
    from scipy.signal import resample_poly
    g = gcd(sr_from, sr_to)
    return resample_poly(x, sr_to // g, sr_from // g, axis=0).astype(np.float32)


def _to_channels(x: np.ndarray, ch: int) -> np.ndarray:
    if x.shape[1] == ch:
        return x
    if ch == 1:
        return x.mean(axis=1, keepdims=True)
    return np.repeat(x[:, :1], ch, axis=1)


def cmd_ai(s: dict[str, Any]) -> dict[str, Any]:
    """Ein KI-Modell über eine Spur: Fenster von CHUNK_SECONDS mit OVERLAP_SECONDS Überlappung, je Fenster Kanäle
    und Rate auf das Modell bringen, Stems zurück auf die Spur, weich überblenden (cos²/sin²). Jedes Fenster liegt
    als FLAC im Arbeitsordner: Ein abgebrochener Lauf setzt dort fort. Stems, die das Modell nicht liefert, ergeben
    sich als Rest (Mischung minus Ziel), etwa „rest“ bei einer Stimm-Trennung oder „removed“ beim Entrauschen."""
    import soundfile as sf
    import torch

    src = s["src"]
    sr, ch, frames = info(src)
    a = _adapter(s["model"])
    params = s.get("params") or {}
    region = s.get("region")  # [erste Probe, Probenzahl] in der Spur
    first, count = (int(region[0]), int(region[1])) if region else (0, frames)
    count = max(0, min(count, frames - first))
    chunk = int(float(params.get("chunk_seconds") or a.CHUNK_SECONDS) * sr)
    ov = min(int(float(a.OVERLAP_SECONDS) * sr), chunk // 2)
    hop = chunk - ov
    n_win = max(1, math.ceil(max(0, count - ov) / hop)) if count > chunk else 1
    work = Path(s["work_dir"])
    work.mkdir(parents=True, exist_ok=True)
    outs: dict[str, dict[str, str]] = s["outputs"]
    produced = list(a.STEMS)
    want = list(outs)
    device = "cuda" if torch.cuda.is_available() and s.get("device", "cuda") == "cuda" else "cpu"
    model = None
    t_model = 0.0
    torch.backends.cuda.matmul.allow_tf32 = True
    for k in range(n_win):
        done_files = [work / f"w{k:05d}_{st}.flac" for st in want]
        if all(f.exists() for f in done_files):
            continue
        if model is None:
            progress(k / n_win, L("Modell laden", "loading the model"))
            t0 = time.time()
            model = a.load(Path(s["weights_dir"]), device, params)
            t_model = time.time() - t0
        start = first + k * hop
        length = min(chunk, first + count - start)
        x = next(read_blocks(src, block_seconds=chunk / sr + 1, start=start, frames=length))
        xm = _resample(_to_channels(x, a.CHANNELS), sr, a.SAMPLE_RATE)
        with torch.inference_mode():
            res = a.process(model, xm, params)
        stems: dict[str, np.ndarray] = {}
        for st in want:
            if st in res:
                y = _resample(np.asarray(res[st], dtype=np.float32), a.SAMPLE_RATE, sr)
                y = _to_channels(y, ch)
                y = y[:length] if len(y) >= length else np.pad(y, ((0, length - len(y)), (0, 0)))
                stems[st] = y
        for st in want:
            if st not in stems:
                # Rest: Mischung minus alle gelieferten Ziel-Stems
                acc = x.copy()
                for other, y in stems.items():
                    if other in produced:
                        acc = acc - y
                stems[st] = acc
        for st in want:
            sf.write(str(work / f"w{k:05d}_{st}.part.flac"), np.clip(stems[st], -1, 1), sr, format="FLAC", subtype="PCM_24")
            os.replace(work / f"w{k:05d}_{st}.part.flac", work / f"w{k:05d}_{st}.flac")
        progress(0.9 * (k + 1) / n_win, L(f"Abschnitt {k + 1} von {n_win}", f"section {k + 1} of {n_win}"))
        if device == "cuda" and k == 0:
            vram = torch.cuda.max_memory_allocated() / 1024**3
            emit(info={"vram_gb": round(vram, 2), "model_seconds": round(t_model, 1)})
    # zusammensetzen mit Überblendung
    writers = {st: Writer(Path(o["flac"]), sr, ch, Path(o["peaks"]) if o.get("peaks") else None,
                          Path(o["proxy"]) if o.get("proxy") else None) for st, o in outs.items()}
    fade_in = np.sin(np.linspace(0, math.pi / 2, ov, dtype=np.float32)) ** 2 if ov else np.zeros(0, np.float32)
    tails: dict[str, np.ndarray | None] = {st: None for st in want}
    for k in range(n_win):
        for st in want:
            y, _ = sf.read(str(work / f"w{k:05d}_{st}.flac"), dtype="float32", always_2d=True)
            if tails[st] is not None and ov:
                n = min(ov, len(y), len(tails[st]))
                y[:n] = tails[st][:n] * (1 - fade_in[:n, None]) + y[:n] * fade_in[:n, None]
            last = k == n_win - 1
            if last or not ov:
                writers[st].add(y)
                tails[st] = None
            else:
                writers[st].add(y[: len(y) - ov])
                tails[st] = y[len(y) - ov:]
        progress(0.9 + 0.1 * (k + 1) / n_win, L("zusammensetzen", "joining"))
    result = {st: w.close() for st, w in writers.items()}
    return {"stems": result, "windows": n_win, "sample_rate": sr, "channels": ch, "first": first, "frames": count,
            "model_seconds": round(t_model, 1)}


# --------------------------------------------------------------------------------------------- Geräusch lernen

def cmd_learn(s: dict[str, Any]) -> dict[str, Any]:
    """Ein Geräusch aus markierten Beispielen lernen: Mischungen aus sauberen Stellen derselben Aufnahme und den
    Beispielen (zufällige Lage und Lautstärke) trainieren ein kleines Masken-Netz (audio_models/learned.py). Geprüft
    wird an zurückgehaltenen Beispielen: wie weit das Geräusch sinkt und dass saubere Stellen gleich laut bleiben."""
    import random

    import torch

    sys.path.insert(0, str(Path(__file__).parent))
    from audio_models import learned

    rng = random.Random(1234)
    torch.manual_seed(1234)
    src = s["src"]
    sr_src, _, frames = info(src)
    sr = learned.SAMPLE_RATE

    def span(a: int, n: int) -> np.ndarray:
        x = next(read_blocks(src, block_seconds=n / sr_src + 1, start=max(0, a), frames=n), None)
        if x is None:
            return np.zeros(0, np.float32)
        return _resample(x.mean(axis=1, keepdims=True), sr_src, sr)[:, 0]

    noise = [span(int(a), int(n)) for a, n in s["noise"]]
    noise = [x for x in noise if len(x) > sr // 10]
    if not noise:
        raise SystemExit(L("Keine verwertbaren Beispiele (mindestens 0,1 s je Marke).",
                           "No usable examples (at least 0.1 s per marker)."))
    progress(0.02, L("Beispiele", "examples"))
    # saubere Stellen: „behalten“-Marken, sonst 4-s-Stücke außerhalb der Beispiele (1 s Abstand)
    clean: list[np.ndarray] = [span(int(a), int(n)) for a, n in s.get("keep") or []]
    if sum(len(x) for x in clean) < sr * 60:
        busy = [(int(a) - sr_src, int(a) + int(n) + sr_src) for a, n in s["noise"]]
        tries = 0
        win = 4 * sr_src
        while sum(len(x) for x in clean) < sr * 240 and tries < 400 and frames > win * 2:
            tries += 1
            a = rng.randrange(0, frames - win)
            if any(a < e and a + win > b for b, e in busy):
                continue
            x = span(a, win)
            if len(x) and float(np.sqrt((x ** 2).mean())) > 1e-4:
                clean.append(x)
            progress(0.02 + 0.06 * min(1.0, sum(len(c) for c in clean) / (sr * 240)), L("saubere Stellen", "clean passages"))
    clean = [x for x in clean if len(x) >= sr]
    if not clean:
        raise SystemExit(L("Zu wenig saubere Stellen gefunden.", "Too few clean passages found."))
    # ein Beispiel (bei mehreren das letzte) und ein Fünftel der sauberen Stellen bleiben zur Prüfung zurück
    val_noise = noise[-1:] if len(noise) > 1 else noise
    train_noise = noise[:-1] if len(noise) > 1 else noise
    n_val = max(1, len(clean) // 5)
    val_clean, train_clean = clean[:n_val], clean[n_val:] or clean
    dev = "cuda" if torch.cuda.is_available() else "cpu"
    net = learned.build().to(dev)
    steps = int(s.get("steps") or 3000)
    opt = torch.optim.AdamW(net.parameters(), lr=1e-3, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=1e-3, total_steps=steps, pct_start=0.1)
    seg = 2 * sr
    win = torch.hann_window(learned.N_FFT, device=dev)

    def crop(x: np.ndarray, n: int) -> np.ndarray:
        if len(x) >= n:
            a = rng.randrange(0, len(x) - n + 1)
            return x[a:a + n]
        out = np.zeros(n, np.float32)
        a = rng.randrange(0, n - len(x) + 1)
        out[a:a + len(x)] = x
        return out

    def batch(cl: list[np.ndarray], no: list[np.ndarray], b: int) -> tuple[Any, Any]:
        cs, ns = [], []
        for _ in range(b):
            c = crop(rng.choice(cl), seg) * 10 ** (rng.uniform(-6, 6) / 20)
            if rng.random() < 0.2:
                n_ = np.zeros(seg, np.float32)
            else:
                n_ = crop(rng.choice(no), seg)
                rc = float(np.sqrt((c ** 2).mean()) + 1e-6)
                rn = float(np.sqrt((n_ ** 2).mean()) + 1e-6)
                n_ = n_ * (rc / rn) * 10 ** (rng.uniform(-12, 6) / 20)
            cs.append(c)
            ns.append(n_)
        return (torch.from_numpy(np.stack(cs)).to(dev), torch.from_numpy(np.stack(ns)).to(dev))

    def spec(x: Any) -> Any:
        return torch.stft(x, learned.N_FFT, learned.HOP, window=win, return_complex=True).abs().transpose(1, 2)

    t0 = time.time()
    net.train()
    for step in range(steps):
        c, n_ = batch(train_clean, train_noise, 16)
        mc, mm = spec(c), spec(c + n_)
        mask = net(mm)
        loss = (torch.abs((mask * mm + 1e-8) ** 0.3 - (mc + 1e-8) ** 0.3)).mean()
        opt.zero_grad(set_to_none=True)
        loss.backward()
        torch.nn.utils.clip_grad_norm_(net.parameters(), 5.0)
        opt.step()
        sched.step()
        if step % 50 == 0:
            progress(0.1 + 0.8 * step / steps, L(f"lernen {step}/{steps}, Verlust {loss.item():.4f}",
                                                 f"learning {step}/{steps}, loss {loss.item():.4f}"))
    train_seconds = time.time() - t0
    # Prüfung: Geräusch-Absenkung an zurückgehaltenen Mischungen, Pegel sauberer Stellen
    net.eval()
    red, keep = [], []
    with torch.inference_mode():
        for _ in range(40):
            c, n_ = batch(val_clean, val_noise, 1)
            if float(n_.abs().max()) == 0:
                continue
            mix = c + n_
            sp = torch.stft(mix, learned.N_FFT, learned.HOP, window=win, return_complex=True)
            m = net(sp.abs().transpose(1, 2)).transpose(1, 2)
            out = torch.istft(sp * m, learned.N_FFT, learned.HOP, window=win, length=mix.shape[1])
            resid = out - c
            red.append(10 * math.log10(float((n_ ** 2).mean() + 1e-12) / float((resid ** 2).mean() + 1e-12)))
        for _ in range(20):
            c, _n = batch(val_clean, val_noise, 1)
            sp = torch.stft(c, learned.N_FFT, learned.HOP, window=win, return_complex=True)
            m = net(sp.abs().transpose(1, 2)).transpose(1, 2)
            out = torch.istft(sp * m, learned.N_FFT, learned.HOP, window=win, length=c.shape[1])
            keep.append(10 * math.log10(float((out ** 2).mean() + 1e-12) / float((c ** 2).mean() + 1e-12)))
    out_path = Path(s["out"])
    out_path.parent.mkdir(parents=True, exist_ok=True)
    metrics = {"noise_reduction_db": round(float(np.median(red)), 1) if red else None,
               "clean_change_db": round(float(np.median(keep)), 2) if keep else None,
               "examples": len(noise), "example_seconds": round(sum(len(x) for x in noise) / sr, 1),
               "clean_seconds": round(sum(len(x) for x in clean) / sr, 1), "steps": steps,
               "train_seconds": round(train_seconds, 1), "device": dev}
    torch.save({"state": {k: v.detach().cpu() for k, v in net.state_dict().items()},
                "config": {"hidden": 256, "n_fft": learned.N_FFT, "hop": learned.HOP, "sr": sr}, "metrics": metrics},
               out_path)
    return {"profile": str(out_path), "metrics": metrics}


# --------------------------------------------------------------------------------------------- Töne suchen

def cmd_scan(s: dict[str, Any]) -> dict[str, Any]:
    """Gleichbleibende Töne finden (Alarme, Piepser, Signaltöne): je 21 ms der stärkste Spektralwert zwischen fmin und
    fmax gegen den Median des Bandes; ein Ton zählt, wenn er mindestens min_ms lang auf derselben Höhe bleibt (Sprache
    wandert in der Höhe). Ereignisse mit Lücken unter 0,4 s werden zusammengefasst, dann nach Tonhöhe gruppiert."""
    src = s["src"]
    sr, ch, frames = info(src)
    n_fft, hop = 2048, 1024
    fmin, fmax = float(s.get("fmin") or 500), float(s.get("fmax") or 6000)
    thr = float(s.get("threshold_db") or 26)
    min_frames = max(2, int(float(s.get("min_ms") or 150) / 1000 * sr / hop))
    freqs = np.fft.rfftfreq(n_fft, 1 / sr)
    band = np.where((freqs >= fmin) & (freqs <= fmax))[0]
    win = np.hanning(n_fft).astype(np.float32)
    peak_bin: list[np.ndarray] = []
    tonal: list[np.ndarray] = []
    level: list[np.ndarray] = []
    rest = np.zeros(0, np.float32)
    done = 0
    for block in read_blocks(src, block_seconds=60):
        mono = block.mean(axis=1)
        data = np.concatenate([rest, mono])
        n = (len(data) - n_fft) // hop + 1
        if n > 0:
            idx = np.arange(n_fft)[None, :] + hop * np.arange(n)[:, None]
            spec = np.abs(np.fft.rfft(data[idx] * win, axis=1))[:, band]
            db = 20 * np.log10(spec + 1e-9)
            pk = db.argmax(axis=1)
            med = np.median(db, axis=1)
            peak_bin.append(pk.astype(np.int32))
            tonal.append((db[np.arange(n), pk] - med).astype(np.float32))
            level.append(db[np.arange(n), pk].astype(np.float32))
            rest = data[n * hop:]
        else:
            rest = data
        done += len(block)
        progress(0.9 * done / max(1, frames), L("Töne suchen", "finding tones"))
    if not peak_bin:
        return {"clusters": [], "events": 0}
    pk = np.concatenate(peak_bin)
    tn = np.concatenate(tonal)
    lv = np.concatenate(level)
    floor = float(np.percentile(lv, 20))
    on = (tn > thr) & (lv > floor + 12)
    # gleichbleibende Höhe: Nachbarbild auf ±1 Bin derselben Höhe
    same = np.zeros_like(on)
    same[1:] = np.abs(pk[1:] - pk[:-1]) <= 1
    on = on & (same | np.roll(same, -1))
    events: list[list[float]] = []
    i = 0
    n = len(on)
    while i < n:
        if not on[i]:
            i += 1
            continue
        j = i
        while j + 1 < n and on[j + 1] and abs(int(pk[j + 1]) - int(pk[i])) <= 2:
            j += 1
        if j - i + 1 >= min_frames:
            f = float(freqs[band[int(np.median(pk[i:j + 1]))]])
            events.append([i * hop / sr, (j + 1) * hop / sr + n_fft / sr, f, float(tn[i:j + 1].mean())])
        i = j + 1
    # Pieptöne mit kurzen Pausen zu einem Alarm zusammenfassen, auch wechselnde Töne (Zweiton-Alarme)
    merged: list[dict[str, Any]] = []
    for e in events:
        if merged and e[0] - merged[-1]["end"] < 0.4:
            m = merged[-1]
            m["end"] = e[1]
            m["freqs"].add(int(round(e[2] / 50.0) * 50))
            m["tonality"] = max(m["tonality"], e[3])
        else:
            merged.append({"start": e[0], "end": e[1], "freqs": {int(round(e[2] / 50.0) * 50)}, "tonality": e[3]})
    groups: dict[tuple[int, ...], list[dict[str, Any]]] = {}
    for m in merged:
        groups.setdefault(tuple(sorted(m["freqs"]))[:3], []).append(m)
    clusters = []
    for key, evs in groups.items():
        total = sum(e["end"] - e["start"] for e in evs)
        ton = float(np.mean([e["tonality"] for e in evs]))
        clusters.append({"freqs": list(key), "freq": key[0], "count": len(evs), "total_s": round(total, 1),
                         "mean_s": round(total / len(evs), 2), "tonality_db": round(ton, 1),
                         "score": round(len(evs) * max(0.0, ton - 30), 1),
                         "events": [[round(e["start"], 2), round(e["end"], 2)] for e in evs[:500]]})
    clusters.sort(key=lambda c: -c["score"])
    progress(1.0, L("fertig", "done"))
    return {"clusters": clusters[:12], "events": len(merged), "seconds_scanned": round(frames / sr, 1)}

def cmd_wavcopy(s: dict[str, Any]) -> dict[str, Any]:
    """Arbeitsdatei (FLAC) bitgenau als WAV für das Prüfpaket: gleiche Rate, Kanäle und Auflösung (16 oder 24 Bit), über
    4 GB als RF64. s: src, dst. Ergebnis: Format und SHA-256 der geschriebenen Datei."""
    import hashlib
    import soundfile as sf
    info = sf.info(s["src"])
    subtype = "PCM_24" if "24" in info.subtype else "PCM_16"
    width = 3 if subtype == "PCM_24" else 2
    fmt = "RF64" if info.frames * info.channels * width > 0xFFFFFF00 else "WAV"
    done = 0
    with sf.SoundFile(s["src"]) as fi, sf.SoundFile(s["dst"], "w", samplerate=info.samplerate, channels=info.channels,
                                                     subtype=subtype, format=fmt) as fo:
        while True:
            block = fi.read(info.samplerate * 60, dtype="int32", always_2d=True)
            if not len(block):
                break
            fo.write(block)
            done += len(block)
            progress(0.9 * done / max(1, info.frames), "WAV")
    h = hashlib.sha256()
    with open(s["dst"], "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 22), b""):
            h.update(chunk)
    return {"sample_rate": info.samplerate, "channels": info.channels, "frames": info.frames, "subtype": subtype,
            "format": fmt.lower(), "sha256": h.hexdigest(), "bytes": os.path.getsize(s["dst"])}


COMMANDS: dict[str, Callable[[dict[str, Any]], dict[str, Any]]] = {
    "probe": cmd_probe, "prepare": cmd_prepare, "process": cmd_process, "export": cmd_export, "peaks": cmd_peaks,
    "ai": cmd_ai, "learn": cmd_learn, "scan": cmd_scan, "wavcopy": cmd_wavcopy,
}


def main() -> None:
    cmd = sys.argv[1]
    settings = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8")) if len(sys.argv) > 2 else {}
    set_lang(settings.get("lang"))
    t0 = time.time()
    try:
        result = COMMANDS[cmd](settings)
    except SystemExit as e:
        emit(error=str(e))
        raise SystemExit(2) from None
    result["seconds"] = round(time.time() - t0, 2)
    emit(result=result)


if __name__ == "__main__":
    main()
