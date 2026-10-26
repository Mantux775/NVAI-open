"""NVAI-opens eigene ComfyUI-Knoten fuer Video. NVAI-open kopiert diese Datei beim Start von ComfyUI nach
custom_nodes/ (comfy._install_nodes); ComfyUI laedt sie wie jede andere Erweiterung. video_tools.py und
studio_render.py nutzen MasterWriter auch direkt (ComfyUI-venv, PyAV).

NVAISaveMaster: speichert die Bilder eines erzeugten Videos zusaetzlich verlustfrei, als FFV1 in MKV (8 Bit RGB,
jedes Bild ein Schluesselbild) mit dem Ton als 32-Bit-Float-PCM. Das MP4 von SaveVideo (H.264, Farbe 4:2:0) bleibt
fuer Vorschau, Browser und Unity; das Studio schneidet und exportiert aus dem Master, und das Startbild eines
Anschlusses kommt daraus, damit sich Kompressionsfehler nicht von Clip zu Clip fortpflanzen (Nutzer 26.10.2026:
„dass die ki erstellten videos unkomprimiert sind, wegen dem qualitaets verlust“). Pixelgleich mit dem, was das
Modell ausgibt, nach der Rundung auf 8 Bit, die jedes Video braucht; gemessen: Rundreise bild- und probengleich,
1080p mit 76 Bildern/s geschrieben.
"""
from __future__ import annotations

import math
import os
from fractions import Fraction

import av
import numpy as np

try:  # ComfyUI stellt beides bereit; MasterWriter geht auch ohne
    import folder_paths
    import torch
except ImportError:  # pragma: no cover
    folder_paths = None
    torch = None

MASTER_OPTIONS = {"level": "3", "slices": "16", "slicecrc": "1", "g": "1"}
AUDIO_CHUNK = 4096


def frame_bytes(frame) -> np.ndarray:
    """Ein Bild (H, W, 3) als uint8, gerundet statt abgeschnitten."""
    if torch is not None and isinstance(frame, torch.Tensor):
        return (frame.float() * 255.0).round().clamp(0, 255).to(torch.uint8).cpu().numpy()
    arr = np.asarray(frame)
    if arr.dtype == np.uint8:
        return arr
    return np.clip(np.round(arr.astype(np.float32) * 255.0), 0, 255).astype(np.uint8)


class MasterWriter:
    """Schreibt einen Master Bild fuer Bild und Ton blockweise, ohne das ganze Video im Speicher zu halten."""

    def __init__(self, path: str, width: int, height: int, fps: float | Fraction, sample_rate: int = 0,
                 channels: int = 0):
        self.rate = Fraction(fps).limit_denominator(1001)
        self.out = av.open(path, "w", format="matroska")
        self.video = self.out.add_stream("ffv1", rate=self.rate)
        self.video.width, self.video.height, self.video.pix_fmt = width, height, "bgr0"
        self.video.options = dict(MASTER_OPTIONS)
        self.video.thread_type = "SLICE"
        self.sound = None
        if sample_rate and channels:
            layout = {1: "mono", 2: "stereo"}.get(channels, "stereo")
            self.sound = self.out.add_stream("pcm_f32le", rate=sample_rate, layout=layout)
        self.frames = 0
        self.samples = 0

    def add_frame(self, rgb: np.ndarray) -> None:
        frame = av.VideoFrame.from_ndarray(np.ascontiguousarray(rgb), format="rgb24").reformat(format="bgr0")
        frame.pts = self.frames
        frame.time_base = 1 / self.rate
        self.out.mux(self.video.encode(frame))
        self.frames += 1

    def add_audio(self, wave: np.ndarray) -> None:
        """wave: [Kanaele, Proben] float32."""
        if self.sound is None:
            return
        channels = self.sound.layout.nb_channels
        if wave.shape[0] != channels:  # Mono auf Stereo und umgekehrt
            wave = np.repeat(wave[:1], channels, axis=0) if wave.shape[0] == 1 else wave[:channels]
        for start in range(0, wave.shape[1], AUDIO_CHUNK):
            part = wave[:, start:start + AUDIO_CHUNK]
            frame = av.AudioFrame.from_ndarray(np.ascontiguousarray(part.T.reshape(1, -1), dtype=np.float32),
                                               format="flt", layout=self.sound.layout.name)
            frame.sample_rate = self.sound.rate
            frame.pts = self.samples
            frame.time_base = Fraction(1, self.sound.rate)
            self.out.mux(self.sound.encode(frame))
            self.samples += part.shape[1]

    def close(self) -> None:
        self.out.mux(self.video.encode(None))
        if self.sound is not None:
            self.out.mux(self.sound.encode(None))
        self.out.close()

    def __enter__(self) -> "MasterWriter":
        return self

    def __exit__(self, *exc) -> None:
        self.close()


def write_master(path: str, frames, fps: float, audio: dict | None = None) -> dict:
    """frames ([N, H, W, 3], 0..1 oder uint8), fps und optional audio ({"waveform": [B, C, S], "sample_rate": int})
    als MKV. Der Ton wird wie bei ComfyUIs SaveVideo auf die Laenge des Bildes gekuerzt."""
    n, h, w = int(frames.shape[0]), int(frames.shape[1]), int(frames.shape[2])
    wave, sr = None, 0
    if audio is not None:
        sr = int(audio["sample_rate"])
        wave = audio["waveform"][0]
        wave = wave.float().cpu().numpy() if torch is not None and isinstance(wave, torch.Tensor) else np.asarray(wave)
        wave = wave[:, :math.ceil(sr / float(Fraction(fps).limit_denominator(1001)) * n)].astype(np.float32)
    with MasterWriter(path, w, h, fps, sr, wave.shape[0] if wave is not None else 0) as writer:
        for i in range(n):
            writer.add_frame(frame_bytes(frames[i]))
        if wave is not None:
            writer.add_audio(wave)
    return {"frames": n, "bytes": os.path.getsize(path)}


class NVAISaveMaster:
    """Verlustfreier Master neben dem MP4 (siehe Moduldoku)."""

    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "images": ("IMAGE",),
                "fps": ("FLOAT", {"default": 24.0, "min": 1.0, "max": 120.0, "step": 0.001}),
                "filename_prefix": ("STRING", {"default": "nvai_master"}),
            },
            "optional": {"audio": ("AUDIO",)},
        }

    RETURN_TYPES = ()
    OUTPUT_NODE = True
    FUNCTION = "save"
    CATEGORY = "video/NVAI-open"
    DESCRIPTION = "Speichert das Video zusaetzlich verlustfrei (FFV1/MKV, Ton als Float-PCM) fuer Schnitt und Export."

    def save(self, images, fps, filename_prefix, audio=None):
        h, w = int(images.shape[1]), int(images.shape[2])
        folder, name, counter, subfolder, _ = folder_paths.get_save_image_path(
            filename_prefix, folder_paths.get_output_directory(), w, h)
        file = f"{name}_{counter:05}_.mkv"
        write_master(os.path.join(folder, file), images, fps, audio)
        # Eigener Schluessel: NVAI-open haengt den Master an das MP4-Asset, statt ein zweites anzulegen
        return {"ui": {"nvai_master": [{"filename": file, "subfolder": subfolder, "type": "output"}]}}


NODE_CLASS_MAPPINGS = {"NVAISaveMaster": NVAISaveMaster}
NODE_DISPLAY_NAME_MAPPINGS = {"NVAISaveMaster": "NVAI-open Save Lossless Master"}
