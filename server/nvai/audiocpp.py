"""Ton und Sprache ueber Vulkan: audio.cpp fuer Karten ohne CUDA und ROCm (seit 0.5.35, GitHub-Issue #3).

audio.cpp (Apache-2.0, ShugoAI LLC, https://github.com/0xShug0/audio.cpp) rechnet Audiomodelle mit ggml, ohne PyTorch,
auch ueber Vulkan. Auf aelteren Radeons und Intel-Karten nimmt es ComfyUI auf dem Prozessor den Ton ab: Geraeusche mit
Stable Audio 3 Small SFX, Musik mit Stable Audio 3 Medium (GGUF-Pakete aus audio-cpp/audio.cpp-gguf, Lizenz Stability AI
Community) und die Sprecherstimme mit Qwen3-TTS 1.7B (dieselben Modellordner wie der CUDA-Weg, VoiceDesign und Base).
Damit ist DirectML ganz entbehrlich (Nutzer 22.11.: „es wäre schön wenn ML komplett verschwindet“).

Ein Auftrag = ein Aufruf von ``audiocpp_cli.exe``; das Protokoll steht in ``<Daten>/audiocpp.log``. Musik und Geraeusche
gehen wie im ComfyUI-Weg als MP3 mit Spitzen hoechstens -1 dB in den Verlauf (video_tools.py finish-audio im
ComfyUI-venv), Sprache als WAV.
"""
from __future__ import annotations

import asyncio
import json
import os
import re
import subprocess
import time
import uuid
from pathlib import Path
from typing import Any, Callable

from . import config, db, gpu, workflows
from .i18n import t

WORKFLOW = "audiocpp_stable_audio"
LOG = config.DATA_DIR / "audiocpp.log"
# Fortschritt, soweit audio.cpp ihn meldet (Schritte des Abtastens bzw. erzeugte Sprach-Tokens)
_STEP = re.compile(r"(?:step|steps?)\s*[:=]?\s*(\d+)\s*/\s*(\d+)", re.IGNORECASE)


def exe() -> Path:
    override = os.getenv("NVAI_AUDIOCPP")  # Tests: Programm ausserhalb der Installation
    return Path(override) if override else config.ROOT / "external" / "audiocpp" / "audiocpp_cli.exe"


def available() -> bool:
    return exe().exists()


def active() -> bool:
    """Rechnet audio.cpp auf diesem Rechner? Nur ohne CUDA/ROCm (gpu.cpu_mode), wenn das Setup es eingerichtet hat und
    NVAI_AUDIOCPP_ENGINE nicht 0 ist."""
    if os.getenv("NVAI_AUDIOCPP_ENGINE", "1") == "0" or not available():
        return False
    return gpu.cpu_mode() is not None


def handles(entry: dict[str, Any], kind: str) -> bool:
    if kind == "audio":
        return entry.get("workflow") == WORKFLOW and active()
    if kind == "speech":
        return entry.get("family") == "qwen3_tts" and active()
    return False


def _env() -> dict[str, str] | None:
    from . import engine  # Vulkan-Nummer vom Setup, sonst aus der Reparatur des Servers (engine.json)
    device = engine.vulkan_index()
    return {**os.environ, "GGML_VK_VISIBLE_DEVICES": str(device)} if device is not None else None


def _model_path(entry: dict[str, Any]) -> Path:
    """GGUF-Datei des Katalogeintrags (Ziel unter dem Modellordner)."""
    f = entry["files"][0]
    return config.COMFY_MODEL_DIR / f["target"] / workflows.file_name(f)


async def _run(args: list[str], entry: dict[str, Any], label: str, on_progress: Callable[[float, str], None],
               cleanup: Callable[[], None], secret: set[str]) -> tuple[int, list[str]]:
    """audiocpp_cli ausfuehren, Fortschritt melden (soweit es ihn ausgibt), Protokoll schreiben; Abbrechen beendet den
    Prozess und raeumt auf. Texte (Prompt, Sprechtext, Stimme) stehen nicht im Protokoll."""
    t0 = time.monotonic()
    with LOG.open("a", encoding="utf-8", errors="replace") as log:
        log.write(f"\n{'=' * 60}\nStart {time.strftime('%Y-%m-%d %H:%M:%S')} {entry['id']}\n"
                  f"Args: {' '.join('<text>' if a in secret else a for a in args[1:])}\n")
        log.flush()
        proc = await asyncio.create_subprocess_exec(
            *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT, cwd=str(config.ASSET_DIR),
            env=_env(), creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        tail: list[str] = []
        buf = b""
        on_progress(0.1, label)
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
                    if m and int(m.group(2)) > 0:
                        on_progress(0.1 + 0.8 * min(1.0, int(m.group(1)) / int(m.group(2))), label)
                    log.write(line + "\n")
                    tail = (tail + [line])[-12:]
            rc = await proc.wait()
        except asyncio.CancelledError:
            if proc.returncode is None:
                proc.kill()
                await proc.wait()
            cleanup()
            log.write("abgebrochen\n")
            raise
        log.write(f"Ende rc={rc} nach {time.monotonic() - t0:.1f} s\n")
    return rc, tail


def _failed(tail: list[str]) -> RuntimeError:
    return RuntimeError(t("audio.cpp (Vulkan) brach ab. Letzte Zeilen:\n",
                          "audio.cpp (Vulkan) stopped. Last lines:\n") + "\n".join(tail))


def _tool(*argv: str) -> dict[str, Any]:
    """video_tools.py im ComfyUI-venv (PyAV, numpy): Ton umwandeln, begrenzen, als MP3 schreiben."""
    from . import comfy
    script = Path(__file__).with_name("video_tools.py")
    proc = subprocess.run([str(comfy.comfy_python()), "-I", str(script), *argv], capture_output=True, text=True,
                          timeout=300, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout).strip()[-600:])
    return json.loads(proc.stdout.strip().splitlines()[-1])


async def run_audio(entry: dict[str, Any], p: dict[str, Any],
                    on_progress: Callable[[float, str], None]) -> tuple[list[Path], dict[str, Any]]:
    """Musik oder Geraeusch mit Stable Audio 3 (GGUF). Rueckgabe: MP3 im Asset-Ordner und Metadaten."""
    config.ensure_dirs()
    d = workflows.defaults_for(entry["workflow"])
    seed = int(p["seed"]) if p.get("seed") is not None else int.from_bytes(os.urandom(4), "big") >> 1
    seconds = float(p.get("seconds") or (entry.get("features") or {}).get("recommended", {}).get("seconds") or 10)
    steps = int(p.get("steps") or d["steps"])
    cfg = float(p.get("cfg") if p.get("cfg") is not None else d["cfg"])
    stem = f"{uuid.uuid4().hex[:12]}_nvai_audio_vulkan"
    wav, mp3 = config.ASSET_DIR / f"{stem}.wav", config.ASSET_DIR / f"{stem}.mp3"
    prompt, negative = p.get("prompt", ""), p.get("negative_prompt") or ""
    args = [str(exe()), "--task", "gen", "--family", "stable_audio", "--model", str(_model_path(entry)),
            "--backend", "vulkan", "--text", prompt, "--duration-seconds", f"{seconds:g}", "--seed", str(seed),
            "--num-inference-steps", str(steps), "--guidance-scale", f"{cfg:g}", "--out", str(wav)]
    if negative:
        args += ["--request-option", f"negative_prompt={negative}"]
    t0 = time.monotonic()
    rc, tail = await _run(args, entry, t("erzeugt Ton (Vulkan)", "generating sound (Vulkan)"), on_progress,
                          lambda: wav.unlink(missing_ok=True), {prompt, f"negative_prompt={negative}"})
    if rc != 0 or not wav.exists() or wav.stat().st_size == 0:
        wav.unlink(missing_ok=True)
        raise _failed(tail)
    on_progress(0.95, t("speichert", "saving"))
    try:
        info = await asyncio.to_thread(_tool, "finish-audio", str(wav), str(mp3), str(workflows.AUDIO_CEILING_DB))
    finally:
        wav.unlink(missing_ok=True)
    meta = {"engine": "audio.cpp (Vulkan)", "seed": seed, "seconds": seconds, "steps": steps, "cfg": cfg,
            "engine_s": round(time.monotonic() - t0, 1), "peak_db": info.get("peak_db")}
    return [mp3], meta


async def run_speech(entry: dict[str, Any], p: dict[str, Any], dirs: dict[str, Path], ref: Path | None,
                     on_progress: Callable[[float, str], None]) -> tuple[Path, dict[str, Any]]:
    """Sprecherstimme mit Qwen3-TTS: aus der Beschreibung (VoiceDesign) oder mit der Stimme einer Aufnahme (Base, die
    ersten 20 s als WAV). Rueckgabe: WAV im Asset-Ordner und Metadaten wie im CUDA-Weg."""
    config.ensure_dirs()
    seed = int(p["seed"]) if p.get("seed") is not None else int.from_bytes(os.urandom(4), "big") >> 1
    out = config.ASSET_DIR / f"{db.new_id('tts')}.wav"
    text, voice = p["text"], p.get("voice") or ""
    secret = {text, voice}
    # SpeechLanguage sind schon die Kuerzel, die audio.cpp erwartet (de, en, ...); auto = ohne Angabe
    lang = "" if (p.get("language") or "auto") == "auto" else str(p["language"])
    work = config.DATA_DIR / "tmp" / "tts"
    work.mkdir(parents=True, exist_ok=True)
    tmp_ref = work / f"{uuid.uuid4().hex[:8]}_ref.wav"
    if ref is None:
        mode = "design"
        args = [str(exe()), "--task", "vdes", "--family", "qwen3_tts", "--model", str(dirs["design"]),
                "--instruct", voice]
    else:
        mode = "clone"
        await asyncio.to_thread(_tool, "to-wav", str(ref), str(tmp_ref), "20")
        args = [str(exe()), "--task", "tts", "--family", "qwen3_tts", "--model", str(dirs["clone"]),
                "--voice-ref", str(tmp_ref)]
        ref_text = (p.get("voice_text") or "").strip()
        if ref_text:
            args += ["--reference-text", ref_text]
            secret.add(ref_text)
        else:
            args += ["--request-option", "x_vector_only_mode=true"]
    args += ["--backend", "vulkan", "--text", text, "--seed", str(seed), "--out", str(out)]
    if lang:
        args += ["--language", lang]
    t0 = time.monotonic()
    try:
        rc, tail = await _run(args, entry, t("spricht (Vulkan)", "speaking (Vulkan)"), on_progress,
                              lambda: out.unlink(missing_ok=True), secret)
    finally:
        tmp_ref.unlink(missing_ok=True)
    if rc != 0 or not out.exists() or out.stat().st_size == 0:
        out.unlink(missing_ok=True)
        raise _failed(tail)
    meta = {"engine": "audio.cpp (Vulkan)", "mode": mode, "seed": seed, "language": p.get("language") or "auto",
            "gen_s": round(time.monotonic() - t0, 1)}
    return out, meta
