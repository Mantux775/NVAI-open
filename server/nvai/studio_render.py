"""Studio-Export (studio.render_plan → MP4). Läuft im ComfyUI-venv wie video_tools.py: PyAV 18 bringt NVENC,
AMF und QSV mit (gemessen 26.10.2026 auf der RTX 5060 Ti: h264/hevc/av1_nvenc 1080p mit 84–97 fps), NumPy und SciPy
für Bild und Ton. Ausgabe: JSON-Zeilen mit Fortschritt, zuletzt {"done": true, …}.

    python studio_render.py <plan.json> <ziel> [<vorschau.mp4>]

Wie bei FilmCraft ist der Hardware-Encoder ein Angebot mit geprüftem Rückfall: Er wird an einem Probebild geöffnet;
klappt das nicht (keine NVIDIA-, AMD- oder Intel-Grafik, alter Treiber), kodiert die Software (libx264/x265/SVT-AV1).
Zum Weiterverarbeiten ohne Qualitätsverlust: FFV1 in MKV (verlustfrei, Ton als Float-PCM) und ProRes 4444 in MOV
(Ton 24 Bit). Gelesen wird aus den verlustfreien Mastern der erzeugten Videos (studio.render_plan), so komprimiert
nur der Export selbst.

Einpassen: Weicht das Seitenverhältnis höchstens 5 % ab, füllt das Bild den Rahmen und der Rand wird abgeschnitten
(LTX-2.5 rechnet 1080p als 1920 × 1088: 8 Zeilen weg statt das ganze Bild um 0,7 % zu verkleinern und
schwarze Ränder); sonst passt es mit schwarzen Rändern hinein.

Bild: V1 unten, V2, V3 … darüber (deckend, ins Format eingepasst); ausgeblendete Spuren fehlen im Plan. Ein Übergang
am Anfang eines Clips mischt ihn mit dem vorherigen Clip derselben Spur (ohne den mit dem Bild darunter bzw. Schwarz);
der vorige läuft dafür über sein Ende hinaus weiter, so weit sein Material reicht, sonst steht sein letztes Bild.
Arten: Überblendung, Abblende über Schwarz bzw. Weiß (erste Hälfte ab-, zweite aufblenden), Wischblende von links mit
weicher Kante. Geschwindigkeit: Medienzeit = In + Zeit im Clip × Geschwindigkeit (Bilder werden wiederholt oder
übersprungen), der Ton wird mit atempo gedehnt und behält seine Tonhöhe wie die Vorschau im Browser.
Ton: alle Clips mit Ton (auch die Tonspur der Videos), Lautstärke je Clip, Übergänge als Ein- und Ausblenden; danach
integrierte Lautheit nach ITU-R BS.1770 auf −14 LUFS und der Limiter von NVAI-open (comfy_nodes/nvai_audio.py) auf
−2,5 dBFS, weil AAC bis knapp 2 dB überschwingt (gemessen 24.10.).
"""
from __future__ import annotations

import io
import json
import sys
import time
from fractions import Fraction
from pathlib import Path
from typing import Any

import av
import numpy as np
from PIL import Image
from scipy.signal import lfilter

sys.path.insert(0, str(Path(__file__).resolve().parent / "comfy_nodes"))
import nvai_audio  # noqa: E402  (Limiter, gleiche Kurve wie beim Erzeugen)

ENCODERS = {
    "h264": ["h264_nvenc", "h264_amf", "h264_qsv", "libx264"],
    "hevc": ["hevc_nvenc", "hevc_amf", "hevc_qsv", "libx265"],
    "av1": ["av1_nvenc", "av1_amf", "av1_qsv", "libsvtav1"],
    "ffv1": ["ffv1"],
    "prores": ["prores_ks"],
}
# Abweichend von MP4 mit 4:2:0 und AAC
PIX_FMT = {"ffv1": "bgr0", "prores": "yuv444p10le"}
CONTAINER = {"ffv1": "matroska", "prores": "mov"}
AUDIO_CODEC = {"ffv1": "pcm_f32le", "prores": "pcm_s24le"}
COVER_TOLERANCE = 0.05
PREVIEW_BITRATE = 8_000_000  # H.264-Vorschau neben MKV/ProRes, nur zum Ansehen im Browser
TIME_SLACK = 0.001  # s; kürzer als jedes Bild (120 fps: 8,3 ms)


def emit(**msg: Any) -> None:
    print(json.dumps(msg), flush=True)


# --------------------------------------------------------------------------------------------- Encoder

def _encoder_options(name: str, bitrate: int | None) -> dict[str, str]:
    if name == "ffv1":
        return {"level": "3", "slices": "16", "slicecrc": "1", "g": "1"}
    if name == "prores_ks":
        return {"profile": "4", "vendor": "apl0"}  # 4444
    if name.endswith("_nvenc"):
        opts = {"preset": "p5", "tune": "hq", "rc": "vbr"}
    elif name.endswith("_amf"):
        opts = {"quality": "quality", "rc": "vbr_peak"}
    elif name.endswith("_qsv"):
        opts = {"preset": "slow"}
    elif name == "libsvtav1":
        opts = {"preset": "8"}
    else:
        opts = {"preset": "medium"}
    if not bitrate and name in ("libx264", "libx265"):
        opts["crf"] = "18"
    return opts


def pick_encoder(codec: str, width: int, height: int, fps: Fraction, bitrate: int | None) -> str:
    """Erster Encoder, der ein Probebild in dieser Größe kodiert."""
    tried = []
    for name in ENCODERS[codec]:
        if name not in av.codecs_available:
            continue
        try:
            with av.open(io.BytesIO(), "w", format=CONTAINER.get(codec, "mp4")) as probe:
                s = probe.add_stream(name, rate=fps)
                s.width, s.height, s.pix_fmt = width, height, PIX_FMT.get(codec, "yuv420p")
                if bitrate:
                    s.bit_rate = bitrate
                s.options = _encoder_options(name, bitrate)
                frame = av.VideoFrame.from_ndarray(np.zeros((height, width, 3), np.uint8), format="rgb24")
                for pkt in s.encode(frame):
                    probe.mux(pkt)
                for pkt in s.encode():
                    probe.mux(pkt)
            return name
        except Exception as exc:  # noqa: BLE001 - nächster Encoder
            tried.append(f"{name}: {str(exc)[:80]}")
    raise SystemExit("Kein Encoder für " + codec + " verfügbar: " + "; ".join(tried))


# -------------------------------------------------------------------------------------------- Bilder

def target_size(w: int, h: int, width: int, height: int) -> tuple[int, int]:
    """Größe, auf die ein Bild für das Ausgabeformat skaliert wird: füllend bei fast gleichem Seitenverhältnis,
    sonst einpassend (siehe Moduldoku)."""
    cover = abs((w / h) / (width / height) - 1.0) <= COVER_TOLERANCE
    scale = (max if cover else min)(width / w, height / h)
    return max(2, int(round(w * scale))), max(2, int(round(h * scale)))


def fit(img: np.ndarray, width: int, height: int) -> np.ndarray:
    """Ins Ausgabeformat bringen: skalieren (Lanczos), mittig abschneiden oder mit schwarzen Rändern auffüllen."""
    h, w = img.shape[:2]
    if (w, h) == (width, height):
        return img
    nw, nh = target_size(w, h, width, height)
    if (nw, nh) != (w, h):
        img = np.asarray(Image.fromarray(img).resize((nw, nh), Image.LANCZOS))
    canvas = np.zeros((height, width, 3), np.uint8)
    x, y = (width - nw) // 2, (height - nh) // 2
    sx, sy, dx, dy = max(0, -x), max(0, -y), max(0, x), max(0, y)
    cw, ch = min(nw - sx, width - dx), min(nh - sy, height - dy)
    canvas[dy:dy + ch, dx:dx + cw] = img[sy:sy + ch, sx:sx + cw]
    return canvas


class VideoSource:
    """Liest ein Video vorwärts und liefert zu einer Medienzeit das zuletzt fällige Bild, schon eingepasst."""

    def __init__(self, path: str, width: int, height: int) -> None:
        self.c = av.open(path)
        self.s = self.c.streams.video[0]
        self.s.thread_type = "AUTO"
        self.width, self.height = width, height
        self.frames = None
        self.current: np.ndarray | None = None
        self.current_t = -1.0
        self.next_frame = None
        self.position = None

    def _start(self, t: float) -> None:
        ts = int(max(0.0, t - 0.5) / float(self.s.time_base))
        self.c.seek(ts, stream=self.s, backward=True, any_frame=False)
        self.frames = self.c.decode(self.s)
        self.next_frame = None
        self.current = None
        self.position = t

    def _convert(self, frame: av.VideoFrame) -> np.ndarray:
        nw, nh = target_size(frame.width, frame.height, self.width, self.height)
        if (nw, nh) == (frame.width, frame.height):
            img = frame.to_ndarray(format="rgb24")  # nur abschneiden, kein Neuabtasten
        else:
            # Bicubic: gemessen 10,6 statt 71,8 ms je Bild (Lanczos), Unterschied 55 dB PSNR, also unsichtbar
            img = frame.reformat(width=nw, height=nh, format="rgb24", interpolation="BICUBIC").to_ndarray()
        return fit(img, self.width, self.height)

    def frame_at(self, t: float) -> np.ndarray | None:
        if self.frames is None or self.position is None or t < self.position - 1e-6 or t > self.position + 2.0:
            self._start(t)
        self.position = t
        raw = None  # erst das fällige Bild wird umgerechnet, nicht jedes übersprungene
        while True:
            if self.next_frame is None:
                try:
                    self.next_frame = next(self.frames)
                except StopIteration:
                    break  # Ende des Materials: letztes Bild steht
            ft = float(self.next_frame.pts * self.s.time_base) if self.next_frame.pts is not None else 0.0
            # MKV zählt in Millisekunden: Bild 1 bei 24 fps steht auf 42 statt 41,67 ms. Ohne Spielraum kam gemessen
            # jedes dritte Bild aus dem Master eins zu spät.
            if ft <= t + TIME_SLACK:
                raw, self.current_t = self.next_frame, ft
                self.next_frame = None
                continue
            if raw is None and self.current is None:  # erstes Bild liegt hinter t
                raw, self.current_t = self.next_frame, ft
            break
        if raw is not None:
            self.current = self._convert(raw)
        return self.current

    def close(self) -> None:
        self.c.close()


class ImageSource:
    def __init__(self, path: str, width: int, height: int) -> None:
        self.img = fit(np.asarray(Image.open(path).convert("RGB")), width, height)

    def frame_at(self, t: float) -> np.ndarray:
        return self.img

    def close(self) -> None:
        pass


# ---------------------------------------------------------------------------------------------- Ton

def read_audio(path: str, start: float, end: float, rate: int) -> np.ndarray:
    """Ton von start bis end (Medienzeit) als float32 [2, n], neu abgetastet."""
    n = max(0, int(round((end - start) * rate)))
    out = np.zeros((2, n), np.float32)
    if n == 0:
        return out
    with av.open(path) as c:
        if not c.streams.audio:
            return out
        s = c.streams.audio[0]
        c.seek(int(max(0.0, start - 0.5) / float(s.time_base)), stream=s, backward=True)
        resampler = av.AudioResampler(format="fltp", layout="stereo", rate=rate)
        chunks, first = [], None
        for frame in c.decode(s):
            for rf in resampler.resample(frame):
                if rf.pts is None:
                    continue
                if first is None:
                    first = float(rf.pts * rf.time_base)
                chunks.append(rf.to_ndarray())
            if chunks and first is not None and first + sum(ch.shape[1] for ch in chunks) / rate > end + 0.1:
                break
        if not chunks:
            return out
        data = np.concatenate(chunks, axis=1)
        if data.shape[0] == 1:
            data = np.repeat(data, 2, axis=0)
        offset = int(round((start - first) * rate))
        if offset < 0:  # Material beginnt später: vorne Stille
            data = np.pad(data, ((0, 0), (-offset, 0)))
            offset = 0
        piece = data[:, offset:offset + n]
        out[:, :piece.shape[1]] = piece
    return out


def stretch(audio: np.ndarray, speed: float, rate: int, length: int) -> np.ndarray:
    """Ton auf `length` Proben bringen, die Tonhöhe bleibt (atempo; je Stufe 0,5 bis 2, deshalb verkettet).
    Gemessen 27.10. mit 440 Hz: 10 bis 1000 % treffen die Tonhöhe genau, die Länge auf etwa 2 %, der Rest wird
    aufgefüllt bzw. abgeschnitten."""
    if abs(speed - 1.0) < 1e-6 or audio.shape[1] == 0:
        out = audio
    else:
        graph = av.filter.Graph()
        src = graph.add_abuffer(format="fltp", sample_rate=rate, layout="stereo", time_base=Fraction(1, rate))
        steps, rest = [], speed
        while rest < 0.5:
            steps.append(0.5)
            rest /= 0.5
        while rest > 2.0:
            steps.append(2.0)
            rest /= 2.0
        steps.append(rest)
        nodes = ([src] + [graph.add("atempo", f"{s:.6f}") for s in steps]
                 + [graph.add("aformat", "sample_fmts=fltp:channel_layouts=stereo"), graph.add("abuffersink")])
        for a, b in zip(nodes, nodes[1:]):
            a.link_to(b)
        graph.configure()
        frame = av.AudioFrame.from_ndarray(np.ascontiguousarray(audio, dtype=np.float32), format="fltp",
                                           layout="stereo")
        frame.sample_rate, frame.pts, frame.time_base = rate, 0, Fraction(1, rate)
        graph.push(frame)
        graph.push(None)
        parts = []
        while True:
            try:
                parts.append(graph.pull().to_ndarray())
            except (av.BlockingIOError, av.EOFError):
                break
        out = np.concatenate(parts, axis=1) if parts else np.zeros((2, 0), np.float32)
    if out.shape[1] >= length:
        return out[:, :length]
    return np.pad(out, ((0, 0), (0, length - out.shape[1])))


def loudness(x: np.ndarray, rate: int) -> float:
    """Integrierte Lautheit nach ITU-R BS.1770-4 (K-Filter, 400-ms-Blöcke, Gates −70 LUFS und −10 LU)."""
    if rate != 48000:
        raise ValueError("K-Filter-Koeffizienten gelten für 48 kHz")
    y = lfilter([1.53512485958697, -2.69169618940638, 1.19839281085285],
                [1.0, -1.69065929318241, 0.73248077421585], x, axis=1)
    y = lfilter([1.0, -2.0, 1.0], [1.0, -1.99004745483398, 0.99007225036621], y, axis=1)
    block, step = int(0.4 * rate), int(0.1 * rate)
    if y.shape[1] < block:
        return -70.0
    sq = np.cumsum(np.pad(y.astype(np.float64) ** 2, ((0, 0), (1, 0))), axis=1)
    starts = np.arange(0, y.shape[1] - block + 1, step)
    z = (sq[:, starts + block] - sq[:, starts]) / block  # [Kanäle, Blöcke]
    power = z.sum(axis=0)
    lk = -0.691 + 10 * np.log10(np.maximum(power, 1e-12))
    gated = power[lk > -70.0]
    if gated.size == 0:
        return -70.0
    relative = -0.691 + 10 * np.log10(gated.mean()) - 10.0
    final = power[(lk > -70.0) & (lk > relative)]
    return float(-0.691 + 10 * np.log10(final.mean())) if final.size else -70.0


def speed_of(c: dict[str, Any]) -> float:
    return float(c.get("speed") or 1.0)


def length_of(c: dict[str, Any]) -> float:
    """Länge auf der Zeitleiste in Sekunden: Material durch die Geschwindigkeit."""
    return (c["out"] - c["in"]) / speed_of(c)


def mix_audio(plan: dict[str, Any], rate: int) -> np.ndarray:
    total = int(np.ceil(plan["duration"] * rate)) + 1
    mix = np.zeros((2, total), np.float32)
    clips = [c for c in plan["clips"] if not c["muted"] and (c["media"] == "audio" or c["audio"])]
    for c in clips:
        n_len = int(round(length_of(c) * rate))
        audio = stretch(read_audio(c["path"], c["in"], c["out"], rate), speed_of(c), rate, n_len)
        audio *= np.float32(10 ** (c["gain_db"] / 20))
        tr = c.get("transition")
        if tr and tr["seconds"] > 0:  # einblenden
            n = min(audio.shape[1], int(tr["seconds"] * rate))
            audio[:, :n] *= np.linspace(0.0, 1.0, n, dtype=np.float32)
            # der vorherige Clip derselben Spur läuft über sein Ende hinaus aus
            prev = _previous(plan, c)
            if prev is not None and (prev["media"] == "audio" or prev["audio"]) and not prev["muted"]:
                k = speed_of(prev)
                tail = stretch(read_audio(prev["path"], prev["out"], prev["out"] + tr["seconds"] * k, rate), k, rate,
                               int(round(tr["seconds"] * rate)))
                tail *= np.float32(10 ** (prev["gain_db"] / 20)) * np.linspace(1.0, 0.0, tail.shape[1], dtype=np.float32)
                _add(mix, tail, int(round(c["start"] * rate)))
        _add(mix, audio, int(round(c["start"] * rate)))
    return mix


def _add(mix: np.ndarray, part: np.ndarray, at: int) -> None:
    end = min(mix.shape[1], at + part.shape[1])
    if end > at >= 0:
        mix[:, at:end] += part[:, :end - at]


def _previous(plan: dict[str, Any], clip: dict[str, Any]) -> dict[str, Any] | None:
    before = [c for c in plan["clips"] if c["track"] == clip["track"] and c is not clip
              and abs((c["start"] + length_of(c)) - clip["start"]) < 1e-3]
    return before[0] if before else None


WIPE_EDGE = 0.04  # weiche Kante der Wischblende, Anteil der Bildbreite


def blend(base: np.ndarray, img: np.ndarray, a: float, kind: str) -> np.ndarray:
    """Übergang bei Fortschritt a (0 → 1) von `base` (voriger Clip, Bild darunter oder Schwarz) zu `img`."""
    b, i = base.astype(np.float32), img.astype(np.float32)
    if kind in ("dip_black", "dip_white"):
        color = np.float32(0.0 if kind == "dip_black" else 255.0)
        out = b + (color - b) * (2 * a) if a < 0.5 else color + (i - color) * (2 * a - 1)
    elif kind == "wipe":
        width = img.shape[1]
        x = np.arange(width, dtype=np.float32) / width
        mask = np.clip((a * (1 + WIPE_EDGE) - x) / WIPE_EDGE, 0.0, 1.0)[None, :, None]
        out = b * (1 - mask) + i * mask
    else:
        out = b * (1 - a) + i * a
    return np.clip(out + 0.5, 0, 255).astype(np.uint8)


# --------------------------------------------------------------------------------------------- Ablauf

def render(plan: dict[str, Any], out_path: str, preview_path: str | None = None) -> dict[str, Any]:
    width, height = int(plan["width"]) // 2 * 2, int(plan["height"]) // 2 * 2
    fps = Fraction(int(plan["fps"][0]), int(plan["fps"][1]))
    rate = int(plan.get("sample_rate", 48000))
    duration = float(plan["duration"])
    n_frames = max(1, int(np.ceil(duration * fps - 1e-9)))
    t0 = time.time()

    emit(progress=0.0, stage="Ton mischen")
    audio = mix_audio(plan, rate)
    measured = loudness(audio, rate)
    gain_db = 0.0
    if measured > -70.0:
        gain_db = float(plan.get("loudness", -14.0)) - measured
        audio *= np.float32(10 ** (gain_db / 20))
    audio *= nvai_audio.gain_curve(audio, rate, ceiling_db=float(plan.get("ceiling_db", -2.5)))
    peak = float(20 * np.log10(max(1e-9, float(np.abs(audio).max()))))

    encoder = pick_encoder(plan["codec"], width, height, fps, plan.get("bitrate"))
    emit(progress=0.02, stage=f"Video mit {encoder}")
    video_tracks = [tr for tr in reversed(plan["tracks"]) if tr.startswith("V")]  # V1 unten, V2 oben
    sources: dict[int, Any] = {}

    def source(i: int) -> Any:
        if i not in sources:
            c = plan["clips"][i]
            sources[i] = (ImageSource if c["media"] == "image" else VideoSource)(c["path"], width, height)
        return sources[i]

    def active(track: str, t: float) -> int | None:
        for i, c in enumerate(plan["clips"]):
            if c["track"] == track and c["start"] <= t < c["start"] + length_of(c) - 1e-9:
                return i
        return None

    sinks = [Sink(out_path, plan["codec"], encoder, width, height, fps, rate, plan.get("bitrate"))]
    if preview_path:
        # Vorschau für den Browser (FFV1 und ProRes spielt keiner ab): dieselben Bilder, nur H.264
        pe = pick_encoder("h264", width, height, fps, PREVIEW_BITRATE)
        sinks.append(Sink(preview_path, "h264", pe, width, height, fps, rate, PREVIEW_BITRATE))

    black = np.zeros((height, width, 3), np.uint8)
    for f in range(n_frames):
        t = f / float(fps)
        canvas = None
        for track in video_tracks:
            i = active(track, t)
            if i is None:
                continue
            c = plan["clips"][i]
            local = t - c["start"]
            img = source(i).frame_at(c["in"] + local * speed_of(c))
            if img is None:
                continue
            tr = c.get("transition")
            if tr and tr["seconds"] > 0 and local < tr["seconds"]:
                prev = _previous(plan, c)
                if prev is not None:
                    j = plan["clips"].index(prev)
                    before = source(j).frame_at(prev["out"] + local * speed_of(prev))
                    base = before if before is not None else (canvas if canvas is not None else black)
                else:
                    base = canvas if canvas is not None else black
                img = blend(base, img, local / tr["seconds"], tr.get("kind", "dissolve"))
            canvas = img
        for sink in sinks:
            sink.video(canvas if canvas is not None else black, f)
            sink.mux_audio(audio, int((f + 1) / float(fps) * rate))
        if f % 12 == 0:
            emit(progress=round(0.02 + 0.96 * (f + 1) / n_frames, 4), stage=f"Video mit {encoder}",
                 frame=f + 1, frames=n_frames)
    for sink in sinks:
        sink.finish(audio)
    for s in sources.values():
        s.close()
    took = time.time() - t0
    return {"done": True, "encoder": encoder, "seconds": round(duration, 3), "width": width, "height": height,
            "fps": [fps.numerator, fps.denominator], "frames": n_frames, "render_seconds": round(took, 1),
            "loudness_before": round(measured, 1), "gain_db": round(gain_db, 1), "peak_dbfs": round(peak, 2),
            "preview": bool(preview_path)}


class Sink:
    """Eine Ausgabedatei: Video-Encoder, Ton (AAC oder PCM) und Muxer. Der Ton geht blockweise hinter den Bildern
    her, damit die Datei verzahnt ist."""

    AAC_FRAME = 1024

    def __init__(self, path: str, codec: str, encoder: str, width: int, height: int, fps: Fraction, rate: int,
                 bitrate: int | None) -> None:
        container = CONTAINER.get(codec, "mp4")
        self.acodec = AUDIO_CODEC.get(codec, "aac")
        self.dst = av.open(path, "w", format=container,
                           options={"movflags": "+faststart"} if container in ("mp4", "mov") else {})
        self.vs = self.dst.add_stream(encoder, rate=fps)
        self.vs.width, self.vs.height, self.vs.pix_fmt = width, height, PIX_FMT.get(codec, "yuv420p")
        if bitrate:
            self.vs.bit_rate = int(bitrate)
        self.vs.options = _encoder_options(encoder, bitrate)
        self.as_ = self.dst.add_stream(self.acodec, rate=rate)
        self.as_.layout = "stereo"
        if self.acodec == "aac":
            self.as_.bit_rate = 192_000
        self.fps, self.rate, self.audio_pos = fps, rate, 0

    def _audio_frame(self, chunk: np.ndarray) -> av.AudioFrame:
        if self.acodec == "aac":
            frame = av.AudioFrame.from_ndarray(np.ascontiguousarray(chunk), format="fltp", layout="stereo")
        elif self.acodec == "pcm_f32le":
            packed = np.ascontiguousarray(chunk.T.reshape(1, -1), dtype=np.float32)
            frame = av.AudioFrame.from_ndarray(packed, format="flt", layout="stereo")
        else:  # pcm_s24le: 24 Bit, geliefert als 32-Bit-Proben
            packed = np.clip(np.round(chunk.T.reshape(1, -1).astype(np.float64) * 2147483647.0),
                             -2147483648, 2147483647).astype(np.int32)
            frame = av.AudioFrame.from_ndarray(packed, format="s32", layout="stereo")
        frame.sample_rate = self.rate
        return frame

    def mux_audio(self, audio: np.ndarray, until_sample: int, final: bool = False) -> None:
        end = min(until_sample, audio.shape[1])
        while self.audio_pos < end:
            n = min(self.AAC_FRAME, end - self.audio_pos)
            if n < self.AAC_FRAME and not final:
                break
            frame = self._audio_frame(audio[:, self.audio_pos:self.audio_pos + n])
            frame.pts = self.audio_pos
            frame.time_base = Fraction(1, self.rate)
            for pkt in self.as_.encode(frame):
                self.dst.mux(pkt)
            self.audio_pos += n

    def video(self, rgb: np.ndarray, index: int) -> None:
        frame = av.VideoFrame.from_ndarray(rgb, format="rgb24")
        frame.pts = index
        frame.time_base = 1 / self.fps
        for pkt in self.vs.encode(frame):
            self.dst.mux(pkt)

    def finish(self, audio: np.ndarray) -> None:
        for pkt in self.vs.encode():
            self.dst.mux(pkt)
        # Rest des Tons; AAC braucht volle Blöcke, PCM nicht
        rest = audio.shape[1] - self.audio_pos
        if rest > 0 and self.acodec == "aac":
            audio = np.pad(audio, ((0, 0), (0, (-rest) % self.AAC_FRAME)))
        self.mux_audio(audio, audio.shape[1], final=True)
        for pkt in self.as_.encode():
            self.dst.mux(pkt)
        self.dst.close()


def main(argv: list[str]) -> None:
    if len(argv) not in (2, 3):
        raise SystemExit(__doc__)
    plan = json.loads(Path(argv[0]).read_text(encoding="utf-8"))
    emit(**render(plan, argv[1], argv[2] if len(argv) == 3 else None))


if __name__ == "__main__":
    main(sys.argv[1:])
