"""stable-diffusion.cpp: fuer Karten ohne CUDA und ROCm ueber Vulkan (seit 0.5.34 Video, seit 0.5.35 auch Bilder;
GitHub-Issue #3), seit 0.5.35 auf Wunsch auch auf NVIDIA ueber CUDA oder Vulkan (Wahl unter „Deine Hardware“, engine.py).

Aeltere Radeons (RX 5000, Vega, Polaris) und Intel-Karten: stable-diffusion.cpp rechnet ueber Vulkan, ohne PyTorch.
DirectML (0.5.33/0.5.34) ist seit 0.5.35 raus: auf einer echten RX 5700 XT brauchte ein Pony-Bild 1344 x 768 mit
zweitem Durchgang rund 6 min (Issue #3), Video ging dort gar nicht, und es hing an PyTorch 2.4.1 und Flicken in ComfyUI.
Gemessen auf der RTX 5060 Ti mit dem Budget einer 8-GB-Karte (notizen/gpu.md): SDXL 1024² 22 s, ohne Matrix-Einheiten
57 s (DirectML 83 s); Wan 2.1 1.3B, 832 x 480, 33 Bilder in 194 s.

Ein Auftrag = ein Aufruf von ``sd-cli.exe``; die Engine nimmt dieselben Dateien wie ComfyUI (Katalog). Fortschritt aus
der Ausgabe ("|===>  | 5/30 - 4.15s/it"), Abbrechen beendet den Prozess, das Protokoll steht in ``<Daten>/sdcpp.log``.
"""
from __future__ import annotations

import asyncio
import os
import re
import subprocess
import tempfile
import time
import uuid
from pathlib import Path
from typing import Any, Callable

from . import config, db, gpu, workflows
from .i18n import t

# Was die Engine rechnet (Workflow-Namen des Katalogs)
VIDEO_WORKFLOWS = {"wan_t2v"}
IMAGE_WORKFLOWS = {"sdxl"}
WORKFLOWS = VIDEO_WORKFLOWS | IMAGE_WORKFLOWS
LOG = config.DATA_DIR / "sdcpp.log"
_STEP = re.compile(r"\|\s*(\d+)/(\d+)\s*-\s*([\d.]+)\s*(s/it|it/s)")

# ComfyUI-Namen -> stable-diffusion.cpp (sd-cli --help); was fehlt, faellt auf die naechste Verwandte
SAMPLERS = {
    "euler": "euler", "euler_ancestral": "euler_a", "heun": "heun", "dpm_2": "dpm2",
    "dpmpp_2s_ancestral": "dpm++2s_a", "dpmpp_2m": "dpm++2m", "dpmpp_2m_sde": "dpm++2m_sde",
    "dpmpp_2m_sde_gpu": "dpm++2m_sde", "dpmpp_sde": "dpm++2m_sde", "lcm": "lcm", "ipndm": "ipndm",
    "ipndm_v": "ipndm_v", "ddim": "ddim_trailing", "res_multistep": "res_multistep", "er_sde": "er_sde",
    "lms": "lms", "euler_cfg_pp": "euler_cfg_pp", "euler_ancestral_cfg_pp": "euler_a_cfg_pp",
}
SCHEDULERS = {
    "normal": "discrete", "karras": "karras", "exponential": "exponential", "sgm_uniform": "sgm_uniform",
    "simple": "simple", "beta": "beta", "kl_optimal": "kl_optimal", "ddim_uniform": "discrete",
}


# Was sd.cpp nicht kann: rechnet PyTorch auf der Karte (NVIDIA, ROCm), uebernimmt ComfyUI solche Auftraege
UNSUPPORTED = (("controlnet", "ControlNet", "ControlNet"), ("reference_asset_ids", "Referenzbilder", "reference images"),
               ("slg", "Skip-Layer-Guidance", "skip-layer guidance"))


def backend() -> str | None:
    """Programm, mit dem sd.cpp hier rechnet ("cuda" oder "vulkan"), oder None: dann rechnet ComfyUI. Auto ist Vulkan
    auf Karten ohne CUDA/ROCm (gpu.cpu_mode), sonst ComfyUI; die Wahl unter „Deine Hardware“ steht in engine.json.
    NVAI_SDCPP_ENGINE=0 schaltet sd.cpp ab."""
    if os.getenv("NVAI_SDCPP_ENGINE", "1") == "0":
        return None
    from . import engine
    eff = engine.effective()
    if eff["engine"] != "sdcpp" or not engine.installed(eff["backend"]):
        return None
    return eff["backend"]


def backend_label() -> str:
    return {"cuda": "CUDA", "vulkan": "Vulkan"}.get(backend() or "", "Vulkan")


def exe() -> Path:
    from . import engine
    return engine.exe(backend() or "vulkan")


def available() -> bool:
    return exe().exists()


def active() -> bool:
    """Rechnet sd.cpp auf diesem Rechner Bilder und Videos (SDXL, Wan 2.1 1.3B)?"""
    return backend() is not None


def handles(entry: dict[str, Any], kind: str, p: dict[str, Any] | None = None) -> bool:
    wf = entry.get("workflow")
    if not ((kind == "video" and wf in VIDEO_WORKFLOWS) or (kind == "image" and wf in IMAGE_WORKFLOWS)):
        return False
    if not active():
        return False
    # Rechnet PyTorch auf der Karte, macht ComfyUI, was sd.cpp fehlt, statt den Auftrag abzulehnen
    if p and gpu.cpu_mode() is None and (any(p.get(key) for key, _, _ in UNSUPPORTED)
                                         or (kind == "video" and p.get("loras"))):
        return False
    return True


def model_file(entry: dict[str, Any], target: str) -> Path:
    for f in entry["files"]:
        if f["target"] == target:
            return config.COMFY_MODEL_DIR / target / workflows.file_name(f)
    raise RuntimeError(t(f"{entry['id']}: keine Datei für {target}", f"{entry['id']}: no file for {target}"))


# Video ueber Vulkan mit festem Budget: Ohne holt sd.cpp den Text-Encoder (umt5-xxl, 6,4 GB) mit auf die Karte, und Wan
# 2.1 1.3B kam auf der RTX 5060 Ti (16 GB) in 17 min nicht ueber den ersten Schritt, mit 12 GiB auch nicht in 5 min; mit
# 7 GiB liegt der Text-Encoder im Arbeitsspeicher: 182 s fuer 2 s Video (22.11.2026). Ueber CUDA lief es ohne Budget.
VULKAN_VIDEO_MAX_VRAM = "7"


def _budget(args: list[str], video: bool = False) -> list[str]:
    budget = os.getenv("NVAI_SDCPP_MAX_VRAM")  # Tests: so viel Grafikspeicher wie eine kleinere Karte (GiB)
    if not budget and video and backend() == "vulkan":
        budget = VULKAN_VIDEO_MAX_VRAM
    return args + (["--max-vram", budget] if budget else [])


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
    meta = {"engine": f"stable-diffusion.cpp ({backend_label()})", "seed": seed, "width": width, "height": height,
            "frames": frames, "fps": fps, "steps": steps, "cfg": cfg, "sampler": "euler", "shift": shift}
    return _budget(args, video=True), meta


def _asset_file(asset_id: str, what: tuple[str, str]) -> Path:
    asset = db.get_asset(asset_id)
    path = config.ASSET_DIR / asset.filename if asset else None
    if path is None or not path.exists():
        raise RuntimeError(t(f"{what[0]} nicht gefunden: {asset_id}", f"{what[1]} not found: {asset_id}"))
    return path


def _tool(*argv: str) -> dict[str, Any]:
    """video_tools.py im ComfyUI-venv (Pillow): Start- und Maskenbild vorbereiten; im Server-venv gibt es kein Pillow."""
    import json
    from . import comfy
    script = Path(__file__).with_name("video_tools.py")
    proc = subprocess.run([str(comfy.comfy_python()), "-I", str(script), *argv], capture_output=True, text=True,
                          timeout=120, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout).strip()[-600:])
    return json.loads(proc.stdout.strip().splitlines()[-1])


def _fit(src: Path, width: int, height: int, out: Path, *, mode: str = "RGB") -> Path:
    """Bild auf die Zielgroesse bringen wie ImageScale im ComfyUI-Weg (mittig beschnitten, Lanczos)."""
    _tool("fit-image", str(src), str(out), str(width), str(height), mode)
    return out


def _outpaint(src: Path, pads: list[int], width: int, height: int, tmp: Path) -> tuple[Path, Path]:
    """Erweitern wie ImagePadForOutpaint (Rand, Maske mit weichem Uebergang, Zielgroesse ohne Beschnitt)."""
    img, mask = tmp / "outpaint.png", tmp / "outpaint_mask.png"
    _tool("outpaint-image", str(src), str(img), str(mask), str(width), str(height),
          *[str(int(v)) for v in pads], str(int(workflows.OUTPAINT_FEATHER)))
    return img, mask


def image_args(entry: dict[str, Any], p: dict[str, Any], loras: list[dict[str, Any]], out: Path,
               tmp: Path) -> tuple[list[str], dict[str, Any]]:
    """Aufruf fuer SDXL-Checkpoints mit denselben Angaben wie workflows.build_image: Groesse, Schritte, CFG, Sampler und
    Scheduler (uebersetzt), Seed, Stapel, Startbild mit Staerke, Maske, Erweitern, zweiter Durchgang, LoRAs."""
    for key, de, en in UNSUPPORTED:
        if p.get(key):
            raise RuntimeError(t(f"{de} geht mit stable-diffusion.cpp nicht.",
                                 f"{en} does not work with stable-diffusion.cpp."))
    d = workflows.defaults_for(entry["workflow"])
    seed = int(p["seed"]) if p.get("seed") is not None else int.from_bytes(os.urandom(4), "big") >> 1
    width, height = int(p.get("width", 1024)), int(p.get("height", 1024))
    batch = max(1, int(p.get("batch_size", 1)))
    steps = int(p.get("steps") or d["steps"])
    cfg = float(p.get("cfg") if p.get("cfg") is not None else d["cfg"])
    sampler = p.get("sampler") or d["sampler"]
    scheduler = p.get("scheduler") or d["scheduler"]
    prompt = p.get("prompt", "")
    lora_dir = config.COMFY_MODEL_DIR / "loras"
    for lo in loras:  # Schreibweise von stable-diffusion.cpp: <lora:Name ohne Endung:Staerke>
        prompt += f" <lora:{Path(lo['file']).with_suffix('').as_posix()}:{float(lo['strength']):g}>"
    args = [str(exe()), "-M", "img_gen", "-m", str(model_file(entry, "checkpoints")),
            "-p", prompt, "-n", p.get("negative_prompt", ""),
            "-W", str(width), "-H", str(height), "--steps", str(steps), "--cfg-scale", f"{cfg:g}",
            "--sampling-method", SAMPLERS.get(sampler, "euler_a"),
            "--scheduler", SCHEDULERS.get(scheduler, "discrete"),
            # Rauschen wie ComfyUI (auf dem Prozessor erzeugt): gleiche Seeds geben ein aehnliches Bild wie mit CUDA
            "--rng", "cpu", "-s", str(seed), "-b", str(batch), "-o", str(out), "-v"]
    vae = config.COMFY_MODEL_DIR / "vae" / "sdxl_vae.safetensors"
    if vae.exists():  # SDXL-VAE (fp16-fix) statt der eingebauten, wenn geladen (Katalog: sdxl-vae-fp16)
        args += ["--vae", str(vae)]
    if loras:
        args += ["--lora-model-dir", str(lora_dir)]
    meta: dict[str, Any] = {"engine": f"stable-diffusion.cpp ({backend_label()})", "seed": seed, "width": width, "height": height,
                            "steps": steps, "cfg": cfg, "sampler": sampler, "scheduler": scheduler}
    outpaint = [int(v) for v in (p.get("outpaint") or [])]
    if any(outpaint):
        if not p.get("image_asset_id"):
            raise RuntimeError(t("Erweitern braucht ein Ausgangsbild.", "Extending needs a source image."))
        img, mask = _outpaint(_asset_file(p["image_asset_id"], ("Startbild", "Start image")), outpaint, width, height,
                              tmp)
        args += ["-i", str(img), "--mask", str(mask), "--strength", "1"]
        meta["outpaint"] = outpaint
    elif p.get("image_asset_id"):
        img = _fit(_asset_file(p["image_asset_id"], ("Startbild", "Start image")), width, height, tmp / "start.png")
        strength = float(p.get("denoise", 1.0))
        args += ["-i", str(img), "--strength", f"{strength:g}"]
        meta["denoise"] = strength
        if p.get("mask_asset_id"):
            mask = _fit(_asset_file(p["mask_asset_id"], ("Maske", "Mask")), width, height, tmp / "mask.png", mode="L")
            args += ["--mask", str(mask)]
    final = width * height * (float(p.get("hires_scale", 1.25)) ** 2 if p.get("hires") else 1.0)
    if final > 1.1e6:
        # VAE in Kacheln ab gut 1 MP: 1344 x 768 mit zweitem Durchgang (1728 x 960) brauchte am Stueck 4 GB und 127 s
        # zum Dekodieren, in Kacheln war der ganze Auftrag in 40 s fertig (RTX 5060 Ti, Budget 7 GiB)
        args += ["--vae-tiling"]
        meta["vae_tiling"] = True
    if p.get("hires"):
        hs = p.get("hires_steps")
        hires = {"scale": float(p.get("hires_scale", 1.25)), "denoise": float(p.get("hires_denoise", 0.45)),
                 "steps": int(hs) if hs else max(8, steps // 2)}
        args += ["--hires", "--hires-scale", f"{hires['scale']:g}", "--hires-denoising-strength",
                 f"{hires['denoise']:g}", "--hires-steps", str(hires["steps"]), "--hires-upscaler", "Latent (bicubic)"]
        meta["hires"] = hires
    return _budget(args), meta


async def _run(args: list[str], entry: dict[str, Any], label: str, passes: int,
               on_progress: Callable[[float, str], None], cleanup: Callable[[], None]) -> tuple[int, list[str]]:
    """sd-cli ausfuehren, Fortschritt melden (Abtasten 0..90 % ueber alle Durchgaenge, Rest Dekodieren), Protokoll
    schreiben. Abbrechen beendet den Prozess und raeumt auf."""
    t0 = time.monotonic()
    prompts = {a for i, a in enumerate(args) if i and args[i - 1] in ("-p", "-n")}
    with LOG.open("a", encoding="utf-8", errors="replace") as log:
        log.write(f"\n{'=' * 60}\nStart {time.strftime('%Y-%m-%d %H:%M:%S')} {entry['id']}\n"
                  f"Args: {' '.join('<prompt>' if a in prompts else a for a in args[1:])}\n")
        log.flush()
        env = None
        from . import engine
        if backend() == "cuda":
            if gpu.multi_gpu():  # dieselbe Karte wie ComfyUIs Bilder (nvidia-smi zaehlt nach PCI-Bus)
                env = {**os.environ, "CUDA_DEVICE_ORDER": "PCI_BUS_ID", "CUDA_VISIBLE_DEVICES": str(gpu.device_for("image"))}
        elif (device := engine.vulkan_index()) is not None:
            env = {**os.environ, "GGML_VK_VISIBLE_DEVICES": str(device)}
        proc = await asyncio.create_subprocess_exec(
            *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT, cwd=str(config.ASSET_DIR),
            env=env, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        tail: list[str] = []
        buf = b""
        done_passes, last_done = 0, 0
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
                        if done < last_done:  # neuer Durchgang (zweiter Durchgang, naechstes Bild im Stapel)
                            done_passes += 1
                        last_done = done
                        frac = min(1.0, (done_passes + done / max(1, total)) / max(1, passes))
                        on_progress(0.9 * frac, label)
                        continue
                    if "decode" in line and "completed" not in line:
                        on_progress(0.92, t(f"dekodiert ({backend_label()})", f"decoding ({backend_label()})"))
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
    return RuntimeError(t(f"stable-diffusion.cpp ({backend_label()}) brach ab. Letzte Zeilen:\n",
                          f"stable-diffusion.cpp ({backend_label()}) stopped. Last lines:\n") + "\n".join(tail))


async def run_video(entry: dict[str, Any], p: dict[str, Any],
                    on_progress: Callable[[float, str], None]) -> tuple[list[Path], dict[str, Any]]:
    """Rechnet einen Clip und legt ihn in den Asset-Ordner. Rueckgabe wie comfy.run_workflow plus Metadaten."""
    config.ensure_dirs()
    out = config.ASSET_DIR / f"{uuid.uuid4().hex[:12]}_nvai_video_{backend() or 'vulkan'}.webm"
    args, meta = video_args(entry, p, out)
    t0 = time.monotonic()
    rc, tail = await _run(args, entry, t(f"generiert ({backend_label()})", f"generating ({backend_label()})"), 1, on_progress,
                          lambda: out.unlink(missing_ok=True))
    if rc != 0 or not out.exists() or out.stat().st_size == 0:
        out.unlink(missing_ok=True)
        raise _failed(tail)
    meta["engine_s"] = round(time.monotonic() - t0, 1)
    return [out], meta


async def run_image(entry: dict[str, Any], p: dict[str, Any], loras: list[dict[str, Any]],
                    on_progress: Callable[[float, str], None]) -> tuple[list[Path], dict[str, Any]]:
    """Rechnet ein Bild oder einen Stapel und legt sie in den Asset-Ordner (PNG)."""
    config.ensure_dirs()
    stem = f"{uuid.uuid4().hex[:12]}_nvai_{backend() or 'vulkan'}"
    out = config.ASSET_DIR / f"{stem}.png"

    def produced() -> list[Path]:
        return sorted(config.ASSET_DIR.glob(f"{stem}*.png"), key=lambda q: (len(q.name), q.name))

    def cleanup() -> None:
        for q in produced():
            q.unlink(missing_ok=True)

    with tempfile.TemporaryDirectory(prefix="nvai-sdcpp-") as tmp:
        args, meta = image_args(entry, p, loras, out, Path(tmp))
        passes = int(meta.get("hires") is not None) + 1
        passes *= max(1, int(p.get("batch_size", 1)))
        t0 = time.monotonic()
        rc, tail = await _run(args, entry, t(f"generiert ({backend_label()})", f"generating ({backend_label()})"), passes, on_progress,
                              cleanup)
    files = [q for q in produced() if q.stat().st_size > 0]
    if rc != 0 or not files:
        cleanup()
        raise _failed(tail)
    meta["engine_s"] = round(time.monotonic() - t0, 1)
    return files, meta
