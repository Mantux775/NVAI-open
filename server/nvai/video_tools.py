"""Videowerkzeuge für „Video verlängern“ (seit 0.5.10), laufen im ComfyUI-venv (PyAV, Pillow) wie
outpaint_align.py: den letzten Frame herauslösen und zwei Clips samt Ton aneinanderhängen. Gestreamt Bild
für Bild, damit auch lange 1080p-Videos keinen zweistelligen Gigabyte-Bedarf an Arbeitsspeicher haben.
Kein ffmpeg-Programm nötig; PyAV bringt ComfyUI für SaveVideo ohnehin mit. Ausgabe: eine JSON-Zeile.

    python video_tools.py info <video>
    python video_tools.py probe <datei>            (Video oder reiner Ton, fürs Studio)
    python video_tools.py last-frame <video> <bild.png>
    python video_tools.py concat <erster.mp4> <zweiter.mp4> <ziel.mp4> <crf> [<frames_ueberspringen>]
    python video_tools.py concat-master <erster.mkv> <zweiter.mkv> <ziel.mkv> [<frames_ueberspringen>]
    python video_tools.py preview <video> <vorschau.mp4>   (H.264 für den Browser, höchstens 1920 breit)

Beim Anhängen fällt der erste Frame des zweiten Clips weg (er ist der letzte des ersten, das Startbild), samt
dem Ton dieser Bilddauer, damit Bild und Ton synchron bleiben. Kodiert wird wie SaveVideo: H.264, CRF, AAC;
concat-master hängt die verlustfreien Master (FFV1/MKV, comfy_nodes/nvai_video.py) genauso verlustfrei aneinander.
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
    else:
        raise SystemExit(__doc__)
    print(json.dumps(result))


if __name__ == "__main__":
    main(sys.argv[1:])
