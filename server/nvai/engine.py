"""Rechenweg fuer Bilder und Videos (seit 0.5.35): ComfyUI oder stable-diffusion.cpp, und sd.cpp ueber CUDA oder Vulkan.

Nutzer 22.11.2026: „ich soll unter Models Your hardware zwischen cuda und vulkan mit stabledifusion.cpp umstellen
koennen, dann von der stable difusion unterschiedliche modi auswaehlen koennen, aktuell cuda und vulkan. mit dem tip
welches ist am besten fuer welches und auto als auswahl in dropdown“, „genau so beim anklicken auf die ram anzeige (wie
beim multigpu)“, „bei nicht kompaktiblen gpus gibt es dann nur kompaktible optionen zur auswahl“.

Zwei Wahlen in <Daten>/engine.json:
- engine "auto" | "comfyui" | "sdcpp": Auto rechnet mit ComfyUI, wo PyTorch auf der Karte laeuft (NVIDIA, Radeon mit
  ROCm), sonst mit stable-diffusion.cpp ueber Vulkan (gpu.cpu_mode). "sdcpp" rechnet, was die Engine kann (sdcpp.WORKFLOWS:
  SDXL-Bilder, Wan 2.1 T2V 1.3B), mit sd.cpp; alles andere, und Auftraege mit Funktionen, die sd.cpp fehlen, bleiben bei
  ComfyUI.
- sdcpp_backend "auto" | "cuda" | "vulkan": Auto nimmt CUDA auf NVIDIA, sonst Vulkan.
Angeboten wird nur, was auf der Karte laeuft (compatible): CUDA nur mit NVIDIA, ComfyUI nur mit CUDA oder ROCm.

Die Programme kommen aus dem festen Release von stable-diffusion.cpp (MIT) mit den SHA-256 von GitHub: Vulkan (30 MB)
nach external/sdcpp wie im Setup, CUDA 12 (412 MB plus CUDA-Laufzeit 563 MB) nach external/sdcpp-cuda; geladen beim
ersten Wechsel. Ein Setup-Update laesst external/ stehen (nur die Deinstallation loescht es).
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path
from typing import Any

import httpx

from . import config, gpu
from .i18n import t

FILE = config.DATA_DIR / "engine.json"
ENGINES = ("auto", "comfyui", "sdcpp")
BACKENDS = ("auto", "cuda", "vulkan")
RELEASE = "https://github.com/leejet/stable-diffusion.cpp/releases/download/master-1106-532d2c1/"
# Je Modus: Ordner unter external/ und die Dateien des Releases (Name, SHA-256, Bytes)
PACKAGES: dict[str, dict[str, Any]] = {
    "vulkan": {"dir": "sdcpp", "files": [
        ("sd-master-532d2c1-bin-win-vulkan-x64.zip",
         "3e66222c87ca27074e1fd8ce79706eef17a8aaf39949906aa1bee7e060f22ecc", 30312081)]},
    "cuda": {"dir": "sdcpp-cuda", "files": [
        ("sd-master-532d2c1-bin-win-cuda12-x64.zip",
         "b087219145a382cc1b1e826318289e1f672b9bb6965977734ef0deb85fe2d03a", 412365497),
        ("cudart-sd-bin-win-cu12-x64.zip",
         "fe20366827d357c00797eebb58244dddab7fd9a348d70090c3871004c320f38d", 563452046)]},
}
# Tests: Programme ausserhalb der Installation
OVERRIDES = {"vulkan": "NVAI_SDCPP", "cuda": "NVAI_SDCPP_CUDA"}

_install: dict[str, Any] = {}  # laufender oder zuletzt gescheiterter Download: backend, done, total, error
_task: asyncio.Task[None] | None = None


def load() -> dict[str, Any]:
    s: dict[str, Any] = {"engine": "auto", "sdcpp_backend": "auto"}
    try:
        saved = json.loads(FILE.read_text(encoding="utf-8"))
        if isinstance(saved, dict):
            s.update({k: v for k, v in saved.items() if k in ("engine", "sdcpp_backend", "vulkan_index")})
    except (OSError, ValueError):
        pass
    return s


def _save(s: dict[str, Any]) -> None:
    FILE.parent.mkdir(parents=True, exist_ok=True)
    FILE.write_text(json.dumps(s, indent=2), encoding="utf-8")


def compatible() -> dict[str, list[str]]:
    """Was auf diesem Rechner laeuft. ComfyUI rechnet auf der Karte nur mit CUDA (NVIDIA) oder ROCm (Radeon ab RX 6000);
    sd.cpp gibt es fuer Windows als CUDA- (nur NVIDIA) und Vulkan-Programm. Ohne Karte, die Vulkan kann, bleibt nur
    Auto (ComfyUI auf dem Prozessor)."""
    if sys.platform != "win32":
        return {"engines": ["auto"], "backends": []}
    vendor, cpu = gpu.vendor(), gpu.cpu_mode()
    engines = ["auto"]
    if cpu is None and vendor in ("nvidia", "amd"):
        engines.append("comfyui")
    backends: list[str] = []
    if vendor == "nvidia" and cpu is None:
        backends.append("cuda")
    if (cpu is None and vendor in ("nvidia", "amd")) or (cpu is not None and _setup_vulkan()):
        backends.append("vulkan")
    if backends:
        engines.append("sdcpp")
        backends.insert(0, "auto")
    return {"engines": engines, "backends": backends}


def _setup_vulkan() -> bool:
    """Hat das Setup auf einer Karte ohne CUDA/ROCm die Vulkan-Engine eingerichtet (gpu_mode.json) oder liegt sie da?"""
    try:
        saved = json.loads((config.DATA_DIR / "gpu_mode.json").read_text(encoding="utf-8-sig"))
        v = saved.get("vulkan")
        if v is True or (isinstance(v, dict) and v.get("ok")):
            return True
    except (OSError, ValueError, AttributeError):
        pass
    return installed("vulkan")


def effective() -> dict[str, Any]:
    """Was gerade rechnet: {"engine": "comfyui"|"sdcpp", "backend": "cuda"|"vulkan"|None}. Eine Wahl, die hier nicht
    laeuft (Karte gewechselt), gilt als Auto."""
    s, c = load(), compatible()
    engine = s["engine"] if s["engine"] in c["engines"] else "auto"
    if engine == "auto":
        engine = "sdcpp" if gpu.cpu_mode() is not None and "sdcpp" in c["engines"] else "comfyui"
    if engine != "sdcpp":
        return {"engine": "comfyui", "backend": None}
    backend = s["sdcpp_backend"] if s["sdcpp_backend"] in c["backends"] else "auto"
    if backend == "auto":
        backend = "cuda" if "cuda" in c["backends"] else "vulkan"
    return {"engine": "sdcpp", "backend": backend}


def exe(backend: str) -> Path:
    override = os.getenv(OVERRIDES.get(backend, ""), "") if backend in OVERRIDES else ""
    if override:
        return Path(override)
    return config.ROOT / "external" / PACKAGES[backend]["dir"] / "sd-cli.exe"


def installed(backend: str) -> bool:
    return backend in PACKAGES and exe(backend).exists()


def vulkan_index() -> int | None:
    """Vulkan-Nummer der eigenen Karte: vom Setup (gpu_mode.json), sonst beim Laden hier ermittelt (engine.json)."""
    device = gpu.vulkan_device()
    if device is not None:
        return device
    idx = load().get("vulkan_index")
    return int(idx) if isinstance(idx, int) else None


def set_choice(engine: str | None, backend: str | None) -> dict[str, Any]:
    """Wahl speichern; was hier nicht laeuft, lehnt sie ab (ValueError). Fehlt das Programm des neuen Wegs, startet der
    Download (start_install)."""
    c = compatible()
    s = load()
    if engine is not None:
        if engine not in c["engines"]:
            raise ValueError(t(f"„{engine}“ läuft auf dieser Karte nicht.", f"“{engine}” does not run on this card."))
        s["engine"] = engine
    if backend is not None:
        if backend not in c["backends"]:
            raise ValueError(t(f"sd.cpp über „{backend}“ läuft auf dieser Karte nicht.",
                               f"sd.cpp through “{backend}” does not run on this card."))
        s["sdcpp_backend"] = backend
    _save(s)
    eff = effective()
    if eff["engine"] == "sdcpp" and not installed(eff["backend"]):
        start_install(eff["backend"])
    return state()


def state() -> dict[str, Any]:
    s, c, eff = load(), compatible(), effective()
    return {
        "engine": s["engine"], "sdcpp_backend": s["sdcpp_backend"],
        "engines": c["engines"],
        "backends": [{"id": b, "installed": b == "auto" or installed(b),
                      "download_mb": round(sum(f[2] for f in PACKAGES[b]["files"]) / 1e6) if b in PACKAGES else 0}
                     for b in c["backends"]],
        "effective": eff,
        # Laeuft der gewaehlte Weg schon? Sonst rechnet bis zum Ende des Downloads ComfyUI.
        "ready": eff["engine"] == "comfyui" or installed(eff["backend"]),
        "vendor": gpu.vendor(), "cpu_mode": gpu.cpu_mode() is not None,
        "install": dict(_install) if _install else None,
    }


def start_install(backend: str) -> None:
    global _task, _install
    if _task is not None and not _task.done():
        return
    _install = {"backend": backend, "done": 0, "total": sum(f[2] for f in PACKAGES[backend]["files"]), "error": None}
    _task = asyncio.get_running_loop().create_task(_install_task(backend))


async def _install_task(backend: str) -> None:
    try:
        await install(backend)
        _install.clear()
    except Exception as exc:  # noqa: BLE001 - die Oberflaeche zeigt den Grund
        _install["error"] = str(exc) or exc.__class__.__name__


async def install(backend: str) -> None:
    """Release-Dateien laden, SHA-256 pruefen, in einen frischen Ordner entpacken, mit --list-devices pruefen, ob das
    Programm eine Karte sieht (Vulkan: eine eigene, uma 0), dann an seinen Platz legen."""
    pkg = PACKAGES[backend]
    dest = config.ROOT / "external" / pkg["dir"]
    tmp_dir = config.DATA_DIR / "downloads" / f"sdcpp-{backend}"
    new = dest.with_name(dest.name + ".new")
    shutil.rmtree(new, ignore_errors=True)
    tmp_dir.mkdir(parents=True, exist_ok=True)
    new.mkdir(parents=True)
    try:
        async with httpx.AsyncClient(follow_redirects=True, timeout=httpx.Timeout(60.0, connect=30.0)) as client:
            for name, sha, size in pkg["files"]:
                part = tmp_dir / name
                h = hashlib.sha256()
                async with client.stream("GET", RELEASE + name) as r:
                    r.raise_for_status()
                    with part.open("wb") as f:
                        async for chunk in r.aiter_bytes(1 << 20):
                            f.write(chunk)
                            h.update(chunk)
                            _install["done"] = _install.get("done", 0) + len(chunk)
                if h.hexdigest() != sha:
                    raise RuntimeError(t(f"{name}: Prüfsumme stimmt nicht", f"{name}: checksum mismatch"))
                await asyncio.to_thread(_unzip, part, new)
                part.unlink(missing_ok=True)
        cli = next(new.rglob("sd-cli.exe"), None)
        if cli is None:
            raise RuntimeError(t("sd-cli.exe fehlt im Paket", "sd-cli.exe is missing from the package"))
        if cli.parent != new:  # Paket mit Unterordner: Inhalt nach oben holen
            for item in cli.parent.iterdir():
                shutil.move(str(item), new / item.name)
        out = await asyncio.to_thread(_list_devices, new / "sd-cli.exe")
        if backend == "vulkan":
            m = re.search(r"(?m)^ggml_vulkan: (\d+) = (.+?) \| uma: 0 ", out)
            if not m:
                raise RuntimeError(t("Vulkan sieht keine eigene Grafikkarte.", "Vulkan sees no dedicated graphics card."))
            if gpu.vulkan_device() is None:
                s = load()
                s["vulkan_index"] = int(m.group(1))
                _save(s)
        elif not re.search(r"found \d+ CUDA devices|CUDA[0-9]?\s*:|Device 0:", out):
            raise RuntimeError(t("Die CUDA-Fassung findet keine NVIDIA-Karte.", "The CUDA build finds no NVIDIA card."))
        shutil.rmtree(dest, ignore_errors=True)
        new.rename(dest)
    finally:
        shutil.rmtree(new, ignore_errors=True)
        shutil.rmtree(tmp_dir, ignore_errors=True)


def _unzip(archive: Path, target: Path) -> None:
    """Entpacken ohne Pfade ausserhalb des Ziels (Zip-Slip)."""
    root = target.resolve()
    with zipfile.ZipFile(archive) as z:
        for info in z.infolist():
            out = (target / info.filename).resolve()
            if root != out and root not in out.parents:
                raise RuntimeError(f"{archive.name}: {info.filename}")
        z.extractall(target)


def _list_devices(cli: Path) -> str:
    r = subprocess.run([str(cli), "--list-devices"], capture_output=True, text=True, timeout=120,
                       encoding="utf-8", errors="replace", cwd=str(cli.parent),
                       creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    return (r.stdout or "") + (r.stderr or "")
