"""Zweite Engine: stable-diffusion.cpp mit Vulkan (seit 0.5.34, GitHub-Issue #3).

Fuer Karten ohne CUDA und ROCm (aeltere Radeons, perspektivisch Intel): stable-diffusion.cpp rechnet ueber Vulkan, das
jede DirectX-12-taugliche Karte unter Windows spricht, ohne PyTorch. Gemessen auf der RTX 5060 Ti mit dem Budget einer
8-GB-Karte (notizen/gpu.md): Wan 2.1 1.3B, 832 x 480, 33 Bilder in 194 s (4,2 s je Schritt; ueber DirectML 27 s je
Schritt und Abbruch, weil torch-directml nur 5 Dimensionen kennt), SDXL 1024² in 34 s (DirectML 83 s, CUDA 16 s).

Ein Auftrag = ein Aufruf von ``sd-cli.exe`` (Modelle werden je Auftrag geladen; bei Video faellt das nicht ins Gewicht).
Die Engine nimmt dieselben Dateien wie ComfyUI (Katalog, auch FP8-Text-Encoder). Fortschritt aus der Ausgabe
("|===>  | 5/30 - 4.15s/it"), Abbrechen beendet den Prozess, das ganze Protokoll steht in ``<Daten>/sdcpp.log``.
"""
from __future__ import annotations

import asyncio
import os
import re
import subprocess
import time
import uuid
from pathlib import Path
from typing import Any, Callable

from . import config, gpu, workflows
from .i18n import t

# Was die Engine rechnet (Workflow-Namen des Katalogs). Phase 1: Video mit Wan 2.1 T2V 1.3B.
WORKFLOWS = {"wan_t2v"}
LOG = config.DATA_DIR / "sdcpp.log"
_STEP = re.compile(r"\|\s*(\d+)/(\d+)\s*-\s*([\d.]+)\s*(s/it|it/s)")


def exe() -> Path:
    override = os.getenv("NVAI_SDCPP")  # Tests: Programm ausserhalb der Installation
    return Path(override) if override else config.ROOT / "external" / "sdcpp" / "sd-cli.exe"


def available() -> bool:
    return exe().exists()


def active() -> bool:
    """Rechnet die Vulkan-Engine auf diesem Rechner? Nur ohne CUDA/ROCm (gpu.cpu_mode: Radeon ohne ROCm oder
    keine Karte, auf der PyTorch rechnet), wenn das Setup sie eingerichtet hat und NVAI_SDCPP_ENGINE nicht 0 ist."""
    if os.getenv("NVAI_SDCPP_ENGINE", "1") == "0" or not available():
        return False
    return gpu.cpu_mode() is not None


def handles(entry: dict[str, Any], kind: str) -> bool:
    return kind == "video" and entry.get("workflow") in WORKFLOWS and active()


def model_file(entry: dict[str, Any], target: str) -> Path:
    for f in entry["files"]:
        if f["target"] == target:
            return config.COMFY_MODEL_DIR / target / workflows.file_name(f)
    raise RuntimeError(t(f"{entry['id']}: keine Datei für {target}", f"{entry['id']}: no file for {target}"))


def video_args(entry: dict[str, Any], p: dict[str, Any], out: Path) -> tuple[list[str], dict[str, Any]]:
    """Aufruf fuer Wan 2.1 T2V und die Angaben fuer die Asset-Metadaten. Formate und Laengen wie im ComfyUI-Weg
    (workflows.build_video): 832 x 480, Bilder 4n+1, 16 fps, Negativprompt und Shift aus den Vorgaben."""
    wf = entry["workflow"]
    d = workflows.defaults_for(wf)
    seed = int(p["seed"]) if p.get("seed") is not None else int.from_bytes(os.urandom(4), "big") >> 1
    width, height = int(p.get("width", 832)), int(p.get("height", 480))
    frames = workflows.normalize_frames(int(p.get("frames", 49)), wf)
    fps = max(1, int(round(float(p.get("fps", 16)))))
    steps = int(p.get("steps") or d["steps"])
    cfg = float(p.get("cfg") if p.get("cfg") is not None else d["cfg"])
    shift = float(p.get("shift") or d.get("shift", 8.0))
    negative = p.get("negative_prompt") or workflows.DEFAULT_VIDEO_NEGATIVE
    args = [str(exe()), "-M", "vid_gen",
            "--diffusion-model", str(model_file(entry, "diffusion_models")),
            "--vae", str(model_file(entry, "vae")),
            "--t5xxl", str(model_file(entry, "text_encoders")),
            "-p", p.get("prompt", ""), "-n", negative,
            "--cfg-scale", f"{cfg:g}", "--sampling-method", "euler", "--flow-shift", f"{shift:g}",
            "-W", str(width), "-H", str(height), "--video-frames", str(frames), "--fps", str(fps),
            "--steps", str(steps), "--seed", str(seed), "-o", str(out), "-v"]
    budget = os.getenv("NVAI_SDCPP_MAX_VRAM")  # Tests: so viel Grafikspeicher wie eine kleinere Karte (GiB)
    if budget:
        args += ["--max-vram", budget]
    meta = {"engine": "stable-diffusion.cpp (Vulkan)", "seed": seed, "width": width, "height": height,
            "frames": frames, "fps": fps, "steps": steps, "cfg": cfg, "sampler": "euler", "shift": shift}
    return args, meta


async def run_video(entry: dict[str, Any], p: dict[str, Any],
                    on_progress: Callable[[float, str], None]) -> tuple[list[Path], dict[str, Any]]:
    """Rechnet einen Clip und legt ihn in den Asset-Ordner. Rueckgabe wie comfy.run_workflow plus Metadaten."""
    config.ensure_dirs()
    out = config.ASSET_DIR / f"{uuid.uuid4().hex[:12]}_nvai_video_vulkan.webm"
    args, meta = video_args(entry, p, out)
    t0 = time.monotonic()
    with LOG.open("a", encoding="utf-8", errors="replace") as log:
        log.write(f"\n{'=' * 60}\nStart {time.strftime('%Y-%m-%d %H:%M:%S')} {entry['id']}\n"
                  f"Args: {' '.join(a if a != p.get('prompt') else '<prompt>' for a in args[1:])}\n")
        log.flush()
        proc = await asyncio.create_subprocess_exec(
            *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT, cwd=str(config.ASSET_DIR),
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        tail: list[str] = []
        buf = b""
        try:
            assert proc.stdout is not None
            while True:
                chunk = await proc.stdout.read(4096)
                if not chunk:
                    break
                buf += chunk
                parts = re.split(rb"[\r\n]", buf)
                buf = parts.pop()
                for raw in parts:
                    line = raw.decode("utf-8", "replace").strip()
                    if not line:
                        continue
                    m = _STEP.search(line)
                    if m:
                        done, total = int(m.group(1)), int(m.group(2))
                        # Abtasten 0..90 %, der Rest fuer das Dekodieren des Videos
                        on_progress(0.9 * done / max(1, total), t("generiert (Vulkan)", "generating (Vulkan)"))
                        continue
                    if "decode" in line and "completed" not in line:
                        on_progress(0.92, t("dekodiert (Vulkan)", "decoding (Vulkan)"))
                    log.write(line + "\n")
                    tail = (tail + [line])[-12:]
            rc = await proc.wait()
        except asyncio.CancelledError:
            if proc.returncode is None:
                proc.kill()
                await proc.wait()
            out.unlink(missing_ok=True)
            log.write("abgebrochen\n")
            raise
        log.write(f"Ende rc={rc} nach {time.monotonic() - t0:.1f} s\n")
    if rc != 0 or not out.exists() or out.stat().st_size == 0:
        out.unlink(missing_ok=True)
        raise RuntimeError(t("Die Vulkan-Engine (stable-diffusion.cpp) brach ab. Letzte Zeilen:\n",
                             "The Vulkan engine (stable-diffusion.cpp) stopped. Last lines:\n") + "\n".join(tail))
    meta["engine_s"] = round(time.monotonic() - t0, 1)
    return [out], meta
