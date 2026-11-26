"""Werkzeuge der Ton-Forensik (seit 17.11.2026; Nutzer: „Ton wird zum Ton Forensik Tool … spuren für die Forensik,
und tools die mann braucht“). Läuft wie audio_tools.py als eigener Prozess:
python -I forensic_tools.py <befehl> <einstellungen.json>, Fortschritt und Ergebnis als JSON-Zeilen.

Befehle:
- spectro: Spektrogramm einer Spur in vier Auflösungen (20 ms, 0,16 s, 2,56 s, 41 s je Spalte), dazu eine Sprachaktivität
  aus demselben Durchgang (Pegel im Sprachband über dem Rauschboden, getaktete Töne abgezogen).
- vad: Sprachaktivität mit Silero VAD (MIT), wenn das Modell geladen ist.

Spektrogramm-Datei: 32 Byte Kopf (NVSP, Version, Bänder, Schritt in Proben, Rate, fmax, Spalten, dB unten, dB oben),
dann je Spalte die Bänder als uint8 (0 = dB unten, 255 = dB oben), Spalte für Spalte. So holt der Browser per
Range-Anfrage nur den sichtbaren Ausschnitt.
"""
from __future__ import annotations

import json
import os
import math
import struct
import sys
import time
from pathlib import Path
from typing import Any, Callable

# -I nimmt den Ordner des Skripts aus sys.path: audio_tools liegt daneben
sys.path.insert(0, str(Path(__file__).resolve().parent))
import audio_tools as at  # noqa: E402
import numpy as np  # noqa: E402

SPEC_MAGIC = b"NVSP"
SPEC_HEAD = struct.Struct("<4sHHIIfIff")  # 32 Byte
DB_LO, DB_HI = -120.0, 0.0
LEVELS = (1, 8, 128, 2048)                # Spalten je Stufe: 20 ms, 0,16 s, 2,56 s, 41 s
ACT_RATE = 10                             # Sprachaktivität: Werte je Sekunde


def emit(**kw: Any) -> None:
    # reines ASCII: unter python -I gilt PYTHONIOENCODING nicht, Umlaute kämen sonst verstümmelt beim Server an
    print(json.dumps(kw, ensure_ascii=True), flush=True)


def progress(frac: float, stage: str = "") -> None:
    emit(progress=round(max(0.0, min(1.0, frac)), 4), stage=stage)


def L(de: str, en: str) -> str:
    """Meldung in der Sprache des Auftrags (main setzt sie über audio_tools.set_lang)."""
    return at.L(de, en)


class SpecFile:
    """Eine Stufe des Spektrogramms blockweise schreiben (Spalten als uint8, Kopf am Ende nachgetragen)."""

    def __init__(self, path: Path, bins: int, hop: int, sr: int, fmax: float, factor: int) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        self.path = path
        self.tmp = path.with_name(path.name + ".part")
        self.f = self.tmp.open("wb")
        self.f.write(b"\0" * SPEC_HEAD.size)
        self.bins, self.hop, self.sr, self.fmax, self.factor = bins, hop, sr, fmax, factor
        self.cols = 0
        self.rest = np.zeros((0, bins), np.uint8)

    def add(self, cols: np.ndarray) -> None:
        data = np.concatenate([self.rest, cols]) if len(self.rest) else cols
        whole = len(data) // self.factor * self.factor
        if whole:
            out = data[:whole].reshape(-1, self.factor, self.bins).max(axis=1) if self.factor > 1 else data[:whole]
            self.f.write(np.ascontiguousarray(out, np.uint8).tobytes())
            self.cols += len(out)
        self.rest = data[whole:].copy()

    def close(self) -> None:
        if len(self.rest):
            self.f.write(self.rest.max(axis=0).astype(np.uint8).tobytes())
            self.cols += 1
        self.f.seek(0)
        self.f.write(SPEC_HEAD.pack(SPEC_MAGIC, 1, self.bins, self.hop * self.factor, self.sr, float(self.fmax),
                                     self.cols, DB_LO, DB_HI))
        self.f.close()
        self.tmp.replace(self.path)


def _band_starts(sr: int, nfft: int, fmax: float, bins: int) -> tuple[np.ndarray, int]:
    """Erster FFT-Bin je Band (für np.add.reduceat) und Anzahl der genutzten Bins."""
    kmax = int(math.floor(fmax * nfft / sr)) + 1
    freqs = np.arange(kmax) * sr / nfft
    band = np.minimum(bins - 1, np.floor(freqs / fmax * bins).astype(int))
    starts = np.searchsorted(band, np.arange(bins))
    # Bänder ohne eigenen Bin (nur bei sehr feiner Teilung) übernehmen den Nachbarn
    starts = np.minimum(starts, kmax - 1)
    return starts, kmax


def cmd_spectro(s: dict[str, Any]) -> dict[str, Any]:
    """Spektrogramm (drei Stufen) und Sprachaktivität einer Spur. s: src, out (Pfad ohne Endung), bins, fmax."""
    src = s["src"]
    sr, channels, frames = at.info(src)
    bins = int(s.get("bins") or 192)
    fmax = float(min(sr / 2, float(s.get("fmax") or 12000)))
    hop = int(round(sr * 0.02))
    nfft = 2048 if sr >= 32000 else 1024
    win = np.hanning(nfft).astype(np.float32)
    norm = 4.0 / float(win.sum()) ** 2          # Vollaussteuerter Sinus = 0 dB
    starts, kmax = _band_starts(sr, nfft, fmax, bins)
    counts = np.diff(np.append(starts, kmax)).clip(min=1).astype(np.float32)
    out = Path(s["out"])
    files = [SpecFile(out.with_suffix(f".spec{'' if i == 0 else i}"), bins, hop, sr, fmax, f) for i, f in enumerate(LEVELS)]
    # Sprachband und Bänder für die Aktivität
    fb = (np.arange(bins) + 0.5) * fmax / bins
    speech = (fb >= 250) & (fb <= min(3800.0, fmax))
    # Puffer: Fenster mittig auf jeder Spalte (Spalte i deckt [i*hop, (i+1)*hop))
    buf = np.zeros(nfft // 2 - hop // 2, np.float32)
    total_cols = int(math.ceil(frames / hop))
    done_cols = 0
    act_cols: list[np.ndarray] = []      # je Spalte: Sprachband-Pegel (dB) und Tonhaltigkeit
    t0 = time.time()

    def flush(data: np.ndarray, final: bool) -> np.ndarray:
        nonlocal done_cols
        if final:
            need = nfft + max(0, total_cols - done_cols - 1) * hop
            if len(data) < need:
                data = np.concatenate([data, np.zeros(need - len(data), np.float32)])
        n = (len(data) - nfft) // hop + 1 if len(data) >= nfft else 0
        if final:
            n = min(n, total_cols - done_cols)
        if n <= 0:
            return data
        view = np.lib.stride_tricks.as_strided(data, shape=(n, nfft), strides=(data.strides[0] * hop, data.strides[0]),
                                               writeable=False)
        for a in range(0, n, 4096):
            fr = view[a:a + 4096] * win
            p = np.abs(np.fft.rfft(fr, axis=1)[:, :kmax]) ** 2 * norm
            band = np.add.reduceat(p, starts, axis=1) / counts
            db = 10 * np.log10(band + 1e-14)
            q = np.clip((db - DB_LO) / (DB_HI - DB_LO) * 255 + 0.5, 0, 255).astype(np.uint8)
            for f in files:
                f.add(q)
            sp = db[:, speech]
            med = np.median(sp, axis=1)
            act_cols.append(np.stack([10 * np.log10(band[:, speech].mean(axis=1) + 1e-14),
                                      sp.max(axis=1) - med], axis=1).astype(np.float32))
        done_cols += n
        return data[n * hop:].copy()

    for block in at.read_blocks(src, block_seconds=60.0):
        mono = block.mean(axis=1) if block.shape[1] > 1 else block[:, 0]
        buf = flush(np.concatenate([buf, mono.astype(np.float32)]), False)
        progress(0.95 * done_cols / max(1, total_cols), L("Spektrogramm", "spectrogram"))
    flush(buf, True)
    for f in files:
        f.close()
    act = _activity(np.concatenate(act_cols) if act_cols else np.zeros((0, 2), np.float32), hop, sr)
    act_path = out.with_suffix(".act")
    act["values"].tofile(act_path)
    progress(1.0, L("fertig", "done"))
    return {"bins": bins, "hop": hop, "sr": sr, "fmax": fmax, "nfft": nfft, "cols": files[0].cols,
            "levels": [{"factor": f, "cols": x.cols} for f, x in zip(LEVELS, files)],
            "activity": {"rate": ACT_RATE, "method": "energy", "segments": act["segments"],
                         "speech_seconds": act["speech_seconds"], "floor_db": act["floor_db"]},
            "compute_seconds": round(time.time() - t0, 1)}


def _activity(cols: np.ndarray, hop: int, sr: int) -> dict[str, Any]:
    """Grobe Sprachaktivität ohne KI: Pegel im Sprachband über dem gleitenden Rauschboden (Minimum über 8 s),
    stark tonale Spalten (Alarme, Piepser: Spitze > 25 dB über dem Bandmedian) zählen nicht. Ergebnis je 0,1 s ein
    Wert 0–255 und Abschnitte mit mindestens 0,4 s, Lücken unter 0,5 s überbrückt."""
    per = max(1, int(round(sr / hop / ACT_RATE)))           # Spalten je Wert (20 ms → 5)
    n = len(cols) // per
    if n == 0:
        return {"values": np.zeros(0, np.uint8), "segments": [], "speech_seconds": 0.0, "floor_db": None}
    lvl = cols[: n * per, 0].reshape(n, per).mean(axis=1)
    ton = cols[: n * per, 1].reshape(n, per).max(axis=1)
    # Rauschboden: Minimum über 8 s, geglättet über 30 s
    w = 8 * ACT_RATE
    pad = np.pad(lvl, (w // 2, w - w // 2 - 1), mode="edge")
    mins = np.lib.stride_tricks.sliding_window_view(pad, w).min(axis=1)
    k = 30 * ACT_RATE
    floor = np.convolve(np.pad(mins, (k // 2, k - k // 2 - 1), mode="edge"), np.ones(k) / k, mode="valid")
    snr = lvl - floor
    score = np.clip((snr - 4.0) / 14.0, 0, 1)                # ab 4 dB über Boden, voll bei 18 dB
    score[ton > 25.0] *= 0.15
    values = (score * 255 + 0.5).astype(np.uint8)
    on = score > 0.35
    segs: list[list[float]] = []
    i = 0
    while i < n:
        if on[i]:
            j = i
            while j < n and on[j]:
                j += 1
            a, b = i / ACT_RATE, j / ACT_RATE
            if segs and a - segs[-1][1] < 0.5:
                segs[-1][1] = b
            else:
                segs.append([a, b])
            i = j
        else:
            i += 1
    segs = [[round(a, 1), round(b, 1)] for a, b in segs if b - a >= 0.4]
    return {"values": values, "segments": segs[:20000], "speech_seconds": round(sum(b - a for a, b in segs), 1),
            "floor_db": round(float(np.median(floor)), 1)}


def cmd_vad(s: dict[str, Any]) -> dict[str, Any]:
    """Sprachaktivität mit Silero VAD (TorchScript, 16 kHz, Fenster 512 Proben). s: src, model, out (.act),
    threshold. Ergebnis wie bei spectro: je 0,1 s ein Wert 0–255 und Abschnitte."""
    import torch
    src = s["src"]
    sr, channels, frames = at.info(src)
    model = torch.jit.load(s["model"], map_location="cpu")
    model.eval()
    if hasattr(model, "reset_states"):
        model.reset_states()
    thr = float(s.get("threshold") or 0.5)
    win = 512
    probs: list[float] = []
    done = 0
    t0 = time.time()
    with torch.inference_mode():
        for block in at.read_blocks(src, block_seconds=60.0):
            mono = block.mean(axis=1) if block.shape[1] > 1 else block[:, 0]
            x = at._resample(mono.reshape(-1, 1), sr, 16000)[:, 0] if sr != 16000 else mono
            n = len(x) // win
            if n:
                chunks = torch.from_numpy(np.ascontiguousarray(x[: n * win].reshape(n, win), dtype=np.float32))
                for c in chunks:
                    probs.append(float(model(c.unsqueeze(0), 16000).item()))
            done += len(block)
            progress(0.98 * done / max(1, frames), L("Sprache suchen", "finding speech"))
    p = np.asarray(probs, np.float32)
    # je 0,1 s das Maximum der Silero-Werte (31,25 je Sekunde) in diesem Zehntel
    fi = (np.arange(len(p)) * win * ACT_RATE // 16000).astype(int)
    vals = np.zeros(int(fi[-1]) + 1 if len(p) else 0, np.float32)
    np.maximum.at(vals, fi, p)
    values = (vals * 255 + 0.5).astype(np.uint8)
    values.tofile(s["out"])
    on = vals > thr
    segs: list[list[float]] = []
    i = 0
    while i < len(on):
        if on[i]:
            j = i
            while j < len(on) and on[j]:
                j += 1
            a, b = i / ACT_RATE, j / ACT_RATE
            if segs and a - segs[-1][1] < 0.3:
                segs[-1][1] = b
            else:
                segs.append([a, b])
            i = j
        else:
            i += 1
    segs = [[round(a, 1), round(b, 1)] for a, b in segs if b - a >= 0.25]
    return {"activity": {"rate": ACT_RATE, "method": "silero", "segments": segs[:20000],
                         "speech_seconds": round(sum(b - a for a, b in segs), 1)},
            "compute_seconds": round(time.time() - t0, 1)}


def cmd_vadmap(s: dict[str, Any]) -> dict[str, Any]:
    """Sprachwahrscheinlichkeit (Silero VAD) für ganze Spuren, je 0,1 s ein Wert 0–255 (Datei .vad). Schnell durch
    Stapel: alle Spuren werden in Stücke zu 32 s geteilt und gemeinsam gerechnet (ein Modellaufruf je 32-ms-Fenster
    für alle Stücke); am Anfang jedes Stücks beginnt das Modell neu (wenige Fenster ungenauer).
    Hintergrund (17.11.): Die Mikrofone eines Schiffsschreibers sind geschaltet, zwischen Geräuschen steht digitale
    Stille; pegelbasierte Aktivität hält dort alles für Sprache. s: vad_dir, tracks [{id, file, out}]."""
    import torch
    model = torch.jit.load(str(Path(s["vad_dir"]) / "silero_vad.jit"), map_location="cpu")
    model.eval()
    torch.set_num_threads(max(1, min(8, (os.cpu_count() or 4))))
    tracks = s["tracks"]
    infos = [at.info(tr["file"]) for tr in tracks]
    dur = max(i[2] / i[0] for i in infos)
    win = 512
    per = 1000                                    # Fenster je Stück (32 s)
    chunk = win * per
    group_s = 1800.0                              # so viel Ton je Spur auf einmal im Speicher
    out = [np.zeros(int(math.ceil(dur * ACT_RATE)) + 1, np.uint8) for _ in tracks]
    t0 = time.time()
    g = 0.0
    while g < dur:
        g1 = min(dur, g + group_s)
        rows, where = [], []
        for k, tr in enumerate(tracks):
            x = _read16(tr["file"], g, g1) if g < infos[k][2] / infos[k][0] else np.zeros(0, np.float32)
            n = int(math.ceil(len(x) / chunk))
            if n == 0:
                continue
            x = np.pad(x, (0, n * chunk - len(x)))
            for c in range(n):
                rows.append(x[c * chunk:(c + 1) * chunk])
                where.append((k, g + c * chunk / 16000))
        if rows:
            X = torch.from_numpy(np.stack(rows))
            P = np.zeros((len(rows), per), np.float32)
            if hasattr(model, "reset_states"):
                model.reset_states()          # Zustand passt sich der Stapelgröße beim nächsten Aufruf an
            with torch.inference_mode():
                for w in range(per):
                    P[:, w] = model(X[:, w * win:(w + 1) * win], 16000).reshape(-1).numpy()
            for (k, start), p in zip(where, P):
                idx = (start + np.arange(per) * win / 16000) * ACT_RATE
                fi = idx.astype(int)
                ok = fi < len(out[k])
                vals = (p[ok] * 255 + 0.5).astype(np.uint8)
                np.maximum.at(out[k], fi[ok], vals)
        g = g1
        progress(g / dur, L(f"Sprache finden {fmt_hms(g)} / {fmt_hms(dur)}", f"finding speech {fmt_hms(g)} / {fmt_hms(dur)}"))
    res = {}
    for k, tr in enumerate(tracks):
        a = out[k][: int(math.ceil(infos[k][2] / infos[k][0] * ACT_RATE))]
        a.tofile(tr["out"])
        on = a > 128
        res[tr["id"]] = {"speech_seconds": round(float(on.sum()) / ACT_RATE, 1)}
    return {"tracks": res, "compute_seconds": round(time.time() - t0, 1)}


def _envelope(blocks: Any, sr: int, rate: int = 100) -> np.ndarray:
    """Pegel-Hüllkurve (dB) mit rate Werten je Sekunde aus Blöcken (Proben, Kanäle), über alle Kanäle gemittelt."""
    hop = sr // rate
    parts, rest = [], np.zeros(0, np.float32)
    for b in blocks:
        mono = b.mean(axis=1) if b.ndim == 2 else b
        x = np.concatenate([rest, mono.astype(np.float32)])
        n = len(x) // hop
        if n:
            parts.append(10 * np.log10((x[: n * hop].reshape(n, hop) ** 2).mean(axis=1) + 1e-10))
        rest = x[n * hop:]
    return np.concatenate(parts).astype(np.float32) if parts else np.zeros(0, np.float32)


def _mix_blocks(files: list[str], gains: list[float], block_seconds: float = 60.0, start: int = 0,
                frames: int | None = None) -> Any:
    """Mehrere Spuren gleicher Rate blockweise gemischt (mono)."""
    readers = [at.read_blocks(f, block_seconds=block_seconds, start=start, frames=frames) for f in files]
    while True:
        blocks = [next(r, None) for r in readers]
        if all(b is None for b in blocks):
            return
        n = max(len(b) for b in blocks if b is not None)
        acc = np.zeros(n, np.float32)
        for b, g in zip(blocks, gains):
            if b is not None:
                acc[: len(b)] += (b.mean(axis=1) if b.shape[1] > 1 else b[:, 0]) * g
        yield acc.reshape(-1, 1)


def cmd_align(s: dict[str, Any]) -> dict[str, Any]:
    """Ein Video (z. B. Bildschirmaufnahme des Wiedergabeprogramms) über den Ton auf die Zeit der Aufnahme ausrichten.
    1. grob: Kreuzkorrelation der Pegel-Hüllkurven (10 je Sekunde) über die ganze Länge,
    2. fein: alle step_s Sekunden ein Fenster von win_s Sekunden, Hüllkurve mit 100 je Sekunde im Umkreis von ±3 s,
    3. Gerade video_t = a·t + b durch die Punkte (robust: Median-Abweichung), Restfehler in ms.
    s: video (Datei mit Ton), ref (Liste FLAC der Aufnahme), out (JSON). Ergebnis: Punkte, Gerade, Restfehler."""
    from scipy.signal import fftconvolve
    rate = 100
    progress(0.01, L("Ton des Videos lesen", "reading the video's audio"))
    pr = at.probe(s["video"])
    vdur = float(pr.get("duration") or 0)
    sr_v = 8000
    venv: list[np.ndarray] = []
    done = 0.0
    # Die Hüllkurve zählt ab der ersten Tonprobe, Export und Lagebild rechnen mit den Zeitstempeln des Videos: Beginnt
    # der Ton nicht bei 0, lag die Zuordnung sonst um genau diesen Versatz daneben
    a0 = _audio_start(s["video"])

    def vblocks() -> Any:
        nonlocal done
        for b in at.decode_blocks(s["video"], sr_v, 1, block_seconds=60.0):
            done += len(b) / sr_v
            progress(0.02 + 0.6 * done / max(1.0, vdur), L("Ton des Videos lesen", "reading the video's audio"))
            yield b
    V = _envelope(vblocks(), sr_v, rate)
    progress(0.63, L("Aufnahme lesen", "reading the recording"))
    sr_r = at.info(s["ref"][0])[0]
    R = _envelope(_mix_blocks(list(s["ref"]), [1.0] * len(s["ref"])), sr_r, rate)

    def norm(x: np.ndarray) -> np.ndarray:
        x = np.maximum(x, np.percentile(x, 5))
        return (x - x.mean()) / (x.std() + 1e-6)
    # 1. grob mit 10 je Sekunde
    k = 10
    v10 = norm(V[: len(V) // k * k].reshape(-1, k).mean(axis=1))
    r10 = norm(R[: len(R) // k * k].reshape(-1, k).mean(axis=1))
    cc = fftconvolve(r10, v10[::-1], mode="full")
    lag = int(np.argmax(cc)) - (len(v10) - 1)        # r10[i + lag] ≈ v10[i]
    coarse = lag / 10.0                               # Aufnahme-Zeit = Video-Zeit + coarse
    progress(0.75, L("fein ausrichten", "fine alignment"))
    # 2. fein in Fenstern
    win, step, search = int(float(s.get("win_s") or 120) * rate), int(float(s.get("step_s") or 600) * rate), 3 * rate
    vn, rn = norm(V), norm(R)
    pts = []
    for a in range(0, len(vn) - win, step):
        seg = vn[a:a + win]
        b0 = a + int(round(coarse * rate)) - search
        b1 = b0 + win + 2 * search
        if b0 < 0 or b1 > len(rn):
            continue
        ref = rn[b0:b1]
        c = fftconvolve(ref, seg[::-1], mode="valid")
        i = int(np.argmax(c))
        # Spitze unterhalb eines Rasterpunkts schätzen (Parabel)
        frac = 0.0
        if 0 < i < len(c) - 1:
            d = c[i - 1] - 2 * c[i] + c[i + 1]
            frac = 0.5 * (c[i - 1] - c[i + 1]) / d if d != 0 else 0.0
        score = float(c[i] / win)
        vt = (a + win / 2) / rate + a0               # Zeitstempel des Videos
        rt = (b0 + i + frac + win / 2) / rate
        pts.append([round(float(rt), 3), round(float(vt), 3), round(float(score), 3)])
    good = [p for p in pts if p[2] > 0.3]
    if len(good) < 2:
        raise SystemExit(L("Video und Aufnahme passen nicht zusammen (keine sichere Übereinstimmung im Ton).",
                           "The video and the recording do not match (no reliable agreement in the sound)."))
    t = np.array([p[0] for p in good])
    v = np.array([p[1] for p in good])
    a_, b_ = np.polyfit(t, v, 1)
    for _ in range(2):                                # Ausreißer (mehr als 3 × Median-Abweichung) entfernen
        res = v - (a_ * t + b_)
        mad = np.median(np.abs(res - np.median(res))) + 1e-4
        keep = np.abs(res - np.median(res)) < 3 * mad + 0.02
        if keep.sum() >= 2:
            a_, b_ = np.polyfit(t[keep], v[keep], 1)
    res = v - (a_ * t + b_)
    out = {"coarse_offset_s": round(a0 - coarse, 3), "points": pts, "fit": {"a": float(a_), "b": float(b_)},
           "drift_ppm": round((a_ - 1) * 1e6, 1), "residual_ms": {"median": round(float(np.median(np.abs(res))) * 1000, 1),
                                                                   "max": round(float(np.abs(res).max()) * 1000, 1)},
           "used_points": int(len(good)), "video_duration": vdur, "audio_start_s": round(a0, 4)}
    Path(s["out"]).write_text(json.dumps(out), encoding="utf-8")
    progress(1.0, L("fertig", "done"))
    return out


def _audio_start(path: str) -> float:
    """Zeitstempel (s) der ersten dekodierten Tonprobe einer Datei (0, wenn es keinen gibt)."""
    import av
    with av.open(path) as c:
        a = next((st for st in c.streams if st.type == "audio"), None)
        if a is None:
            return 0.0
        for packet in c.demux(a):
            try:
                frames = packet.decode()
            except av.error.FFmpegError:
                continue
            for fr in frames:
                if fr.pts is not None and fr.time_base:
                    return float(fr.pts * fr.time_base)
    return 0.0


class ClockReader:
    """Liest eine im Bild angezeigte Uhr „TT/MM/JJJJ hh:mm:ss“ (feste Schrift, dunkel auf hell) per Ziffernvorlagen in
    Graustufen (normierte Korrelation, ±1 Pixel Spielraum; auf Schwarz-Weiß verwechselte die kleine Schrift 0 und 6).
    Vorlagen: die Ziffern des bekannten Datums (aus dem Beginn der Aufnahme) und die Einerstelle der Sekunden, die beim
    Weiterzählen alle Ziffern zeigt. box: (x, y, Breite, Höhe) um Datum und Uhrzeit (18 Zeichen)."""

    W = 8

    def __init__(self, box: list[int], date_text: str) -> None:
        self.box = box
        self.date = date_text                    # z. B. "15/06/2019"
        self.cols: list[tuple[int, int]] = []    # x-Bereich je Zeichen
        self.tpl: dict[str, np.ndarray] = {}

    def gray(self, img: np.ndarray) -> np.ndarray:
        x, y, w, h = self.box
        g = img[y:y + h, x:x + w].astype(np.float32)
        g = g.mean(axis=2) if g.ndim == 3 else g
        return 1.0 - g / 255.0                   # Text hell

    @staticmethod
    def segment(g: np.ndarray) -> list[tuple[int, int]]:
        b = g > (g.max() + g.min()) / 2
        cols = b.sum(axis=0) > 0
        out, i = [], 0
        while i < len(cols):
            if cols[i]:
                j = i
                while j < len(cols) and cols[j]:
                    j += 1
                out.append((i, j))
                i = j
            else:
                i += 1
        return out

    def patch(self, g: np.ndarray, c: tuple[int, int], dx: int = 0) -> np.ndarray:
        x0 = max(0, c[0] - 1 + dx)
        q = g[:, x0:x0 + self.W]
        if q.shape[1] < self.W:
            q = np.pad(q, ((0, 0), (0, self.W - q.shape[1])))
        q = q - q.mean()
        return q / (np.linalg.norm(q) + 1e-6)

    def setup(self, frames: list[np.ndarray]) -> bool:
        """Zeichenlagen aus einem Bild mit genau 18 Zeichen, Vorlagen aus Datum und Sekunden-Einerstelle."""
        g0 = None
        for f in frames:
            g = self.gray(f)
            segs = self.segment(g)
            if len(segs) == 18:
                g0, self.cols = g, segs
                break
        if g0 is None:
            return False
        acc: dict[str, list[np.ndarray]] = {}
        for ch, c in zip(self.date, self.cols[:10]):
            if ch.isdigit():
                acc.setdefault(ch, []).append(self.patch(g0, c))
        last = self.cols[-1]
        seq: list[np.ndarray] = []
        for f in frames:
            gl = self.patch(self.gray(f), last)
            if not seq or float((gl * seq[-1]).sum()) < 0.97:
                seq.append(gl)
        known = {k: np.mean(v, axis=0) for k, v in acc.items()}
        best, best_score = None, -1e9
        for start in range(10):          # zyklische Lage der Sekunden-Einer gegen die Ziffern des Datums
            sc, n = 0.0, 0
            for k, gl in enumerate(seq):
                d = str((start + k) % 10)
                if d in known:
                    sc += float((gl * known[d]).sum())
                    n += 1
            if n and sc / n > best_score:
                best, best_score = start, sc / n
        if best is None or best_score < 0.7:
            return False
        for k, gl in enumerate(seq):
            acc.setdefault(str((best + k) % 10), []).append(gl)
        self.tpl = {d: (lambda m: m / (np.linalg.norm(m) + 1e-6))(np.mean(v, axis=0)) for d, v in acc.items()}
        return len(self.tpl) == 10

    def digit(self, g: np.ndarray, c: tuple[int, int]) -> tuple[str | None, float]:
        best, score = None, -1.0
        for dx in (-1, 0, 1):
            q = self.patch(g, c, dx)
            for d, tp in self.tpl.items():
                v = float((q * tp).sum())
                if v > score:
                    best, score = d, v
        return best, score

    def read(self, img: np.ndarray) -> tuple[int, int, int] | None:
        """(h, m, s) oder None, wenn die Uhr nicht sicher lesbar ist."""
        g = self.gray(img)
        digits = []
        for idx in (10, 11, 13, 14, 16, 17):     # hh:mm:ss in den 18 Zeichen (10 Datum + 8 Zeit)
            d, sc = self.digit(g, self.cols[idx])
            if d is None or sc < 0.75:
                return None
            digits.append(d)
        h, m, s_ = int(digits[0] + digits[1]), int(digits[2] + digits[3]), int(digits[4] + digits[5])
        if h > 23 or m > 59 or s_ > 59:
            return None
        return h, m, s_


def cmd_clockalign(s: dict[str, Any]) -> dict[str, Any]:
    """Video über die im Bild angezeigte Uhr der Aufnahme zuordnen (z. B. „System Time“ des Live Players):
    an Stellen alle step_s Sekunden das Bild suchen, in dem die Sekunde umspringt (±1 Bild), Punkte (Aufnahme-Zeit,
    Video-Zeit), Gerade und Restfehler. s: video, box, origin (UTC-Sekunden von t=0), step_s, out."""
    import datetime as dt
    import av
    origin = float(s["origin"])
    day0 = dt.datetime.fromtimestamp(origin, dt.timezone.utc)
    reader = ClockReader(list(s["box"]), day0.strftime(s.get("date_format") or "%d/%m/%Y"))
    c = av.open(s["video"])
    vs = c.streams.video[0]
    vs.thread_type = "AUTO"
    vdur = float(c.duration or 0) / 1e6
    fps = float(vs.average_rate or 30)

    def frames_at(t0: float, seconds: float, every: float | None = None) -> list[tuple[float, np.ndarray]]:
        c.seek(int(max(0.0, t0 - 2) / vs.time_base), stream=vs, backward=True, any_frame=False)
        out, nxt = [], t0
        for f in c.decode(vs):
            tt = float(f.pts * vs.time_base) if f.pts is not None else 0.0
            if tt < t0 - 1e-3:
                continue
            if tt > t0 + seconds:
                break
            if every is None or tt >= nxt:
                out.append((tt, f.to_ndarray(format="rgb24")))
                nxt = tt + (every or 0)
        return out
    progress(0.02, L("Uhr im Bild lernen", "learning the clock in the picture"))
    first = frames_at(float(s.get("learn_at") or 5.0), 13.0, every=0.5)
    if not first or not reader.setup([f for _, f in first]):
        raise SystemExit(L("Die Uhr im Bild ließ sich nicht lesen (Lage der Uhr prüfen).",
                           "The clock in the picture could not be read (check where the clock is)."))
    step = float(s.get("step_s") or 300)
    pts, misses = [], 0
    samples = list(np.arange(10.0, vdur - 3, step))
    for k, t0 in enumerate(samples):
        fr = frames_at(float(t0), 1.4)
        prev = None
        found = False
        for tt, img in fr:
            r = reader.read(img)
            if r is None:
                continue
            if prev is not None and r != prev[1]:
                # Sprung: die angezeigte Sekunde r beginnt in diesem Bild
                day = day0
                shown = dt.datetime(day.year, day.month, day.day, r[0], r[1], r[2], tzinfo=dt.timezone.utc).timestamp()
                if shown < origin - 3600:
                    shown += 86400                   # nach Mitternacht
                pts.append([round(shown - origin, 3), round(tt - 0.5 / fps, 3)])
                found = True
                break
            prev = (tt, r)
        if not found:
            misses += 1
        progress(0.05 + 0.93 * (k + 1) / len(samples), L(f"Uhr lesen {k + 1}/{len(samples)}",
                                                          f"reading the clock {k + 1}/{len(samples)}"))
    c.close()
    if len(pts) < 2:
        raise SystemExit(L("Zu wenige lesbare Stellen der Uhr im Bild.", "Too few readable spots of the clock in the picture."))
    t = np.array([p[0] for p in pts])
    v = np.array([p[1] for p in pts])
    a_, b_ = np.polyfit(t, v, 1)
    res = v - (a_ * t + b_)
    keep = np.abs(res - np.median(res)) < 0.5
    if keep.sum() >= 2:
        a_, b_ = np.polyfit(t[keep], v[keep], 1)
        res = v - (a_ * t + b_)
    out = {"method": "clock", "points": [[p[0], p[1], round(float(r_) * 1000, 1)] for p, r_ in zip(pts, res)],
           "fit": {"a": float(a_), "b": float(b_)}, "drift_ppm": round(float((a_ - 1) * 1e6), 1),
           "residual_ms": {"median": round(float(np.median(np.abs(res))) * 1000, 1), "max": round(float(np.abs(res).max()) * 1000, 1)},
           "used_points": int(len(pts)), "unreadable": misses, "video_duration": vdur, "fps": fps}
    Path(s["out"]).write_text(json.dumps(out), encoding="utf-8")
    progress(1.0, L("fertig", "done"))
    return out


# ----------------------------------------------------------------------------------------- Untertitel

# Wie frontend/src/forensic/subtitles.ts (Nutzer 20.11.2026: Windows Media Player lehnte die SRT ab). Der Untertitel-Parser
# von Windows verwirft die ganze Datei, sobald eine Zeile 1024 Zeichen erreicht (DataFormatError 0xC00D36B1); Übersetzungen
# standen bis dahin in einer Zeile und erreichten 2983 Zeichen. Deshalb höchstens zwei Zeilen zu 42 Zeichen je Block,
# längere Texte auf aufeinanderfolgende Blöcke verteilt (Zeit nach Textlänge), sortiert, CRLF.
SUB_LINE = 42
SUB_LINES = 2


def sub_wrap(text: str, width: int = SUB_LINE) -> list[str]:
    lines: list[str] = []
    cur = ""
    for w in str(text).split():
        while len(w) > width:
            if cur:
                lines.append(cur)
                cur = ""
            lines.append(w[:width])
            w = w[width:]
        if not w:
            continue
        if not cur:
            cur = w
        elif len(cur) + 1 + len(w) <= width:
            cur += " " + w
        else:
            lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines


def sub_layout(cues: list[dict[str, Any]], clip: tuple[float, float] | None = None) -> list[dict[str, Any]]:
    """[{start, end, text}] → [{start, end, lines}]: umbrochen, lange Blöcke aufgeteilt, auf clip beschnitten, sortiert."""
    out: list[tuple[float, int, dict[str, Any]]] = []
    for c in cues:
        lines = sub_wrap(c["text"])
        if not lines:
            continue
        chunks = [lines[i:i + SUB_LINES] for i in range(0, len(lines), SUB_LINES)]
        weights = [len(" ".join(ch)) for ch in chunks]
        total = sum(weights) or 1
        start, end = float(c["start"]), float(c["end"])
        dur = max(0.0, end - start)
        t0, acc = start, 0
        for i, ch in enumerate(chunks):
            acc += weights[i]
            t1 = max(start, end) if i == len(chunks) - 1 else start + dur * acc / total
            a, b = (max(clip[0], t0), min(clip[1], t1)) if clip else (t0, t1)
            if not clip or b > a or (t1 == t0 and clip[0] <= t0 < clip[1]):
                out.append((a, len(out), {"start": a, "end": b, "lines": ch}))
            t0 = t1
    out.sort(key=lambda x: (x[0], x[1]))
    return [x[2] for x in out]


def sub_time(x: float, sep: str = ",") -> str:
    ms = int(round(max(0.0, x) * 1000))
    return f"{ms // 3600000:02d}:{ms // 60000 % 60:02d}:{ms // 1000 % 60:02d}{sep}{ms % 1000:03d}"


def srt_text(laid: list[dict[str, Any]]) -> str:
    return "\r\n".join(f"{i + 1}\r\n{sub_time(c['start'])} --> {sub_time(c['end'])}\r\n" + "\r\n".join(c["lines"]) + "\r\n"
                       for i, c in enumerate(laid))


class SubBurner:
    """Untertitel ins dekodierte Bild mischen, direkt in Y, U und V (weiße Schrift auf halbdurchsichtigem Schwarz, wie
    drawSubtitles in subtitles.ts). Nur die Zeilen mit Untertitel werden angefasst; alle anderen Bildpunkte bleiben, wie
    der Dekoder sie liefert, und es gibt keinen Umweg über RGB (keine Farbverschiebung)."""

    def __init__(self, w: int, h: int, laid: list[dict[str, Any]]):
        self.w, self.h, self.laid = w, h, laid
        self.size = max(14, round(h * 0.045))
        self.font = _font(self.size, bold=True)
        self.key: tuple[int, ...] | None = None
        self.masks: tuple[int, Any, Any] | None = None

    def active(self, t: float) -> list[int]:
        on = [i for i, c in enumerate(self.laid) if c["start"] <= t < c["end"]]
        return on[-3:]

    def _render(self, idx: list[int]) -> tuple[int, Any, Any] | None:
        from PIL import Image, ImageDraw
        w, h, size = self.w, self.h, self.size
        lh = round(size * 1.3)
        pad = round(size * 0.4)
        gap = round(size * 0.35)
        box = Image.new("L", (w, h), 0)
        txt = Image.new("L", (w, h), 0)
        db, dt = ImageDraw.Draw(box), ImageDraw.Draw(txt)
        y = h - round(h * 0.06)
        for i in reversed(idx):
            for line in reversed(self.laid[i]["lines"]):
                tw = min(w - 8, dt.textlength(line, font=self.font))
                db.rectangle([round(w / 2 - tw / 2 - pad), y - lh, round(w / 2 + tw / 2 + pad) - 1, y - 1], fill=158)  # 0,62
                dt.text((w / 2, y - lh / 2), line, font=self.font, fill=255, anchor="mm")
                y -= lh
            y -= gap
        top = max(0, (y - 2) & ~1)
        a_box = np.asarray(box, np.float32)[top:] / 255.0
        a_txt = np.asarray(txt, np.float32)[top:] / 255.0
        return top, a_box, a_txt

    def apply(self, frame: Any, t: float) -> Any:
        import av
        idx = self.active(t)
        if not idx:
            return frame
        if tuple(idx) != self.key:
            self.key = tuple(idx)
            self.masks = self._render(idx)
        if self.masks is None:
            return frame
        top, a_box, a_txt = self.masks
        fmt = frame.format.name
        if fmt not in ("yuv420p", "yuvj420p"):
            frame = frame.reformat(format="yuv420p")
            fmt = "yuv420p"
        full = fmt == "yuvj420p"
        lo, hi = (0.0, 255.0) if full else (16.0, 235.0)
        arr = frame.to_ndarray()  # Y (h Zeilen), dann U und V (je h/4 Zeilen zu w Spalten)
        w, h = self.w, self.h
        y = arr[top:h].astype(np.float32)
        y = y * (1 - a_box) + lo * a_box
        y = y * (1 - a_txt) + hi * a_txt
        arr[top:h] = np.clip(np.rint(y), 0, 255).astype(np.uint8)
        # Farbe: Alpha auf halbe Auflösung, Grau = 128 (Schwarz und Weiß haben keine Farbe)
        keep = (1 - a_box) * (1 - a_txt)
        keep_c = keep.reshape(keep.shape[0] // 2, 2, w // 2, 2).mean(axis=(1, 3))
        uv = arr[h:].reshape(2, h // 2, w // 2)
        part = uv[:, top // 2:].astype(np.float32)
        uv[:, top // 2:] = np.clip(np.rint(128 + (part - 128) * keep_c), 0, 255).astype(np.uint8)
        out = av.VideoFrame.from_ndarray(arr, format=fmt)
        out.pts, out.time_base = frame.pts, frame.time_base
        return out


def cmd_videoexport(s: dict[str, Any]) -> dict[str, Any]:
    """Video mit neuem Ton: Bild unverändert kopiert (ab dem Schlüsselbild vor dem Anfang), Ton aus den Spuren der
    Aufnahme gemischt und über die Ausrichtung (video_t = a·t + b) auf die Video-Zeit gelegt, AAC. Untertitel als
    SRT daneben; mit burn zusätzlich ins Bild gebrannt (Bild neu kodiert, NVENC, sonst x264). s: video, fit {a, b},
    tracks [{file, gain_db}], region [t0, t1] (Aufnahme-Zeit) oder None, out, kbps, mono, srt (Liste {start, end, text}
    in Aufnahme-Zeit) oder None, burn."""
    import av
    from scipy.signal import resample_poly
    a_, b_ = float(s["fit"]["a"]), float(s["fit"]["b"])
    files = [x["file"] for x in s["tracks"]]
    gains = [10 ** (float(x.get("gain_db") or 0) / 20) for x in s["tracks"]]
    sr = at.info(files[0])[0]
    total_r = min(at.info(f)[2] for f in files) / sr
    vin = av.open(s["video"])
    vs = next(st for st in vin.streams if st.type == "video")
    vdur = float(vin.duration or 0) / 1e6
    t0, t1 = (s.get("region") or [0.0, total_r])[:2]
    tau0 = max(0.0, a_ * float(t0) + b_)
    tau1 = min(vdur, a_ * float(t1) + b_)
    if tau1 - tau0 < 0.5:
        raise SystemExit(L("Der Bereich liegt nicht im Video.", "The range is not inside the video."))
    # Schlüsselbild vor dem Anfang suchen. Die Pakete danach werden nicht mehr gesammelt (bei 10 Stunden Video 9 bis
    # 27 GB im Speicher), sondern nach dem Ton direkt aus dem Demuxer weitergereicht (video_packets)
    vin.seek(int(tau0 / vs.time_base), stream=vs, backward=True, any_frame=False)
    demux = vin.demux(vs)
    head = None
    for packet in demux:
        if packet.dts is None or packet.pts is None:
            continue
        if packet.is_keyframe:
            head = packet
            break
    if head is None:
        raise SystemExit(L("Kein Schlüsselbild im Bereich gefunden.", "No keyframe found in the range."))
    first = head.pts

    def video_packets() -> Any:
        """Ab dem Schlüsselbild alle Pakete bis vor das erste hinter dem Ende, in Dekodier-Reihenfolge."""
        if float(head.pts * vs.time_base) > tau1:
            return
        yield head
        for packet in demux:
            if packet.dts is None or packet.pts is None:
                continue
            if float(packet.pts * vs.time_base) > tau1:
                return
            yield packet
    out = Path(s["out"])
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_name(out.stem + ".part" + out.suffix)
    c = av.open(str(tmp), "w", format="mp4", options={"movflags": "+faststart"})
    burn = bool(s.get("burn") and s.get("srt"))
    vw, vh = int(vs.codec_context.width) & ~1, int(vs.codec_context.height) & ~1
    vfps = vs.average_rate or vs.guessed_rate or 30
    enc = ""
    if burn:
        enc = _pick_h264(vw, vh, max(1, round(float(vfps))))
        vout = c.add_stream(enc, rate=vfps)
        vout.width, vout.height, vout.pix_fmt = vw, vh, "yuv420p"
        vout.bit_rate = int(min(40e6, max(2e6, vw * vh * float(vfps) * 0.16)))
        vout.codec_context.gop_size = max(1, round(2 * float(vfps)))
        if enc.endswith("_nvenc"):
            vout.options = {"preset": "p5", "rc": "vbr", "cq": "20"}
        elif enc == "libx264":
            vout.options = {"preset": "veryfast", "crf": "18"}
    else:
        vout = c.add_stream_from_template(vs)
    st_a = c.add_stream("aac", rate=48000)
    st_a.layout = "mono" if s.get("mono") else "stereo"
    st_a.bit_rate = int(s.get("kbps") or 192) * 1000
    count = 0
    kf = float(first * vs.time_base)
    # Ton für [kf, tau1] in Video-Zeit
    out_sr = 48000
    up = out_sr // sr if out_sr % sr == 0 else None
    chunk = 60.0
    tau = kf
    from fractions import Fraction
    written = 0
    res = av.AudioResampler(format="fltp", layout=st_a.layout, rate=out_sr)
    peak = 0.0
    total = tau1 - kf
    while tau < tau1 - 1e-6:
        tb = min(tau1, tau + chunk)
        ta_r, tb_r = (tau - b_) / a_, (tb - b_) / a_   # Aufnahme-Zeit
        lo = max(0.0, ta_r - 0.2)
        hi = min(total_r, tb_r + 0.2)
        n_out = int(round((tb - tau) * out_sr))
        y = np.zeros(n_out, np.float32)
        if hi > lo:
            parts = list(_mix_blocks(files, gains, block_seconds=hi - lo + 1, start=int(lo * sr), frames=int((hi - lo) * sr)))
            x = np.concatenate([p[:, 0] for p in parts]) if parts else np.zeros(0, np.float32)
            xu = resample_poly(x, up, 1).astype(np.float32) if up else at._resample(x.reshape(-1, 1), sr, out_sr)[:, 0]
            pos = (((tau + np.arange(n_out) / out_sr) - b_) / a_ - lo) * out_sr
            ok = (pos >= 0) & (pos <= len(xu) - 1)
            y[ok] = np.interp(pos[ok], np.arange(len(xu)), xu)
        peak = max(peak, float(np.abs(y).max()) if len(y) else 0.0)
        y = np.clip(y, -1, 1)
        arr = y.reshape(1, -1) if s.get("mono") else np.repeat(y, 2).reshape(1, -1)  # verschränkt: L0 R0 L1 R1 …
        frame = av.AudioFrame.from_ndarray(np.ascontiguousarray(arr), format="flt", layout=st_a.layout)
        frame.sample_rate = out_sr
        # Zeitstempel setzen: Dann weist die MP4 den Vorlauf des AAC-Kodierers (1024 Proben) aus, und der Ton liegt nicht
        # 21 ms zu spät (gemessen 18.11.: ohne −21,3 ms, Lagebild-Video mit Zeitstempeln 0 ms)
        frame.pts = written
        frame.time_base = Fraction(1, out_sr)
        written += n_out
        for f in res.resample(frame):
            for p in st_a.encode(f):
                c.mux(p)
        tau = tb
        progress(0.6 * (tau - kf) / max(1e-6, total), L("Ton mischen", "mixing the audio"))
    for f in res.resample(None):
        for p in st_a.encode(f):
            c.mux(p)
    for p in st_a.encode(None):
        c.mux(p)
    # Untertitel in Video-Zeit ab dem ersten Bild, umbrochen und auf das Video beschnitten (für SRT und Einbrennen gleich)
    laid: list[dict[str, Any]] = []
    if s.get("srt"):
        cues = [{"start": a_ * float(x["start"]) + b_ - kf, "end": a_ * float(x["end"]) + b_ - kf, "text": x["text"]}
                for x in s["srt"] if str(x.get("text") or "").strip()]
        laid = sub_layout([x for x in cues if x["end"] > 0 and x["start"] < total], clip=(0.0, total))
    if burn:
        from fractions import Fraction
        burner = SubBurner(vw, vh, laid)
        dec = vs.codec_context
        tb_out = Fraction(1, 1) / Fraction(vfps)
        last = -1

        def put(frame: Any) -> None:
            nonlocal count, last
            if frame.pts is None or frame.pts < first:
                return  # vor dem Schlüsselbild (offene Bildgruppe)
            rel = float((frame.pts - first) * vs.time_base)
            if rel > total + 1e-6:
                return
            if (frame.width, frame.height) != (vw, vh):
                frame = frame.reformat(width=vw, height=vh)
            f2 = burner.apply(frame, rel)
            f2.pts = max(last + 1, int(round(rel / float(tb_out))))
            f2.time_base = tb_out
            last = f2.pts
            for pk in vout.encode(f2):
                c.mux(pk)
            count += 1
        for i, packet in enumerate(video_packets()):
            pt = float(packet.pts * vs.time_base)
            for frame in dec.decode(packet):
                put(frame)
            if i % 100 == 0:
                progress(0.6 + 0.4 * min(1.0, (pt - kf) / max(1e-6, total)), L("Untertitel einbrennen", "burning in subtitles"))
        for frame in dec.decode(None):
            put(frame)
        for pk in vout.encode(None):
            c.mux(pk)
    else:
        for i, packet in enumerate(video_packets()):
            pt = float(packet.pts * vs.time_base)
            packet.pts -= first
            packet.dts -= first
            packet.stream = vout
            c.mux(packet)
            count += 1
            if i % 500 == 0:
                progress(0.6 + 0.4 * min(1.0, (pt - kf) / max(1e-6, total)), L("Bild übernehmen", "copying the picture"))
    c.close()
    vin.close()
    os.replace(tmp, out)
    srt = None
    if s.get("srt"):
        srt = out.with_suffix(".srt")
        srt.write_text(srt_text(laid), encoding="utf-8-sig", newline="")
    return {"file": str(out), "srt": str(srt) if srt else None, "cues": len(laid), "burned": enc or None,
            "video_start": round(kf, 3), "video_end": round(tau1, 3),
            "record_start": round((kf - b_) / a_, 3), "packets": count, "peak": round(peak, 4),
            "size_mb": round(out.stat().st_size / 1024 ** 2, 1)}


# ----------------------------------------------------------------------------------------- Lagebild-Video

# Farben wie im Zeitstrahl (Lanes.tsx, EVENT_COLOR) und Farbskala wie spectro.ts
EV_COLORS = {"alarm": (255, 93, 93), "alert": (255, 138, 93), "digital": (255, 200, 87), "analog": (224, 192, 96),
             "telegraph": (124, 196, 255), "autopilot": (154, 208, 255), "ais": (179, 157, 219), "text": (200, 200, 200),
             "gap": (119, 119, 119), "system": (153, 153, 153), "tone": (255, 143, 171)}
SPEC_STOPS = [(0, 4, 4, 12), (0.2, 40, 16, 80), (0.4, 110, 30, 120), (0.6, 200, 60, 90), (0.8, 248, 150, 60),
              (1, 252, 250, 190)]


def _font(size: int, bold: bool = False) -> Any:
    from PIL import ImageFont
    names = ["segoeuib.ttf", "arialbd.ttf", "DejaVuSans-Bold.ttf"] if bold else ["segoeui.ttf", "arial.ttf", "DejaVuSans.ttf"]
    for d in (Path(os.environ.get("WINDIR", r"C:\Windows")) / "Fonts", Path("/usr/share/fonts/truetype/dejavu")):
        for name in names:
            try:
                return ImageFont.truetype(str(d / name), size)
            except OSError:
                continue
    return ImageFont.load_default()


def _fit(d: Any, text: str, font: Any, width: float) -> str:
    """Text auf eine Breite kürzen (mit …)."""
    text = " ".join(str(text).split())
    if width <= 8:
        return ""
    if d.textlength(text, font=font) <= width:
        return text
    lo, hi = 0, len(text)
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if d.textlength(text[:mid] + "…", font=font) <= width:
            lo = mid
        else:
            hi = mid - 1
    return text[:lo] + "…" if lo else ""


def _wrap(d: Any, text: str, font: Any, width: float) -> list[str]:
    lines: list[str] = []
    cur = ""
    for w in str(text).split():
        nxt = f"{cur} {w}".strip()
        if d.textlength(nxt, font=font) <= width or not cur:
            cur = nxt
        else:
            lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines


def _rgb(color: Any, default: tuple[int, int, int] = (118, 185, 0)) -> tuple[int, int, int]:
    c = str(color or "")
    if len(c) == 7 and c.startswith("#"):
        try:
            return int(c[1:3], 16), int(c[3:5], 16), int(c[5:7], 16)
        except ValueError:
            pass
    return default


def _pick_h264(w: int, h: int, fps: int) -> str:
    import io as _io
    import av
    for name in ("h264_nvenc", "h264_amf", "h264_qsv", "libx264"):
        if name not in av.codecs_available:
            continue
        try:
            with av.open(_io.BytesIO(), "w", format="mp4") as probe:
                st = probe.add_stream(name, rate=fps)
                st.width, st.height, st.pix_fmt = w, h, "yuv420p"
                for pkt in st.encode(av.VideoFrame.from_ndarray(np.zeros((h, w, 3), np.uint8), format="rgb24")):
                    probe.mux(pkt)
                for pkt in st.encode():
                    probe.mux(pkt)
            return name
        except Exception:  # noqa: BLE001 - nächster Encoder
            continue
    raise SystemExit(L("Kein H.264-Encoder verfügbar.", "No H.264 encoder available."))


def _clock(origin: float | None, x: float, tenths: bool = False, date: bool = False) -> str:
    if not origin:
        h, r = divmod(max(0.0, x), 3600)
        m, sec = divmod(r, 60)
        return f"{int(h)}:{int(m):02d}:{sec:04.1f}" if tenths else f"{int(h)}:{int(m):02d}:{int(sec):02d}"
    import datetime as dt
    d = dt.datetime.fromtimestamp(origin + x, dt.timezone.utc)
    return d.strftime("%Y-%m-%d %H:%M:%S" if date else "%H:%M:%S") + (f".{d.microsecond // 100000}" if tenths else "")


def _deg(v: float | None, lon: bool = False) -> str:
    """Wie Monitor.tsx (fmtLat): Grad und Dezimalminuten."""
    if v is None:
        return "–"
    hemi = ("W" if v < 0 else "E") if lon else ("S" if v < 0 else "N")
    a = abs(v)
    d = int(a)
    return f"{d:0{3 if lon else 2}d}° {(a - d) * 60:06.3f}′ {hemi}"


def _envelope_cols(path: str, a: float, b: float, cols: int) -> np.ndarray:
    """min/max je Bildspalte für [a, b) einer Spur, blockweise (auch für Stunden)."""
    sr, _, total = at.info(path)
    s0, s1 = int(a * sr), min(total, int(b * sr))
    edges = np.linspace(s0, s1, cols + 1).astype(np.int64)
    mn = np.zeros(cols, np.float32)
    mx = np.zeros(cols, np.float32)
    pos = s0
    for block in at.read_blocks(path, block_seconds=60.0, start=s0, frames=max(0, s1 - s0)):
        mono = block.mean(axis=1) if block.shape[1] > 1 else block[:, 0]
        n = len(mono)
        c0 = max(0, int(np.searchsorted(edges, pos, side="right")) - 1)
        c1 = min(cols, int(np.searchsorted(edges, pos + n, side="left")))
        for c in range(c0, c1):
            lo, hi = max(edges[c], pos) - pos, min(edges[c + 1], pos + n) - pos
            if hi > lo:
                seg = mono[lo:hi]
                mn[c] = min(mn[c], float(seg.min()))
                mx[c] = max(mx[c], float(seg.max()))
        pos += n
    return np.stack([mn, mx])


def _spec_image(base: str, a: float, b: float, cols: int, rows: int, lo: float, hi: float, fshow: float) -> np.ndarray | None:
    """Spektrogramm wie im Zeitstrahl: aus den vorberechneten Stufen die gröbste, die noch fein genug ist, Spalten per
    Maximum zusammengefasst, Bänder bis fshow, dB-Fenster [lo, hi], Farbskala wie im Browser (spectro.ts)."""
    pick = None
    need = (b - a) / max(1, cols)
    for suffix in (".spec", ".spec1", ".spec2", ".spec3"):
        path = Path(base + suffix)
        if not path.is_file():
            continue
        with path.open("rb") as fh:
            head = SPEC_HEAD.unpack(fh.read(SPEC_HEAD.size))
        if head[0] != SPEC_MAGIC:
            continue
        cs = head[3] / head[4]
        if pick is None or cs <= need:
            pick = (path, head, cs)
    if pick is None:
        return None
    path, head, cs = pick
    bins, fmax, ncols, dlo, dhi = head[2], head[5], head[6], head[7], head[8]
    c0 = max(0, int(a / cs))
    c1 = min(ncols, int(math.ceil(b / cs)) + 1)
    if c1 <= c0:
        return None
    with path.open("rb") as fh:
        fh.seek(SPEC_HEAD.size + c0 * bins)
        raw = fh.read((c1 - c0) * bins)
    data = np.frombuffer(raw, np.uint8)
    data = data[: len(data) // bins * bins].reshape(-1, bins)
    if not len(data):
        return None
    starts = np.clip(((a + np.arange(cols) * need) / cs).astype(np.int64) - c0, 0, len(data) - 1)
    img = np.maximum.reduceat(data, starts, axis=0) if need >= cs else data[starts]
    top = max(1, min(bins, int(round(min(fshow, fmax) / fmax * bins))))
    kk = np.minimum(bins - 1, ((rows - 1 - np.arange(rows)) / rows * top).astype(np.int64))
    db = dlo + img[:, kk].T.astype(np.float32) * (dhi - dlo) / 255
    v = np.clip((db - lo) / max(1.0, hi - lo), 0, 1) * 255
    stops = np.array(SPEC_STOPS, np.float32)
    lut = np.stack([np.interp(np.arange(256) / 255, stops[:, 0], stops[:, k]) for k in (1, 2, 3)], axis=1)
    return lut.round().astype(np.uint8)[v.round().astype(np.uint8)]


def cmd_render(s: dict[str, Any]) -> dict[str, Any]:
    """Lagebild-Video (Nutzer 17.11.: „video … mit ausgewählten spuren (die visualisierung wie ich es sehe unten) und
    angekreuzten einzeln mitlesen, radar … ereignisse, über die ausgewählten spuren läuft der vertikale zeit marker und
    die zeitstempel sind zu sehen“). 1920 × 1080: Kopf mit Datum und Uhrzeit (UTC), darunter die angekreuzten Ansichten
    (Mitlesen, Bildquellen des Schreibers, Fahrstand, Karte, Ereignisse, Live-Player-Bild), unten Zeitlineal, Notizen-,
    Übersetzer- und Ereignis-Streifen und die Spuren (Welle oder Spektrogramm wie im Zeitstrahl), über die der Zeitmarker
    läuft. Ton: Mix der Spuren mit ihrem Pegel, AAC. Ansichten einmal je Sekunde, Marker, Uhr und Live-Player-Bild je Bild.
    s: out, region, fps, origin, lang, title, panels, tracks [{file, spec_base, gain_db, name, color, view}], spec {lo,
    hi, fmax}, segments, target_lang, notes, events, series (Pfad), images (Pfad), images_dir, video {path, fit}, mono."""
    import av
    from fractions import Fraction
    from PIL import Image, ImageDraw
    W, H = 1920, 1080
    fps = max(1, min(30, int(s.get("fps") or 10)))
    t0, t1 = float(s["region"][0]), float(s["region"][1])
    dur = max(1.0, t1 - t0)
    origin = s.get("origin")
    de = (s.get("lang") or "de") == "de"

    def L(a: str, b: str) -> str:
        return a if de else b

    chosen = list(s.get("panels") or [])
    panels = [p for p in chosen if p != "tracks"]
    tracks = s.get("tracks") or []
    show_tracks = "tracks" in chosen and bool(tracks)
    segs = sorted([g for g in s.get("segments") or [] if g["end"] >= t0 and g["start"] <= t1], key=lambda g: g["start"])
    notes = [n for n in s.get("notes") or [] if max(n["end"], n["start"]) >= t0 and n["start"] <= t1]
    events = sorted([e for e in s.get("events") or [] if e.get("kind") != "system"], key=lambda e: e["t"])
    ev_in = [e for e in events if (e["end"] if e.get("end") is not None else e["t"]) >= t0 and e["t"] <= t1]
    tl = s.get("target_lang") or "de"
    spec_cfg = s.get("spec") or {}
    f_s, f_m, f_l, f_b, f_h = _font(15), _font(19), _font(24), _font(18, True), _font(24, True)
    BG, PANEL, LINE, TXT, MUTED, ACC = (15, 19, 23), (24, 29, 35), (52, 60, 70), (230, 235, 240), (140, 150, 160), (118, 185, 0)
    head_h = 46
    lanes_h = 0
    if show_tracks:
        lanes_h = H - head_h if not panels else min(520, 170 + 64 * len(tracks))
    panel_h = H - head_h - lanes_h - (4 if lanes_h and panels else 0)
    label_w, pad = 230, 12
    pw = W - label_w - pad * 2
    x0p = label_w + pad

    def X(t_: float) -> float:
        return x0p + (t_ - t0) / dur * pw

    # ---------------- Spuren, einmal gezeichnet
    lanes_arr = None
    if show_tracks:
        img = Image.new("RGB", (W, lanes_h), BG)
        d = ImageDraw.Draw(img)
        ruler_h = 26
        d.rectangle([0, 0, W, ruler_h], fill=(19, 24, 29))
        steps = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 10800]
        step = next((x for x in steps if x / dur * pw >= 120), 10800)
        base_t = float(origin or 0)
        tt = math.ceil((base_t + t0) / step) * step - base_t
        while tt <= t1:
            xx = X(tt)
            d.line([xx, 6, xx, ruler_h], fill=(90, 100, 110))
            d.text((xx + 4, 4), _clock(origin, tt), font=f_s, fill=MUTED)
            tt += step
        d.text((10, 4), "UTC" if origin else L("Zeit", "Time"), font=f_s, fill=MUTED)
        y = ruler_h + 2
        strips = ([("notes", 24)] if notes else []) + ([("speech", 30)] if segs else []) + ([("events", 22)] if ev_in else [])
        rest = lanes_h - y - sum(hh + 2 for _, hh in strips) - 2
        th = max(24, rest // max(1, len(tracks)) - 2)
        names = {"notes": L("Notizen", "Notes"), "speech": L("Übersetzer-Spur", "Translation track"), "events": L("Ereignisse", "Events")}
        for kind, hh in strips:
            d.rectangle([0, y, label_w, y + hh], fill=PANEL)
            d.text((10, y + 3), names[kind], font=f_s, fill=TXT)
            if kind == "notes":
                for n in notes:
                    xa, xb = X(max(t0, n["start"])), X(min(t1, max(n["end"], n["start"])))
                    d.rectangle([xa, y + 3, max(xa + 3, xb), y + hh - 3], fill=(36, 62, 84), outline=(124, 196, 255))
                    if xb - xa > 40:
                        d.text((xa + 4, y + 3), _fit(d, n.get("label") or "", f_s, xb - xa - 8), font=f_s, fill=TXT)
            elif kind == "speech":
                for g in segs:
                    xa, xb = X(max(t0, g["start"])), X(min(t1, g["end"]))
                    ok = g.get("status") == "checked"
                    d.rectangle([xa, y + 3, max(xa + 2, xb), y + hh - 3], fill=(44, 66, 24) if ok else (74, 60, 24),
                                outline=ACC if ok else (255, 209, 102))
                    if xb - xa > 50:
                        txt = (g.get("translation") or {}).get(tl) or g.get("text") or ""
                        d.text((xa + 4, y + 6), _fit(d, txt, f_s, xb - xa - 8), font=f_s, fill=TXT)
            else:
                for e in ev_in:
                    col = EV_COLORS.get(e.get("kind"), (170, 170, 170))
                    xa = X(max(t0, e["t"]))
                    if e.get("end") is not None:
                        xb = X(min(t1, e["end"]))
                        d.rectangle([xa, y + 8, max(xa + 1, xb), y + hh - 8], fill=tuple(int(c * 0.45) for c in col))
                    if e["t"] >= t0:
                        d.line([xa, y + 2, xa, y + hh - 2], fill=col, width=2)
            y += hh + 2
        for k, tr in enumerate(tracks):
            col = _rgb(tr.get("color"))
            d.rectangle([0, y, label_w, y + th], fill=PANEL)
            d.rectangle([0, y, 3, y + th], fill=col)
            d.text((12, y + 4), _fit(d, str(tr.get("name") or ""), f_s, label_w - 20), font=f_s, fill=TXT)
            if tr.get("gain_db") and th > 40:
                d.text((12, y + 22), f"{float(tr['gain_db']):+.1f} dB", font=f_s, fill=MUTED)
            view = tr.get("view") or "wave"
            spec_h = th if view == "spec" else (th * 3 // 5 if view == "both" else 0)
            sp = None
            if spec_h and tr.get("spec_base"):
                sp = _spec_image(tr["spec_base"], t0, t1, pw, spec_h, float(spec_cfg.get("lo", -95)),
                                 float(spec_cfg.get("hi", -20)), float(spec_cfg.get("fmax", 8000)))
            if sp is not None:
                img.paste(Image.fromarray(sp), (x0p, y))
            else:
                spec_h = 0
            wave_h = th - spec_h
            if wave_h > 4:
                env = _envelope_cols(tr["file"], t0, t1, pw)
                mid = y + spec_h + wave_h / 2
                amp = wave_h / 2 - 1
                if s.get("wave_norm", True):
                    peak = float(np.percentile(np.maximum(np.abs(env[0]), np.abs(env[1])), 99.5))
                    gain = min(30.0, 0.85 / peak) if peak > 1e-5 else 1.0
                    if gain > 1.2:
                        env = np.clip(env * gain, -1, 1)
                        if th > 40 or not tr.get("gain_db"):
                            d.text((12, y + (40 if tr.get("gain_db") and th > 58 else 22)), L(f"Anzeige ×{gain:.0f}", f"display ×{gain:.0f}"),
                                   font=f_s, fill=MUTED)
                for c in range(pw):
                    lo_, hi_ = float(env[0, c]), float(env[1, c])
                    if hi_ - lo_ > 1e-5:
                        d.line([x0p + c, mid - hi_ * amp, x0p + c, mid - lo_ * amp], fill=col)
            progress(0.02 + 0.06 * (k + 1) / len(tracks), L("Spuren zeichnen", "drawing tracks"))
            y += th + 2
        lanes_arr = np.asarray(img).copy()

    # ---------------- Daten der Ansichten
    def load(p: Any) -> Any:
        return json.loads(Path(p).read_text(encoding="utf-8")) if p and Path(p).is_file() else None
    series = load(s.get("series"))
    images = load(s.get("images")) or {}
    src_label = {x["id"]: x.get("label") or x["id"] for x in images.get("sources") or []}
    img_cache: dict[str, tuple[int, Any]] = {}
    dt_ser = float((series or {}).get("dt") or 1)

    def val(key: str, x: float) -> float | None:
        if not series or key not in series["series"]:
            return None
        vals = series["series"][key]["values"]
        i = int(math.floor(x / dt_ser))
        for k in range(min(i, len(vals) - 1), max(-1, i - 11), -1):
            if 0 <= k < len(vals) and vals[k] is not None:
                return float(vals[k])
        return None

    def num(v: float | None, digits: int, unit: str) -> str:
        return "–" if v is None else f"{v:.{digits}f} {unit}".strip()

    n_p = len(panels)
    pwid = (W - pad * (n_p + 1)) // max(1, n_p)
    iw, ih = pwid - 16, panel_h - 12 - 40
    video_box = None
    vin = vstream = vframes = None
    vfit = None
    if "video" in panels and (s.get("video") or {}).get("path"):
        vin = av.open(s["video"]["path"])
        vstream = vin.streams.video[0]
        vstream.thread_type = "AUTO"
        vfit = s["video"]["fit"]
        vt0 = max(0.0, vfit["a"] * t0 + vfit["b"] - 1)
        vin.seek(int(vt0 / vstream.time_base), stream=vstream, backward=True)
        vframes = vin.decode(vstream)
        k = panels.index("video")
        vw, vh = vstream.codec_context.width or 1920, vstream.codec_context.height or 1080
        sc = min(iw / vw, ih / vh)
        tw, th_ = max(2, int(vw * sc) // 2 * 2), max(2, int(vh * sc) // 2 * 2)
        video_box = (pad + k * (pwid + pad) + 8 + (iw - tw) // 2, head_h + 40 + (ih - th_) // 2, tw, th_)
    vstate: list[Any] = [None, -1e9]

    def video_image(x: float) -> np.ndarray | None:
        want = vfit["a"] * x + vfit["b"]
        while vstate[1] < want - 0.5 / fps:
            fr = next(vframes, None)
            if fr is None:
                break
            vstate[0] = fr
            vstate[1] = float(fr.pts * vstream.time_base) if fr.pts is not None else vstate[1] + 1 / 30
        if vstate[0] is None:
            return None
        return vstate[0].to_ndarray(width=video_box[2], height=video_box[3], format="rgb24")

    def draw_panels(x: float) -> np.ndarray:
        im = Image.new("RGB", (W, panel_h), BG)
        dr = ImageDraw.Draw(im)
        for k, p in enumerate(panels):
            px, py = pad + k * (pwid + pad), 6
            dr.rectangle([px, py, px + pwid, panel_h - 6], fill=PANEL, outline=LINE)
            title = {"text": L("Mitlesen", "Read along"), "conning": L("Fahrstand", "Conning"), "map": L("Karte", "Map"),
                     "events": L("Ereignisse", "Events"), "video": L("Live-Player-Bild", "Live Player picture")}.get(p)
            if p.startswith("img:"):
                title = src_label.get(p[4:], p[4:])
            dr.text((px + 8, py + 6), title or p, font=f_b, fill=ACC)
            cx, cy = px + 8, py + 40
            if p == "text":
                # Fußzeile: womit gerechnet wurde (Modelle, Lizenzen, Grafikkarte), höchstens zwei Zeilen
                foot = _wrap(dr, str(s.get("credits") or ""), f_s, iw)[:2] if segs else []
                foot_h = len(foot) * 19 + (8 if foot else 0)
                for k_, line in enumerate(foot):
                    dr.text((cx, panel_h - 12 - foot_h + 8 + k_ * 19), line, font=f_s, fill=MUTED)
                cur = [g for g in segs if g["start"] - 0.3 <= x <= g["end"] + 0.3][:2]
                prev = [g for g in segs if g["end"] + 0.3 < x][-2:]
                nxt = [g for g in segs if g["start"] - 0.3 > x][:1]
                for g, now in [(q, False) for q in prev] + [(q, True) for q in cur] + [(q, False) for q in nxt]:
                    if cy > panel_h - 50 - foot_h:
                        break
                    who = g.get("speaker") or g.get("track_name") or ""
                    draft = "" if g.get("status") == "checked" else L("  · Entwurf der KI", "  · AI draft")
                    dr.text((cx, cy), _fit(dr, f"{_clock(origin, g['start'])}  {who}{draft}", f_s, iw), font=f_s, fill=MUTED)
                    cy += 20
                    font = f_l if now else f_m
                    for line in _wrap(dr, g.get("text") or "", font, iw)[:3]:
                        dr.text((cx, cy), line, font=font, fill=TXT if now else MUTED)
                        cy += font.size + 4
                    trn = (g.get("translation") or {}).get(tl) or ""
                    for line in _wrap(dr, trn, font, iw)[:3]:
                        dr.text((cx, cy), line, font=font, fill=(255, 209, 102) if now else (150, 130, 80))
                        cy += font.size + 4
                    cy += 10
                if not segs:
                    dr.text((cx, cy), L("Keine Sprache in diesem Bereich.", "No speech in this range."), font=f_m, fill=MUTED)
            elif p.startswith("img:"):
                frames = (images.get("frames") or {}).get(p[4:]) or []
                lo_, hi_, idx = 0, len(frames) - 1, -1
                while lo_ <= hi_:
                    mid = (lo_ + hi_) // 2
                    if frames[mid][0] <= x:
                        idx, lo_ = mid, mid + 1
                    else:
                        hi_ = mid - 1
                if idx >= 0:
                    hit = img_cache.get(p)
                    if not hit or hit[0] != idx:
                        try:
                            pic = Image.open(Path(s["images_dir"]) / frames[idx][1]).convert("RGB")
                            pic.thumbnail((iw, ih))
                        except OSError:
                            pic = None
                        img_cache[p] = (idx, pic)
                    pic = img_cache[p][1]
                    if pic is not None:
                        im.paste(pic, (cx + (iw - pic.width) // 2, cy + (ih - pic.height) // 2))
                        stamp = f"{L('Bild', 'Picture')} {_clock(origin, frames[idx][0])}"
                        dr.text((px + pwid - 8 - dr.textlength(stamp, font=f_s), py + 9), stamp, font=f_s, fill=MUTED)
                else:
                    dr.text((cx, cy), L("Noch kein Bild.", "No picture yet."), font=f_m, fill=MUTED)
            elif p == "conning":
                r = val("rudder", x)
                rows = [(L("Breite", "Latitude"), _deg(val("lat", x))), (L("Länge", "Longitude"), _deg(val("lon", x), True)),
                        (L("Steuerkurs HDG", "Heading HDG"), num(val("hdg", x), 1, "°")), (L("Kurs üG COG", "COG"), num(val("cog", x), 1, "°")),
                        (L("Geschwindigkeit üG (SOG)", "SOG"), num(val("sog", x), 1, "kn")), (L("Geschwindigkeit dW (STW)", "STW"), num(val("stw", x), 1, "kn")),
                        (L("Drehrate ROT", "Rate of turn"), num(val("rot", x), 1, "°/min")),
                        (L("Ruder", "Rudder"), "–" if r is None else f"{abs(r):.1f}° {L('Bb', 'port') if r < 0 else L('Stb', 'stbd') if r > 0 else ''}".strip()),
                        (L("Ruder befohlen", "Rudder order"), num(val("rudder_order", x), 1, "°")),
                        (L("Drehzahl", "Engine RPM"), num(val("rpm", x), 0, "rpm")),
                        (L("Wind wahr", "True wind"), f"{num(val('wind_true_dir', x), 0, '°')} · {num(val('wind_true_speed', x), 1, 'kn')}"),
                        (L("Wassertiefe", "Depth"), num(val("depth", x), 1, "m"))]
                colw = iw // 2
                for i, (lab, txt) in enumerate(rows):
                    xx, yy = cx + (i % 2) * colw, cy + (i // 2) * 50
                    if yy > panel_h - 54:
                        break
                    dr.text((xx, yy), _fit(dr, lab, f_s, colw - 10), font=f_s, fill=MUTED)
                    dr.text((xx, yy + 17), _fit(dr, txt, f_l, colw - 10), font=f_l, fill=(159, 232, 112))
                states: dict[str, dict] = {}
                for e in events:
                    if e["t"] > x:
                        break
                    if e.get("kind") in ("digital", "telegraph", "autopilot"):
                        states[f"{e['kind']}:{e.get('label')}"] = e
                yy = cy + ((len(rows) + 1) // 2) * 50 + 4
                for e in list(states.values())[-8:]:
                    if yy > panel_h - 28:
                        break
                    dr.ellipse([cx, yy + 5, cx + 10, yy + 15], fill=EV_COLORS.get(e["kind"], (170, 170, 170)))
                    dr.text((cx + 16, yy), _fit(dr, f"{e.get('label') or ''}  · {L('seit', 'since')} {_clock(origin, e['t'])}", f_s, iw - 20), font=f_s, fill=TXT)
                    yy += 22
            elif p == "events":
                past = [e for e in events if e["t"] <= x][-14:]
                if not past:
                    dr.text((cx, cy), L("Noch kein Ereignis.", "No event yet."), font=f_m, fill=MUTED)
                for e in reversed(past):
                    if cy > panel_h - 30:
                        break
                    end = e.get("end")
                    active = (end is None and x - e["t"] < 10) or (end is not None and e["t"] <= x <= end)
                    dr.ellipse([cx + 2, cy + 6, cx + 12, cy + 16], fill=EV_COLORS.get(e.get("kind"), (170, 170, 170)))
                    label = f"{_clock(origin, e['t'])}  {e.get('label') or ''}" + (f" · {e['detail']}" if e.get("detail") else "")
                    dr.text((cx + 20, cy), _fit(dr, label, f_s, iw - 24), font=f_s, fill=TXT if active else MUTED)
                    cy += 24
            elif p == "map" and series and "lat" in series["series"] and "lon" in series["series"]:
                la, lo2 = series["series"]["lat"]["values"], series["series"]["lon"]["values"]
                i0, i1 = max(0, int(t0 / dt_ser)), min(len(la), int(t1 / dt_ser) + 1)
                pts = [(la[i], lo2[i]) for i in range(i0, i1, max(1, (i1 - i0) // 1500)) if la[i] is not None and lo2[i] is not None]
                here = (val("lat", x), val("lon", x))
                if pts and here[0] is not None and here[1] is not None:
                    las = [q[0] for q in pts] + [here[0]]
                    los = [q[1] for q in pts] + [here[1]]
                    clat, clon = (min(las) + max(las)) / 2, (min(los) + max(los)) / 2
                    cosl = math.cos(math.radians(clat))
                    span = max(max(las) - min(las), (max(los) - min(los)) * cosl, 0.01) * 1.25
                    sc = min(iw, ih) / span
                    mx0, my0 = cx + iw / 2, cy + ih / 2

                    def P(lat_: float, lon_: float) -> tuple[float, float]:
                        return (mx0 + (lon_ - clon) * cosl * sc, my0 - (lat_ - clat) * sc)
                    if len(pts) > 1:
                        dr.line([P(*q) for q in pts], fill=(124, 196, 255), width=2)
                    sx, sy = P(here[0], here[1])
                    hd = math.radians(val("hdg", x) or val("cog", x) or 0)
                    tri = [(sx + 13 * math.sin(hd), sy - 13 * math.cos(hd)), (sx + 8 * math.sin(hd + 2.5), sy - 8 * math.cos(hd + 2.5)),
                           (sx + 8 * math.sin(hd - 2.5), sy - 8 * math.cos(hd - 2.5))]
                    dr.polygon(tri, fill=ACC, outline=(255, 255, 255))
                    nm = span * 60
                    bar = next((b_ for b_ in (0.1, 0.25, 0.5, 1, 2, 5, 10, 20, 50) if b_ >= nm / 6), 50)
                    blen = bar / 60 * sc
                    dr.line([cx + 6, panel_h - 22, cx + 6 + blen, panel_h - 22], fill=TXT, width=2)
                    dr.text((cx + 8, panel_h - 44), f"{bar:g} {L('sm', 'nm')}", font=f_s, fill=TXT)
                    dr.text((cx + iw - 230, panel_h - 44), f"{_deg(here[0])}  {_deg(here[1], True)}", font=f_s, fill=MUTED)
                else:
                    dr.text((cx, cy), L("Keine Position.", "No position."), font=f_m, fill=MUTED)
            elif p == "video" and video_box is None:
                dr.text((cx, cy), L("Kein Video zugeordnet.", "No video linked."), font=f_m, fill=MUTED)
        return np.asarray(im)

    # ---------------- Kopf (ohne Uhr), einmal
    base = np.empty((H, W, 3), np.uint8)
    base[:] = BG
    hd_img = Image.new("RGB", (W, head_h), (19, 24, 29))
    dh = ImageDraw.Draw(hd_img)
    clock_w = 470
    dh.text((14, 9), _fit(dh, str(s.get("title") or ""), f_h, 700), font=f_h, fill=TXT)
    span_txt = f"{L('Bereich', 'Range')} {_clock(origin, t0)} – {_clock(origin, t1)}" + (" UTC" if origin else "")
    dh.text((760, 14), span_txt, font=f_m, fill=MUTED)
    base[:head_h] = np.asarray(hd_img)

    # ---------------- Kodieren: Ton und Bild sekundenweise verschränkt
    out = Path(s["out"])
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_name(out.stem + ".part.mp4")
    enc = _pick_h264(W, H, fps)
    c = av.open(str(tmp), "w", format="mp4", options={"movflags": "+faststart"})
    vs = c.add_stream(enc, rate=fps)
    vs.width, vs.height, vs.pix_fmt = W, H, "yuv420p"
    vs.bit_rate = 8_000_000
    vs.codec_context.gop_size = 2 * fps
    if enc.endswith("_nvenc"):
        vs.options = {"preset": "p5", "rc": "vbr", "cq": "23"}
    elif enc == "libx264":
        vs.options = {"preset": "veryfast", "crf": "22"}
    audio_tracks = [x for x in tracks if x.get("file")]
    st_a = res_a = None
    readers: list[Any] = []
    srs: list[int] = []
    mix_sr = 16000
    if audio_tracks:
        srs = [at.info(x["file"])[0] for x in audio_tracks]
        mix_sr = max(srs)
        st_a = c.add_stream("aac", rate=48000)
        st_a.layout = "mono" if s.get("mono") else "stereo"
        st_a.bit_rate = 192_000
        res_a = av.AudioResampler(format="fltp", layout=st_a.layout, rate=48000)
        readers = [at.read_blocks(x["file"], block_seconds=1.0, start=int(t0 * sr_), frames=int(dur * sr_))
                   for x, sr_ in zip(audio_tracks, srs)]
    gains = [10 ** (float(x.get("gain_db") or 0) / 20) for x in audio_tracks]
    n_frames = int(math.ceil(dur * fps))
    sec_count = int(math.ceil(dur))
    a_pos = 0
    k = 0
    peak = 0.0
    for sec in range(sec_count):
        if readers:
            acc = np.zeros(mix_sr, np.float32)
            n = 0
            for r, g, sr_ in zip(readers, gains, srs):
                b = next(r, None)
                if b is None or not len(b):
                    continue
                x_ = b.mean(axis=1) if b.shape[1] > 1 else b[:, 0]
                if sr_ != mix_sr:
                    m = int(round(len(x_) * mix_sr / sr_))
                    x_ = np.interp(np.arange(m) * sr_ / mix_sr, np.arange(len(x_)), x_).astype(np.float32)
                m = min(len(x_), mix_sr)
                acc[:m] += x_[:m] * g
                n = max(n, m)
            if n:
                acc = np.clip(acc[:n], -1, 1)
                peak = max(peak, float(np.abs(acc).max()))
                arr = acc.reshape(1, -1) if s.get("mono") else np.stack([acc, acc])
                fa = av.AudioFrame.from_ndarray(np.ascontiguousarray(arr), format="fltp", layout=st_a.layout)
                fa.sample_rate = mix_sr
                fa.pts = a_pos
                fa.time_base = Fraction(1, mix_sr)
                a_pos += n
                for f in res_a.resample(fa):
                    for pkt in st_a.encode(f):
                        c.mux(pkt)
        sec_frame = base.copy()
        if panels:
            sec_frame[head_h:head_h + panel_h] = draw_panels(t0 + sec)
        if lanes_arr is not None:
            sec_frame[H - lanes_h:] = lanes_arr
        while k < n_frames and k < (sec + 1) * fps:
            x = t0 + k / fps
            frame = sec_frame.copy()
            if video_box is not None:
                pic = video_image(x)
                if pic is not None:
                    bx, by, bw, bh = video_box
                    frame[by:by + pic.shape[0], bx:bx + pic.shape[1]] = pic[:bh, :bw]
            if lanes_arr is not None:
                mx_ = int(round(X(x)))
                if x0p <= mx_ < W - 2:
                    frame[H - lanes_h:, mx_:mx_ + 2] = 255
                    frame[H - lanes_h:H - lanes_h + 8, max(0, mx_ - 4):mx_ + 6] = 255
            ck = Image.new("RGB", (clock_w, head_h), (19, 24, 29))
            dc = ImageDraw.Draw(ck)
            label = _clock(origin, x, tenths=True, date=True) + (" UTC" if origin else "")
            dc.text((clock_w - 14 - dc.textlength(label, font=f_h), 9), label, font=f_h, fill=ACC)
            frame[:head_h, W - clock_w:] = np.asarray(ck)
            vf = av.VideoFrame.from_ndarray(frame, format="rgb24")
            vf.pts = k
            vf.time_base = Fraction(1, fps)
            for pkt in vs.encode(vf):
                c.mux(pkt)
            k += 1
        progress(0.08 + 0.92 * min(1.0, (sec + 1) / max(1, sec_count)), L(f"Bild {k} von {n_frames}", f"frame {k} of {n_frames}"))
    if res_a is not None:
        for f in res_a.resample(None):
            for pkt in st_a.encode(f):
                c.mux(pkt)
        for pkt in st_a.encode(None):
            c.mux(pkt)
    for pkt in vs.encode():
        c.mux(pkt)
    c.close()
    if vin is not None:
        vin.close()
    os.replace(tmp, out)
    return {"file": str(out), "frames": n_frames, "fps": fps, "encoder": enc, "seconds_video": round(dur, 1),
            "size_mb": round(out.stat().st_size / 1024 ** 2, 1), "audio_peak": round(peak, 3)}


def fmt_hms(x: float) -> str:
    return f"{int(x // 3600)}:{int(x % 3600 // 60):02d}:{int(x % 60):02d}"


def _speech_db(x: np.ndarray, sr: int, hop: int) -> np.ndarray:
    """Pegel im Sprachband (300–3400 Hz) je Rahmen von hop Proben (Hann, ohne Überlappung), in dB."""
    n = len(x) // hop
    if n == 0:
        return np.zeros(0, np.float32)
    fr = x[: n * hop].reshape(n, hop) * np.hanning(hop).astype(np.float32)
    p = np.abs(np.fft.rfft(fr, axis=1)) ** 2
    f = np.fft.rfftfreq(hop, 1 / sr)
    band = (f >= 300) & (f <= 3400)
    return (10 * np.log10(p[:, band].mean(axis=1) + 1e-14)).astype(np.float32)


def cmd_automix(s: dict[str, Any]) -> dict[str, Any]:
    """Bester Kanal: je Moment das Mikrofon mit der klarsten Sprache (Abstand des Sprachband-Pegels zum eigenen
    Rauschboden), mit Haltezeit und 40 ms Überblendung; ohne Sprache alle Kanäle gemittelt. Wählt nur aus, ändert
    keinen Kanal (forensisch nachvollziehbar). s: srcs (FLAC je Kanal, gleiche Rate), flac, peaks, proxy, decisions."""
    from scipy.ndimage import minimum_filter1d, uniform_filter1d
    srcs = list(s["srcs"])
    infos = [at.info(p) for p in srcs]
    sr = infos[0][0]
    if any(i[0] != sr for i in infos):
        raise SystemExit(L("Die Kanäle haben verschiedene Abtastraten.", "The channels have different sample rates."))
    frames = min(i[2] for i in infos)
    n_ch = len(srcs)
    hop = sr // 50                                   # 20 ms
    t0 = time.time()
    # 1. Sprachband-Pegel je Kanal und Rahmen
    levels: list[np.ndarray] = []
    for c, p in enumerate(srcs):
        parts = []
        for block in at.read_blocks(p, block_seconds=60.0, frames=frames):
            mono = block.mean(axis=1) if block.shape[1] > 1 else block[:, 0]
            parts.append(_speech_db(mono, sr, hop))
        levels.append(np.concatenate(parts) if parts else np.zeros(0, np.float32))
        progress(0.45 * (c + 1) / n_ch, L("Kanäle messen", "measuring channels"))
    n = min(len(x) for x in levels)
    E = np.stack([x[:n] for x in levels])            # (Kanäle, Rahmen)
    step = 5                                         # Rahmen je Schritt (0,1 s)
    m = n // step
    vads = s.get("vads") or []
    if vads and all(Path(v).exists() for v in vads):
        # Silero-Karten (je 0,1 s): Kanäle mit Sprache bekommen ihren Pegel, die übrigen −∞; die Schwelle 6 dB unten
        # greift dann für „Sprache da“ (Pegel weit über der digitalen Stille geschalteter VDR-Mikrofone)
        V = np.zeros((n_ch, m), np.uint8)
        for c, v in enumerate(vads):
            a_ = np.fromfile(v, dtype=np.uint8)[:m]
            V[c, :len(a_)] = a_
        lvl = E[:, : m * step].reshape(n_ch, m, step).mean(axis=2)
        S = np.where(V > 128, lvl - lvl.min() + 10.0, -100.0)
    else:
        floor = np.stack([uniform_filter1d(minimum_filter1d(e, 400, mode="nearest"), 1500, mode="nearest") for e in E])
        snr = uniform_filter1d(E - floor, 15, axis=1, mode="nearest")   # 0,3 s geglättet
        S = snr[:, : m * step].reshape(n_ch, m, step).mean(axis=2)
    # 2. Entscheidung je 0,1 s mit Haltezeit
    choice = np.full(m, -1, np.int16)                # −1: alle gemittelt
    cur, hold, quiet, better = -1, 0, 0, 0
    for k in range(m):
        best = int(np.argmax(S[:, k]))
        top = float(S[best, k])
        if top > 6.0:
            quiet = 0
            if cur < 0:
                cur, hold = best, 10
            elif best != cur and top - float(S[cur, k]) > 3.0 and hold <= 0:
                better += 1
                if better >= 3:
                    cur, hold, better = best, 10, 0
            else:
                better = 0
        else:
            quiet += 1
            if quiet > 15:
                cur = -1
        hold -= 1
        choice[k] = cur
    # 3. Mischen: Gewichte je Schritt, 40 ms Rampen an den Wechseln
    W = np.zeros((n_ch, m), np.float32)
    for c in range(n_ch):
        W[c] = (choice == c)
    W[:, choice < 0] = 1.0 / n_ch
    st = step * hop / sr                             # 0,1 s
    kt = np.empty(2 * m)
    kt[0::2] = np.arange(m) * st + 0.02
    kt[1::2] = (np.arange(m) + 1) * st - 0.02
    KW = np.repeat(W, 2, axis=1)
    w = at.Writer(Path(s["flac"]), sr, 1, Path(s["peaks"]), Path(s["proxy"]))
    readers = [at.read_blocks(p, block_seconds=60.0, frames=frames) for p in srcs]
    pos = 0
    for blocks in zip(*readers):
        ln = min(len(b) for b in blocks)
        tt = (pos + np.arange(ln)) / sr
        a, b = np.searchsorted(kt, tt[0]) - 2, np.searchsorted(kt, tt[-1]) + 2
        a, b = max(0, a), min(len(kt), b)
        out = np.zeros(ln, np.float32)
        for c, blk in enumerate(blocks):
            mono = blk[:ln].mean(axis=1) if blk.shape[1] > 1 else blk[:ln, 0]
            out += np.interp(tt, kt[a:b], KW[c, a:b]).astype(np.float32) * mono
        w.add(out.reshape(-1, 1))
        pos += ln
        progress(0.45 + 0.55 * pos / max(1, frames), L("mischen", "mixing"))
    res = w.close()
    # Abschnitte für die Anzeige und die Übersetzer-KI: [Anfang, Ende, Kanal (−1 = alle)]
    segs: list[list[float]] = []
    for k in range(m):
        c = int(choice[k])
        if segs and segs[-1][2] == c:
            segs[-1][1] = round((k + 1) * st, 2)
        else:
            segs.append([round(k * st, 2), round((k + 1) * st, 2), c])
    Path(s["decisions"]).write_text(json.dumps({"segments": segs, "channels": len(srcs)}), encoding="utf-8")
    progress(1.0, L("fertig", "done"))
    return {**res, "switches": sum(1 for x in segs if x[2] >= 0), "speech_seconds": round(sum(b - a for a, b, c in segs if c >= 0), 1),
            "compute_seconds": round(time.time() - t0, 1)}


def _runs(mask: np.ndarray, gap: int, min_len: int) -> list[list[int]]:
    """Zusammenhängende True-Strecken (Indizes), Lücken unter gap überbrückt, kürzer als min_len verworfen."""
    out: list[list[int]] = []
    i, n = 0, len(mask)
    while i < n:
        if mask[i]:
            j = i
            while j < n and mask[j]:
                j += 1
            if out and i - out[-1][1] < gap:
                out[-1][1] = j
            else:
                out.append([i, j])
            i = j
        else:
            i += 1
    return [r for r in out if r[1] - r[0] >= min_len]


def _switch_parts(sub: np.ndarray, s: int, e: int, hold: int = 20, margin: float = 16.0) -> list[tuple[int, int]]:
    """Einen Sprechabschnitt teilen, wo ein anderes Mikrofon mindestens hold Werte lang (2 s) klar vorn liegt (Nutzer
    17.11.: „nach der sirene hört man die auf der anderen spur besser“). Klar heißt: geglättete Sprachwahrscheinlichkeit
    mindestens margin (von 255) über der nächstbesten Spur; unklare Stellen zählen zur vorigen Spur. Geschnitten wird an
    der leisesten Stelle im Umkreis von 0,5 s, damit kein Wort zerfällt."""
    if sub.shape[0] < 2 or e - s < 2 * hold:
        return [(s, e)]
    x = sub[:, s:e].astype(np.float32)
    k = np.ones(10, np.float32) / 10
    sm = np.stack([np.convolve(r, k, mode="same") for r in x])
    order = np.sort(sm, axis=0)
    clear = (order[-1] - order[-2]) >= margin
    if not clear.any():
        return [(s, e)]
    lab = sm.argmax(axis=0)
    first = int(np.argmax(clear))
    lab[:first] = lab[first]
    last = int(lab[first])
    for i in range(first, len(lab)):
        if clear[i]:
            last = int(lab[i])
        else:
            lab[i] = last
    runs: list[list[int]] = []
    for i, v in enumerate(lab.tolist()):
        if runs and runs[-1][0] == v:
            runs[-1][2] = i + 1
        else:
            runs.append([v, i, i + 1])
    while len(runs) > 1:
        short = min(range(len(runs)), key=lambda j: runs[j][2] - runs[j][1])
        if runs[short][2] - runs[short][1] >= hold:
            break
        r = runs.pop(short)
        if short == 0:
            runs[0][1] = r[1]
        elif short >= len(runs):
            runs[-1][2] = r[2]
        elif runs[short - 1][2] - runs[short - 1][1] >= runs[short][2] - runs[short][1]:
            runs[short - 1][2] = r[2]
        else:
            runs[short][1] = r[1]
        merged = [runs[0]]
        for q in runs[1:]:
            if q[0] == merged[-1][0]:
                merged[-1][2] = q[2]
            else:
                merged.append(q)
        runs = merged
    if len(runs) == 1:
        return [(s, e)]
    curve = x.max(axis=0)
    bounds = [0]
    for q in runs[1:]:
        lo, hi = max(bounds[-1] + 1, q[1] - 5), min(len(curve) - 1, q[1] + 5)
        bounds.append(lo + int(np.argmin(curve[lo:hi])) if hi > lo else q[1])
    bounds.append(e - s)
    return [(s + bounds[i], s + bounds[i + 1]) for i in range(len(bounds) - 1) if bounds[i + 1] > bounds[i]]


def plan_regions(tracks: list[dict[str, Any]], region: list[float] | None, max_s: float = 28.0) -> list[dict[str, Any]]:
    """Abschnitte für die Spracherkennung aus der Sprachaktivität (je 0,1 s ein Wert 0–255, .act aus spectro):
    Mikrofone gemeinsam (je Abschnitt der Kanal mit der höchsten Aktivität, der zweitbeste als Gegenprobe), Funk
    (kind=radio) je Kanal getrennt. Lücken unter 0,6 s überbrückt, mindestens 0,4 s, je 0,25 s Rand, höchstens
    max_s (an der leisesten Stelle geteilt)."""
    acts = {}
    use_vad = all(tr.get("vad") and Path(tr["vad"]).exists() for tr in tracks)
    for tr in tracks:
        src = tr.get("vad") if use_vad else tr.get("act")
        a = np.fromfile(src, dtype=np.uint8) if src and Path(src).exists() else np.zeros(0, np.uint8)
        acts[tr["id"]] = a
    n = max((len(a) for a in acts.values()), default=0)
    lo, hi = 0, n
    if region:
        lo, hi = max(0, int(region[0] * ACT_RATE)), min(n, int(math.ceil(region[1] * ACT_RATE)))
    thr = 128 if use_vad else 90               # Silero: Wahrscheinlichkeit über 0,5
    out: list[dict[str, Any]] = []

    def split(a: int, b: int, curve: np.ndarray) -> list[list[int]]:
        step = int(max_s * ACT_RATE)
        parts, s = [], a
        while b - s > step:
            win = curve[s + int(step * 0.6): s + step]
            cut = s + int(step * 0.6) + int(np.argmin(win)) if len(win) else s + step
            parts.append([s, cut])
            s = cut
        parts.append([s, b])
        return parts

    groups = [[t for t in tracks if t.get("kind") != "radio"]] + [[t] for t in tracks if t.get("kind") == "radio"]
    for grp in groups:
        if not grp:
            continue
        mat = np.zeros((len(grp), n), np.uint8)
        for k, tr in enumerate(grp):
            a = acts[tr["id"]]
            mat[k, :len(a)] = a
        sub = mat[:, lo:hi]
        if not sub.size:
            continue
        curve = sub.max(axis=0).astype(np.float32)
        for a, b in _runs(curve > thr, gap=6, min_len=4):
            for s, e in (part for s0, e0 in split(a, b, curve) for part in _switch_parts(sub, s0, e0)):
                seg = sub[:, s:e].astype(np.float32).mean(axis=1)
                order = np.argsort(-seg)
                best = grp[int(order[0])]
                second = grp[int(order[1])]["id"] if len(order) > 1 else None
                t0 = max(0.0, (lo + s) / ACT_RATE - 0.25)
                t1 = (lo + e) / ACT_RATE + 0.25
                out.append({"id": f"{best['id']}@{t0:.1f}", "start": round(t0, 2), "end": round(t1, 2), "track": best["id"],
                            "second": second, "kind": best.get("kind") or "speech", "file": best["file"],
                            "score": round(float(seg[order[0]]), 1)})
    out.sort(key=lambda r: r["start"])
    return out


# Sätze, die Whisper auf Lärm und Stille erfindet (Trainingsdaten aus Videos mit Abspann); gefunden am 17.11. auf
# Nock-Mikrofonen mit Wind. Treffen sie, kommt der Abschnitt nicht in die Spur (im Protokoll gezählt).
HALLUCINATIONS = ("thank you for watching", "thanks for watching", "see you in the next video", "see you in the other video",
                  "please subscribe", "subscribe to", "like and subscribe", "subtitles by", "amara.org",
                  "untertitel im auftrag", "untertitelung", "copyright", "www.", "http")


def _loop_keep(norm: list[str]) -> int | None:
    """Beginn einer Wiederholungsschleife: Wiederholt sich ein Wort (mindestens 5-mal) oder eine Folge von 2 bis 4 Wörtern
    (mindestens 4-mal) direkt hintereinander, gilt alles nach dem ersten Vorkommen als Schleife. Ergebnis: Zahl der Wörter,
    die stehen bleiben, oder None. Echte Wiederholungen wie „Sige po. Sige po.“ (2-mal) bleiben."""
    for i in range(len(norm)):
        for n in (1, 2, 3, 4):
            unit = norm[i:i + n]
            if len(unit) < n or not all(unit):
                continue
            k = 1
            while norm[i + k * n:i + (k + 1) * n] == unit:
                k += 1
            if k >= (5 if n == 1 else 4):
                return i + n
    return None


def _cut_loops(x: dict[str, Any]) -> bool:
    """Whispers Wiederholungsschleifen abschneiden (17.11.: dasselbe Wort hunderte Male hintereinander, die Übersetzung
    wiederholte es mit): Text und Wörter enden nach dem ersten Vorkommen mit „…“."""
    toks = (x.get("text") or "").split()
    keep = _loop_keep([_norm_word(t) for t in toks])
    if keep is None:
        return False
    x["text"] = " ".join(toks[:keep]) + " …"
    words = x.get("words") or []
    wk = _loop_keep([_norm_word(w[2]) for w in words])
    if wk is not None:
        x["words"] = words[:wk]
    return True


def _hallucination(text: str) -> bool:
    low = text.lower()
    return any(h in low for h in HALLUCINATIONS)


def _norm_word(w: str) -> str:
    return "".join(ch for ch in w.lower() if ch.isalnum())


SECOND_SIM_MIN = 0.4      # Buchstaben-Ähnlichkeit des Abschnitts, ab der die Zweitmeinung „im Großen gleich“ hört
WORD_COVER_MIN = 0.7      # Anteil der Buchstaben eines Wortes, die die Zweitmeinung an derselben Stelle hat


def _map_probs(wwords: list[list[Any]], words: list[str]) -> list[float | None]:
    """Whispers Wort-Wahrscheinlichkeiten auf die ausgerichteten Wörter legen: bei gleicher Zahl nach Stelle, sonst über
    die normierte Wortfolge (difflib); nicht zuzuordnende Wörter bekommen den Median des Abschnitts."""
    import difflib
    wp = [w[3] if len(w) > 3 else None for w in wwords]
    if len(wp) == len(words):
        return wp
    out: list[float | None] = [None] * len(words)
    sm = difflib.SequenceMatcher(a=[_norm_word(w[2]) for w in wwords], b=[_norm_word(w) for w in words], autojunk=False)
    for blk in sm.get_matching_blocks():
        for i in range(blk.size):
            out[blk.b + i] = wp[blk.a + i]
    known = sorted(x for x in wp if x is not None)
    med = known[len(known) // 2] if known else None
    return [x if x is not None else med for x in out]


def _second_opinion(om_mod: Any, om: Any, clip: np.ndarray, text: str, wwords: list[list[Any]],
                    offset: float) -> tuple[list[list[Any]], str, float | None]:
    """Whispers Text mit Omnilingual ausrichten (Wortzeiten zum Hinhören) und mit dessen eigenem Hören abgleichen.
    Überarbeitet am 17.11.2026: Auf den Mikrofonen eines Schiffsschreibers war die Ampel fast nur rot. Jetzt
    - ist p Whispers eigene Wort-Wahrscheinlichkeit (FLEURS: unter 0,5 zu 57 % falsch, ab 0,99 zu 3,6 %),
    - gilt Omnilingual als unbrauchbar, wo es ab 20 % fremde Zeichen ausgibt (chinesisch, arabisch …; vorher an 59 % der
      Blöcke): Dort erkennt es die Sprache nicht. Lateinisch erzwingen (latin_only) half nicht: An 30 solchen Stellen
      ähnelte der erzwungene Text Whisper im Median zu 0 % (1 von 30 ab 0,4), an 50 von selbst lateinischen zu 0,39.
      Unbrauchbar zählt deshalb nicht als Widerspruch,
    - wird unscharf verglichen: Buchstaben beider Texte ohne Leerzeichen (difflib); bestätigt ist ein Wort, wenn der
      Abschnitt im Großen gleich klingt (Ähnlichkeit ab SECOND_SIM_MIN) und die Zweitmeinung mindestens WORD_COVER_MIN
      seiner Buchstaben an derselben Stelle hat („makinayan“ = „Makina yan“, „pinatai“ ≈ „pinatay“).
    Ergebnis: Wörter [Anfang, Ende, Wort, p, bestätigt], Text der Zweitmeinung ("" = unbrauchbar), Ähnlichkeit."""
    import difflib
    import re
    aligned = om_mod.align(om, clip, text, {"offset_seconds": offset})
    own = om_mod.transcribe(om, clip, {"offset_seconds": offset})
    foreign = re.compile(r"[^\x00-\u024f\u2019\u2010\u2011\s]")
    raw = " ".join((own.get("text") or "").split())
    chars = [c for c in raw if not c.isspace()]
    usable = bool(chars) and sum(1 for c in chars if foreign.match(c)) / len(chars) < 0.2
    alt = " ".join(foreign.sub("", raw).split()) if usable else ""
    usable = usable and bool(alt)
    if not aligned:
        return [[w[0], w[1], w[2], w[3], 0] for w in wwords], (alt if usable else ""), None
    a_words = [_norm_word(w[2]) for w in aligned]
    a_str = "".join(a_words)
    b_str = "".join(_norm_word(x) for x in alt.split()) if usable else ""
    sim = None
    cover = [0.0] * len(aligned)
    if a_str and b_str:
        sm = difflib.SequenceMatcher(a=a_str, b=b_str, autojunk=False)
        sim = sm.ratio()
        hit = bytearray(len(a_str))
        for blk in sm.get_matching_blocks():
            hit[blk.a:blk.a + blk.size] = b"\x01" * blk.size
        pos = 0
        for k, w in enumerate(a_words):
            cover[k] = sum(hit[pos:pos + len(w)]) / len(w) if w else 0.0
            pos += len(w)
    wp = _map_probs(wwords, [w[2] for w in aligned])
    out = []
    for k, w in enumerate(aligned):
        s0, e0, word = w[0], w[1], w[2]
        p = wp[k] if wp[k] is not None else (w[3] if w[3] is not None else 0.0)
        ok = sim is not None and sim >= SECOND_SIM_MIN and cover[k] >= WORD_COVER_MIN
        out.append([None if s0 is None else round(float(s0), 2), None if e0 is None else round(float(e0), 2), word,
                    round(float(p), 3), 1 if ok else 0])
    return out, (alt if usable else ""), (None if sim is None else round(sim, 3))


def _read16(path: str, start: float, end: float) -> np.ndarray:
    """Abschnitt einer Spur als Mono mit 16 kHz."""
    import soundfile as sf
    info = sf.info(path)
    x, sr = sf.read(path, start=max(0, int(start * info.samplerate)), frames=max(1, int((end - start) * info.samplerate)),
                    dtype="float32", always_2d=True)
    mono = x.mean(axis=1)
    if sr != 16000:
        mono = at._resample(mono.reshape(-1, 1), sr, 16000)[:, 0]
    return mono.astype(np.float32)


def cmd_transcribe(s: dict[str, Any]) -> dict[str, Any]:
    """Spracherkennung der Übersetzer-Spur. s: model, weights_dir, device, tracks [{id, file, act, kind}], region,
    language, allowed, beams, out (JSON-Zeilen je Abschnitt; schon vorhandene werden übersprungen = fortsetzen),
    plan_only. Ergebnis: Anzahl Abschnitte, Sekunden, verworfene."""
    import soundfile as sf
    regions = plan_regions(s["tracks"], s.get("region"))
    total = sum(r["end"] - r["start"] for r in regions)
    if s.get("plan_only"):
        return {"regions": len(regions), "speech_seconds": round(total, 1)}
    # Kennungen der Abschnitte dieses Plans: Der Server übernimmt aus out nur deren Zeilen (die Datei kann Zeilen eines
    # früheren Plans derselben Spuren enthalten, etwa vor Silero; aus dem Tor entstehen „<Kennung>+<Versatz>“)
    plan_ids = [r["id"] for r in regions]
    out_path = Path(s["out"])
    done: set[str] = set()
    if out_path.exists():
        for line in out_path.read_text(encoding="utf-8").splitlines():
            try:
                done.add(json.loads(line)["id"])
            except (ValueError, KeyError):
                pass
    todo = [r for r in regions if r["id"] not in done]
    if not todo:
        progress(1.0, L("fertig", "done"))
        return {"regions": len(regions), "new": 0, "speech_seconds": round(total, 1), "plan_ids": plan_ids}
    # Tor: Silero VAD prüft jeden Abschnitt auf echte Sprache und kürzt ihn auf die Sprachstrecken (Messung 17.11.:
    # ohne Tor erfand Whisper auf Wind und Lärm Sätze wie „Thank you for watching!“)
    rejected: list[dict[str, Any]] = []
    if s.get("vad_dir"):
        vad = at._adapter("silero_vad")
        vm = vad.load(Path(s["vad_dir"]), "cpu", {})
        kept_regions = []
        for k, r in enumerate(todo):
            spans = []
            for tid in [r["track"]] + ([r["second"]] if r.get("second") else []):
                f = next(tr["file"] for tr in s["tracks"] if tr["id"] == tid)
                x = _read16(f, r["start"], r["end"])
                spans = vad.speech_spans(vm, x)
                if spans:
                    if tid != r["track"]:
                        r = {**r, "track": tid, "file": f, "second": r["track"]}
                    break
            if not spans:
                rejected.append({"id": r["id"], "dropped": True, "reason": "vad"})
            else:
                # zusammenhängende Strecken, Lücken über 1,5 s trennen
                groups: list[list[float]] = []
                for a0, b0, pr in spans:
                    if groups and a0 - groups[-1][1] < 1.5:
                        groups[-1][1] = b0
                        groups[-1][2] = max(groups[-1][2], pr)
                    else:
                        groups.append([a0, b0, pr])
                for a0, b0, pr in groups:
                    kept_regions.append({**r, "id": f"{r['id']}+{a0:.1f}", "start": round(r["start"] + a0, 2),
                                         "end": round(r["start"] + b0, 2), "vad": round(pr, 3)})
            if k % 20 == 0:
                progress(0.02 + 0.18 * k / max(1, len(todo)), L(f"Sprache prüfen {k}/{len(todo)}", f"checking speech {k}/{len(todo)}"))
        with out_path.open("a", encoding="utf-8") as fh:
            for rec in rejected:
                fh.write(json.dumps(rec) + "\n")
        todo = [r for r in kept_regions if r["id"] not in done]
    if not todo:
        progress(1.0, L("fertig", "done"))
        return {"regions": len(regions), "new": 0, "rejected_vad": len(rejected), "speech_seconds": round(total, 1),
                "plan_ids": plan_ids}
    progress(0.2, L("Modell laden", "loading the model"))
    adapter = at._adapter(s["model"])
    t0 = time.time()
    device = s.get("device") or "cuda"
    if device == "cuda":
        import torch
        if not torch.cuda.is_available():
            device = "cpu"   # ohne nutzbare Karte (gpu.cpu_mode): Whisper rechnet auf dem Prozessor, in float32
    bundle = adapter.load(Path(s["weights_dir"]), device, {})
    # Zweitmeinung und Wortzeiten mit Omnilingual CTC 1B (Apache-2.0, 2 % der Rechenzeit von Whisper): Whispers Text
    # wird am Ton ausgerichtet, je Wort p = min(Whisper-Token, ausgerichtet), dazu „bestätigt“, wenn Omnilingual selbst
    # dasselbe Wort an derselben Stelle hört (Messung 17.11.: bestätigte Wörter zu 4,3 % falsch, die übrigen fangen
    # 65–69 % aller Whisper-Fehler)
    om_mod = om = None
    if s.get("align_dir"):
        try:
            om_mod = at._adapter("omnilingual_ctc1b")
            om = om_mod.load(Path(s["align_dir"]), device, {})
        except (Exception, SystemExit) as exc:  # noqa: BLE001 - ohne Zweitmeinung weiter (der Baustein meldet per SystemExit)
            emit(warning=L(f"Omnilingual nicht geladen: {exc}", f"Omnilingual not loaded: {exc}"))
            om_mod = om = None
    load_s = time.time() - t0
    params = {"language": s.get("language") or "auto", "allowed": s.get("allowed") or [], "beams": int(s.get("beams") or 5)}
    batch = int(s.get("batch") or 8)
    kept = dropped = 0
    t1 = time.time()
    with out_path.open("a", encoding="utf-8") as fh:
        for i in range(0, len(todo), batch):
            part = todo[i:i + batch]
            clips = [_read16(r["file"], r["start"], r["end"])[: int(adapter.MAX_SECONDS * 16000)] for r in part]
            res = adapter.transcribe(bundle, clips, params)
            for r, x, clip in zip(part, res, clips):
                lp = x.get("logprob")
                flags = []
                # OpenAI-Regel: „keine Sprache“, wenn der Anfang danach aussieht und das Ergebnis unsicher ist
                silent = (x.get("no_speech") or 0) > 0.6 and (lp is None or lp < -1.0)
                looped = _cut_loops(x)
                if looped or (x.get("compression") or 0) > 2.4 or x.get("hit_limit"):
                    flags.append("repetition")
                if lp is not None and lp < -1.0:
                    flags.append("low_confidence")
                if not x.get("text") or silent or _hallucination(x.get("text") or ""):
                    dropped += 1
                    rec = {"id": r["id"], "dropped": True, "no_speech": x.get("no_speech"), "logprob": lp,
                           "reason": "hallucination" if x.get("text") and _hallucination(x["text"]) else "no_speech"}
                else:
                    kept += 1
                    words = [[None if w[0] is None else round(r["start"] + w[0], 2), None if w[1] is None else round(r["start"] + w[1], 2),
                              w[2], w[3]] for w in x.get("words") or []]
                    alt = None
                    sim = None
                    if om is not None:
                        try:
                            words, alt, sim = _second_opinion(om_mod, om, clip, x["text"], words, r["start"])
                        except (Exception, SystemExit) as exc:  # noqa: BLE001 - Wörter ohne Zweitmeinung behalten
                            emit(warning=L(f"Zweitmeinung fehlgeschlagen: {exc}", f"Second opinion failed: {exc}"))
                        # Keine Vermerke aus der Zweitmeinung mehr (Nutzer 18.11.2026: „second_unusable oder disputed fast
                        # immer, was bringt es“): Im Schreiber-Fall war sie bei 52 % von 3290 Blöcken unbrauchbar und
                        # widersprach bei weiteren 32 %, ihre Ähnlichkeit zu Whisper war über 0–1 gleich verteilt. Sie
                        # bleibt als alt_text/second_sim am Block, und Bestätigungen zählen für die grüne Wortampel.
                    rec = {"id": r["id"], "start": r["start"], "end": r["end"], "track": r["track"], "second": r.get("second"),
                           "kind": r["kind"], "text": x["text"], "lang": x.get("lang"), "lang_probs": x.get("lang_probs"),
                           "conf": None if lp is None else round(math.exp(lp), 3), "logprob": lp, "no_speech": x.get("no_speech"),
                           "compression": x.get("compression"), "flags": flags, "words": words, "alt_text": alt,
                           "second_sim": sim}
                fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
            fh.flush()
            progress(0.2 + 0.8 * (i + len(part)) / len(todo), L(f"Sprache erkennen {i + len(part)}/{len(todo)}",
                                                                  f"recognising speech {i + len(part)}/{len(todo)}"))
    rt = time.time() - t1
    secs = sum(r["end"] - r["start"] for r in todo)
    return {"regions": len(regions), "new": len(todo), "kept": kept, "dropped": dropped, "rejected_vad": len(rejected),
            "speech_seconds": round(total, 1),
            "load_seconds": round(load_s, 1), "asr_seconds": round(rt, 1), "rtf": round(rt / max(1.0, secs), 4),
            "plan_ids": plan_ids}


COMMANDS: dict[str, Callable[[dict[str, Any]], dict[str, Any]]] = {"spectro": cmd_spectro, "vad": cmd_vad,
                                                                    "automix": cmd_automix, "transcribe": cmd_transcribe,
                                                                    "vadmap": cmd_vadmap, "align": cmd_align, "videoexport": cmd_videoexport,
                                                                    "clockalign": cmd_clockalign, "render": cmd_render}


def main() -> None:
    cmd = sys.argv[1]
    settings = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8")) if len(sys.argv) > 2 else {}
    at.set_lang(settings.get("lang"))
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
