"""Videowerkzeuge für „Video verlängern“ (seit 0.5.10), laufen im ComfyUI-venv (PyAV, Pillow) wie
outpaint_align.py: den letzten Frame herauslösen und zwei Clips samt Ton aneinanderhängen. Gestreamt Bild
für Bild, damit auch lange 1080p-Videos keinen zweistelligen Gigabyte-Bedarf an Arbeitsspeicher haben.
Kein ffmpeg-Programm nötig; PyAV bringt ComfyUI für SaveVideo ohnehin mit. Ausgabe: eine JSON-Zeile.

    python video_tools.py info <video>
    python video_tools.py probe <datei>            (Video oder reiner Ton, fürs Studio)
    python video_tools.py last-frame <video> <bild.png>
    python video_tools.py concat <erster.mp4> <zweiter.mp4> <ziel.mp4> <crf> [<frames_ueberspringen>]
    python video_tools.py concat-master <erster.mkv> <zweiter.mkv> <ziel.mkv> [<frames_ueberspringen>]
    python video_tools.py last-frames <video> <ziel.mp4> <anzahl>   (die letzten Bilder verlustfrei, seit 0.5.17)
    python video_tools.py concat-xfade <erster> <zweiter> <ziel.mp4> <crf> <bilder>
    python video_tools.py concat-xfade-master <erster.mkv> <zweiter.mkv> <ziel.mkv> <bilder>
    python video_tools.py preview <video> <vorschau.mp4>   (H.264 für den Browser, höchstens 1920 breit)

Beim Anhängen fällt der erste Frame des zweiten Clips weg (er ist der letzte des ersten, das Startbild), samt
dem Ton dieser Bilddauer, damit Bild und Ton synchron bleiben. Kodiert wird wie SaveVideo: H.264, CRF, AAC;
concat-master hängt die verlustfreien Master (FFV1/MKV, comfy_nodes/nvai_video.py) genauso verlustfrei aneinander.

Latent-Kette (seit 0.5.17): Der zweite Clip beginnt mit den letzten <bilder> Bildern des ersten (fest übernommen,
last-frames liefert sie). concat-xfade blendet diese Überlappung linear über, der Ton wechselt mit 40 ms gleich lauter
Überblendung (cos/sin) an der Stelle, an der der zweite Clip neue Bilder zeigt; Bild und Ton bleiben gleich lang.
"""
from __future__ import annotations

import json
import sys
from fractions import Fraction
from pathlib import Path
from typing import Any

import av
import numpy as np


def info(path: str) -> dict[str, Any]:
    with av.open(path) as c:
        v = c.streams.video[0]
        fps = float(v.average_rate or v.guessed_rate or 24)
        seconds = float(c.duration / av.time_base) if c.duration else None
        return {"width": v.codec_context.width, "height": v.codec_context.height, "fps": round(fps, 3),
                "frames": int(v.frames or 0), "seconds": round(seconds, 3) if seconds else None,
                "audio": bool(c.streams.audio)}


def probe(path: str) -> dict[str, Any]:
    """Wie info, aber auch für reine Tondateien (Musik, Klänge im Studio): Dauer, Bild- und Tonspur."""
    with av.open(path) as c:
        seconds = float(c.duration / av.time_base) if c.duration else None
        out: dict[str, Any] = {"seconds": round(seconds, 4) if seconds else None, "video": bool(c.streams.video),
                               "audio": bool(c.streams.audio)}
        if c.streams.video:
            v = c.streams.video[0]
            rate = v.average_rate or v.guessed_rate or Fraction(24)
            out.update(width=v.codec_context.width, height=v.codec_context.height,
                       fps=[int(Fraction(rate).limit_denominator(1001).numerator),
                            int(Fraction(rate).limit_denominator(1001).denominator)],
                       frames=int(v.frames or 0))
        if c.streams.audio:
            out["sample_rate"] = c.streams.audio[0].codec_context.sample_rate
        return out


def last_frame(path: str, out: str) -> dict[str, Any]:
    n = 0
    with av.open(path) as c:
        last = None
        for frame in c.decode(video=0):
            last = frame
            n += 1
        if last is None:
            raise SystemExit("Video ohne Bild")
        last.to_image().save(out)
        return {"frames": n, "width": last.width, "height": last.height}


def concat(first: str, second: str, out: str, crf: float, skip: int = 1) -> dict[str, Any]:
    a, b = info(first), info(second)
    fps = Fraction(a["fps"]).limit_denominator(1001)
    width, height = a["width"], a["height"]
    with_audio = a["audio"] and b["audio"]
    vcount = acount = 0
    with av.open(out, "w", options={"movflags": "+faststart"}) as dst:
        vs = dst.add_stream("libx264", rate=fps)
        vs.width, vs.height, vs.pix_fmt = width, height, "yuv420p"
        vs.options = {"crf": f"{crf:g}", "preset": "medium"}
        rate = 0
        if with_audio:
            with av.open(first) as c:
                rate = c.streams.audio[0].codec_context.sample_rate or 48000
            ast = dst.add_stream("aac", rate=rate, layout="stereo")
            resampler = av.AudioResampler(format="fltp", layout="stereo", rate=rate)

        def put_audio(frames: list[av.AudioFrame]) -> None:
            nonlocal acount
            for af in frames:
                af.pts = acount
                af.time_base = Fraction(1, rate)
                acount += af.samples
                for packet in ast.encode(af):
                    dst.mux(packet)

        for idx, src in enumerate((first, second)):
            drop_frames = skip if idx == 1 else 0
            drop_samples = int(round(rate * drop_frames / float(fps))) if with_audio else 0
            with av.open(src) as c:
                streams = [c.streams.video[0]] + ([c.streams.audio[0]] if with_audio else [])
                for packet in c.demux(*streams):
                    for frame in packet.decode():
                        if isinstance(frame, av.VideoFrame):
                            if drop_frames:
                                drop_frames -= 1
                                continue
                            if frame.width != width or frame.height != height or frame.format.name != "yuv420p":
                                frame = frame.reformat(width=width, height=height, format="yuv420p")
                            frame.pts = vcount
                            frame.time_base = 1 / fps
                            vcount += 1
                            for p in vs.encode(frame):
                                dst.mux(p)
                        elif with_audio:
                            out_frames = resampler.resample(frame)
                            if drop_samples:
                                kept = []
                                for af in out_frames:
                                    if drop_samples >= af.samples:
                                        drop_samples -= af.samples
                                        continue
                                    if drop_samples:
                                        arr = af.to_ndarray()[:, drop_samples:]
                                        af = av.AudioFrame.from_ndarray(np.ascontiguousarray(arr), format="fltp",
                                                                        layout="stereo")
                                        af.sample_rate = rate
                                        drop_samples = 0
                                    kept.append(af)
                                out_frames = kept
                            put_audio(out_frames)
        for p in vs.encode(None):
            dst.mux(p)
        if with_audio:
            put_audio(resampler.resample(None))
            for p in ast.encode(None):
                dst.mux(p)
    return {"frames": vcount, "fps": float(fps), "seconds": round(vcount / float(fps), 3),
            "width": width, "height": height, "audio": with_audio, "skipped": skip}


def concat_master(first: str, second: str, out: str, skip: int = 1) -> dict[str, Any]:
    """Wie concat, aber verlustfrei: zwei Master zu einem neuen Master, Ton als Float-PCM."""
    sys.path.insert(0, str(Path(__file__).resolve().parent / "comfy_nodes"))
    import nvai_video

    a, b = info(first), info(second)
    fps = Fraction(a["fps"]).limit_denominator(1001)
    width, height = a["width"], a["height"]
    with_audio = a["audio"] and b["audio"]
    rate = 0
    if with_audio:
        with av.open(first) as c:
            rate = c.streams.audio[0].codec_context.sample_rate or 48000
    with nvai_video.MasterWriter(out, width, height, fps, rate, 2 if with_audio else 0) as writer:
        for idx, src in enumerate((first, second)):
            drop_frames = skip if idx == 1 else 0
            drop_samples = int(round(rate * drop_frames / float(fps))) if with_audio else 0
            resampler = av.AudioResampler(format="fltp", layout="stereo", rate=rate) if with_audio else None
            with av.open(src) as c:
                streams = [c.streams.video[0]] + ([c.streams.audio[0]] if with_audio else [])
                for packet in c.demux(*streams):
                    for frame in packet.decode():
                        if isinstance(frame, av.VideoFrame):
                            if drop_frames:
                                drop_frames -= 1
                                continue
                            if frame.width != width or frame.height != height:
                                frame = frame.reformat(width=width, height=height)
                            writer.add_frame(frame.to_ndarray(format="rgb24"))
                        elif resampler is not None:
                            for af in resampler.resample(frame):
                                arr = af.to_ndarray()
                                if drop_samples:
                                    cut = min(drop_samples, arr.shape[1])
                                    arr, drop_samples = arr[:, cut:], drop_samples - cut
                                if arr.shape[1]:
                                    writer.add_audio(arr.astype(np.float32))
            if resampler is not None:
                for af in resampler.resample(None):
                    writer.add_audio(af.to_ndarray().astype(np.float32))
        frames = writer.frames
    return {"frames": frames, "fps": float(fps), "seconds": round(frames / float(fps), 3), "width": width,
            "height": height, "audio": with_audio, "skipped": skip}


def last_frames(path: str, out: str, n: int) -> dict[str, Any]:
    """Die letzten n Bilder als verlustfreies MP4 (H.264 qp 0 in 4:4:4) mit der Bildrate des Videos: der Übertrag einer
    Latent-Kette, den ComfyUIs LoadVideo liest (MKV listet es nicht als Video)."""
    from collections import deque

    a = info(path)
    fps = Fraction(a["fps"]).limit_denominator(1001)
    tail: deque = deque(maxlen=max(1, int(n)))
    with av.open(path) as c:
        for frame in c.decode(video=0):
            tail.append(frame.to_ndarray(format="rgb24"))
    if not tail:
        raise SystemExit("Video ohne Bild")
    height, width = tail[0].shape[:2]
    with av.open(out, "w") as dst:
        vs = dst.add_stream("libx264", rate=fps)
        vs.width, vs.height, vs.pix_fmt = width, height, "yuv444p"
        vs.options = {"qp": "0", "preset": "medium"}
        for i, rgb in enumerate(tail):
            vf = av.VideoFrame.from_ndarray(rgb, format="rgb24").reformat(format="yuv444p")
            vf.pts, vf.time_base = i, 1 / fps
            for p in vs.encode(vf):
                dst.mux(p)
        for p in vs.encode(None):
            dst.mux(p)
    return {"frames": len(tail), "width": width, "height": height, "fps": float(fps)}


def _audio_all(path: str, rate: int) -> np.ndarray | None:
    """Der ganze Ton als float32 [2, Proben] mit der gewünschten Rate (für die Überblendung; Clips sind kurz)."""
    with av.open(path) as c:
        if not c.streams.audio:
            return None
        resampler = av.AudioResampler(format="fltp", layout="stereo", rate=rate)
        parts = []
        for frame in c.decode(audio=0):
            parts += [af.to_ndarray() for af in resampler.resample(frame)]
        parts += [af.to_ndarray() for af in resampler.resample(None)]
    return np.concatenate(parts, axis=1).astype(np.float32) if parts else None


def _xfade_audio(first: np.ndarray, second: np.ndarray, overlap_s: float, rate: int) -> np.ndarray:
    """Ton des ersten Clips bis zu seinem Ende, dann der des zweiten ab der Stelle, an der er neue Bilder zeigt
    (overlap_s); die letzten 40 ms des ersten gehen gleich laut (cos/sin) in die 40 ms davor des zweiten über.
    Länge = erster + zweiter − Überlappung, wie das Bild."""
    s1, s2 = first.shape[1], min(second.shape[1], int(round(overlap_s * rate)))
    fade = max(1, min(int(0.04 * rate), s1, s2))
    k = np.linspace(0.0, np.pi / 2, fade, dtype=np.float32)
    mixed = first[:, s1 - fade:] * np.cos(k) + second[:, s2 - fade:s2] * np.sin(k)
    return np.concatenate([first[:, :s1 - fade], mixed, second[:, s2:]], axis=1)


def _xfade_frames(first: str, second: str, n: int):
    """Bilder (rgb24) von erstem + zweitem Clip, die n überlappenden linear überblendet; gestreamt bis auf die n Bilder
    am Ende des ersten. Liefert (Anzahl Überblendbilder, Generator)."""
    from collections import deque

    n = max(1, min(int(n), info(first)["frames"] or n, info(second)["frames"] or n))

    def gen():
        held: deque = deque()
        with av.open(first) as c:
            for frame in c.decode(video=0):
                held.append(frame.to_ndarray(format="rgb24"))
                if len(held) > n:
                    yield held.popleft()
        with av.open(second) as c:
            for i, frame in enumerate(c.decode(video=0)):
                rgb = frame.to_ndarray(format="rgb24")
                if held:
                    if rgb.shape != held[0].shape:
                        rgb = frame.reformat(width=held[0].shape[1], height=held[0].shape[0]).to_ndarray(format="rgb24")
                    w = (i + 1) / (n + 1)
                    rgb = np.clip(held.popleft().astype(np.float32) * (1 - w) + rgb.astype(np.float32) * w + 0.5,
                                  0, 255).astype(np.uint8)
                yield rgb
        while held:  # zweiter Clip kürzer als die Überlappung
            yield held.popleft()

    return n, gen()


def concat_xfade(first: str, second: str, out: str, crf: float, n: int) -> dict[str, Any]:
    """Latent-Kette anhängen: die n Bilder, die der zweite Clip vom ersten übernommen hat, überblenden statt doppeln."""
    a, b = info(first), info(second)
    fps = Fraction(a["fps"]).limit_denominator(1001)
    width, height = a["width"], a["height"]
    n, frames = _xfade_frames(first, second, n)
    rate, audio = 0, None
    if a["audio"] and b["audio"]:
        with av.open(first) as c:
            rate = c.streams.audio[0].codec_context.sample_rate or 48000
        one, two = _audio_all(first, rate), _audio_all(second, rate)
        if one is not None and two is not None:
            audio = _xfade_audio(one, two, n / float(fps), rate)
    count = 0
    with av.open(out, "w", options={"movflags": "+faststart"}) as dst:
        vs = dst.add_stream("libx264", rate=fps)
        vs.width, vs.height, vs.pix_fmt = width, height, "yuv420p"
        vs.options = {"crf": f"{crf:g}", "preset": "medium"}
        ast = dst.add_stream("aac", rate=rate, layout="stereo") if audio is not None else None
        for rgb in frames:
            vf = av.VideoFrame.from_ndarray(rgb, format="rgb24").reformat(format="yuv420p")
            vf.pts, vf.time_base = count, 1 / fps
            count += 1
            for p in vs.encode(vf):
                dst.mux(p)
        for p in vs.encode(None):
            dst.mux(p)
        if ast is not None:
            for start in range(0, audio.shape[1], 1024):
                af = av.AudioFrame.from_ndarray(np.ascontiguousarray(audio[:, start:start + 1024]), format="fltp",
                                                layout="stereo")
                af.sample_rate, af.pts, af.time_base = rate, start, Fraction(1, rate)
                for p in ast.encode(af):
                    dst.mux(p)
            for p in ast.encode(None):
                dst.mux(p)
    return {"frames": count, "fps": float(fps), "seconds": round(count / float(fps), 3), "width": width,
            "height": height, "audio": audio is not None, "xfade": n}


def concat_xfade_master(first: str, second: str, out: str, n: int) -> dict[str, Any]:
    """Wie concat_xfade, aber verlustfrei: zwei Master zu einem neuen Master, Ton als Float-PCM."""
    sys.path.insert(0, str(Path(__file__).resolve().parent / "comfy_nodes"))
    import nvai_video

    a, b = info(first), info(second)
    fps = Fraction(a["fps"]).limit_denominator(1001)
    n, frames = _xfade_frames(first, second, n)
    rate, audio = 0, None
    if a["audio"] and b["audio"]:
        with av.open(first) as c:
            rate = c.streams.audio[0].codec_context.sample_rate or 48000
        one, two = _audio_all(first, rate), _audio_all(second, rate)
        if one is not None and two is not None:
            audio = _xfade_audio(one, two, n / float(fps), rate)
    with nvai_video.MasterWriter(out, a["width"], a["height"], fps, rate, 2 if audio is not None else 0) as writer:
        for rgb in frames:
            writer.add_frame(rgb)
        if audio is not None:
            writer.add_audio(audio)
        count = writer.frames
    return {"frames": count, "fps": float(fps), "seconds": round(count / float(fps), 3), "width": a["width"],
            "height": a["height"], "audio": audio is not None, "xfade": n}


def preview(src: str, out: str) -> dict[str, Any]:
    """Vorschau zum Ansehen im Browser für Dateien, die er nicht abspielt (FFV1, ProRes, MKV/AVI mit fremden Codecs):
    H.264 mit CRF 20, höchstens 1920 Bildpunkte breit, Ton als AAC."""
    a = info(src)
    fps = Fraction(a["fps"] or 24).limit_denominator(1001)
    width, height = a["width"], a["height"]
    if width > 1920:
        width, height = 1920, int(round(height * 1920 / width / 2)) * 2
    width, height = width // 2 * 2, height // 2 * 2
    count = 0
    with av.open(src) as c, av.open(out, "w", options={"movflags": "+faststart"}) as dst:
        vs = dst.add_stream("libx264", rate=fps)
        vs.width, vs.height, vs.pix_fmt = width, height, "yuv420p"
        vs.options = {"crf": "20", "preset": "veryfast"}
        streams = [c.streams.video[0]]
        ast = resampler = None
        apos = 0
        if c.streams.audio:
            rate = c.streams.audio[0].codec_context.sample_rate or 48000
            ast = dst.add_stream("aac", rate=rate, layout="stereo")
            resampler = av.AudioResampler(format="fltp", layout="stereo", rate=rate)
            streams.append(c.streams.audio[0])
        for packet in c.demux(*streams):
            for frame in packet.decode():
                if isinstance(frame, av.VideoFrame):
                    frame = frame.reformat(width=width, height=height, format="yuv420p")
                    frame.pts = count
                    frame.time_base = 1 / fps
                    count += 1
                    for p in vs.encode(frame):
                        dst.mux(p)
                elif resampler is not None:
                    for af in resampler.resample(frame):
                        af.pts, af.time_base = apos, Fraction(1, af.sample_rate)
                        apos += af.samples
                        for p in ast.encode(af):
                            dst.mux(p)
        for p in vs.encode(None):
            dst.mux(p)
        if ast is not None:
            for af in resampler.resample(None):
                af.pts, af.time_base = apos, Fraction(1, af.sample_rate)
                apos += af.samples
                for p in ast.encode(af):
                    dst.mux(p)
            for p in ast.encode(None):
                dst.mux(p)
    return {"frames": count, "width": width, "height": height}


def main(argv: list[str]) -> None:
    cmd = argv[0] if argv else ""
    if cmd == "info" and len(argv) == 2:
        result = info(argv[1])
    elif cmd == "probe" and len(argv) == 2:
        result = probe(argv[1])
    elif cmd == "last-frame" and len(argv) == 3:
        result = last_frame(argv[1], argv[2])
    elif cmd == "concat" and len(argv) in (5, 6):
        result = concat(argv[1], argv[2], argv[3], float(argv[4]), int(argv[5]) if len(argv) == 6 else 1)
    elif cmd == "preview" and len(argv) == 3:
        result = preview(argv[1], argv[2])
    elif cmd == "concat-master" and len(argv) in (4, 5):
        result = concat_master(argv[1], argv[2], argv[3], int(argv[4]) if len(argv) == 5 else 1)
    elif cmd == "last-frames" and len(argv) == 4:
        result = last_frames(argv[1], argv[2], int(argv[3]))
    elif cmd == "concat-xfade" and len(argv) == 6:
        result = concat_xfade(argv[1], argv[2], argv[3], float(argv[4]), int(argv[5]))
    elif cmd == "concat-xfade-master" and len(argv) == 5:
        result = concat_xfade_master(argv[1], argv[2], argv[3], int(argv[4]))
    else:
        raise SystemExit(__doc__)
    print(json.dumps(result))


if __name__ == "__main__":
    main(sys.argv[1:])
