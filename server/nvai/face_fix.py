"""Gesicht nachrechnen (seit 28.11.2026, Nutzer: „baue die nachrechnen funktion in studio und generieren ein“).

Auftrag „face_fix“ für ein Bild oder ein Video mit einer Person, deren Gesicht klein ist oder vom Original abweicht:
1. Gesicht finden (face_tools.py detect, Haar-Kaskaden aus opencv-python-headless < 5 im ComfyUI-venv; fehlt OpenCV,
   wird es beim ersten Mal eingerichtet, rund 40 MB).
2. Kopfausschnitt (2,4 × Gesichtsbreite) auf 1024 px, die Gesichtszüge weichgezeichnet: So nimmt FLUX 3 das Gesicht
   aus dem Originalfoto (zweite Referenz). Mit „Keep the first image exactly“ übernahm es das abweichende Gesicht, über
   eine Kette von Clips summierte sich das.
3. Ergebnis am Ausschnitt ausrichten (outpaint_align), mit weicher Ellipse einsetzen; außerhalb bleibt jedes Pixel.
4. Video: dasselbe an einem Schlüsselbild (0,5 s, kleinere Videos auf 1920 Breite vergrößert), dann das neue Gesicht in
   jedem Bild per ECC auf den laufenden Kopf legen, Licht je Bild angleichen (face_tools.py video). Die Augen sind in
   jedem Bild dieselben; innerhalb des Clips blinzelt es nicht. Gemessen an Video-Clips (Gesicht ~105 px in 768p,
   Pupillen ab Bild 0 weg): 73 Bilder in ~24 s plus ein FLUX-Lauf, ECC 0,995+.

Vorerst ein Gesicht je Auftrag (das sicherste oder face_index); face_tools nimmt Listen, damit später mehrere
Gesichter mit je eigenem Foto gehen (Nutzer: „in der zukunft will ich mehrere gesichter tauschen“).
"""
from __future__ import annotations

import asyncio
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
import time
import traceback
import uuid
from pathlib import Path
from typing import Any

from . import comfy, config, db, workflows
from .i18n import t
from .jobs import JobContext, _badge_meta, _ensure_backend, _name, _restore_model, master_path, register
from .schemas import Job

TOOLS = Path(__file__).with_name("face_tools.py")
OPENCV = "opencv-python-headless>=4.10,<5"   # OpenCV 5 hat keine Haar-Kaskaden mehr
KEY_SECONDS = 0.5
WORK_WIDTH = 1920
# Kein „beard“ und keine anderen Merkmale, die nicht jede Person hat: Mit „…, mouth, beard and skin“ (für einen
# bärtigen Mann geschrieben) bekam eine Frau einen Bart und männliche Züge (Mac, FLUX.2 Klein, 2 von 2). Alter und
# Geschlecht kommen aus dem Foto.
PROMPT = ("Edit the first image, a close-up of a person's head. Replace the face with the face of the person in the "
          "second image, so that it is clearly the same person, with the same age and the same gender as in the second "
          "image: exactly their face shape, forehead, cheeks, jaw, eyes, eyebrows, nose, mouth and skin. "
          "From the first image keep only the headgear, "
          "the hair outline, the clothing, the head position, size and angle, the light, the colors and the "
          "background. Both eyes are clear and natural, the same size, with the pupils centered, looking in the same "
          "direction as in the first image. The same expression as in the first image, the mouth as in the first "
          "image. Photorealistic, natural skin texture.")


def face_python() -> Path:
    """Python mit OpenCV, numpy, Pillow und PyAV: das ComfyUI-venv (NVAI_FACE_PYTHON überschreibt es für Tests)."""
    return Path(os.getenv("NVAI_FACE_PYTHON") or comfy.comfy_python())


async def _run(*args: Any, timeout: float = 1800.0) -> dict[str, Any]:
    proc = await asyncio.create_subprocess_exec(
        str(face_python()), "-I", str(TOOLS), *(str(a) for a in args), stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout)
    except asyncio.TimeoutError:
        proc.kill()
        raise RuntimeError(t("Gesicht nachrechnen: Zeit überschritten.", "Recompute face: timed out."))
    if proc.returncode != 0:
        raise RuntimeError(t(f"Gesicht nachrechnen fehlgeschlagen: {err.decode(errors='replace')[-400:]}",
                             f"Recompute face failed: {err.decode(errors='replace')[-400:]}"))
    return json.loads(out.decode().strip().splitlines()[-1])


async def _ensure_opencv(ctx: JobContext) -> None:
    """OpenCV im ComfyUI-venv; beim ersten Mal mit uv nachinstallieren (ohne Abhängigkeiten: numpy bleibt)."""
    py = face_python()
    check = await asyncio.create_subprocess_exec(
        str(py), "-I", "-c", "import cv2, os; assert os.path.isdir(cv2.data.haarcascades)",
        stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    if await check.wait() == 0:
        return
    uv = config.ROOT / "tools" / ("uv.exe" if sys.platform == "win32" else "uv")
    uv_exe = str(uv) if uv.exists() else shutil.which("uv")
    if not uv_exe:
        raise RuntimeError(t("Für „Gesicht nachrechnen“ fehlt OpenCV, und uv zum Einrichten fehlt auch.",
                             "“Recompute face” needs OpenCV, and uv to set it up is missing too."))
    ctx.progress(0.02, t("richtet die Gesichtserkennung ein (einmalig, rund 40 MB)",
                         "setting up face detection (once, about 40 MB)"))
    proc = await asyncio.create_subprocess_exec(
        uv_exe, "pip", "install", "--python", str(py), "--no-deps", OPENCV, stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT, env={**os.environ, "UV_LINK_MODE": "copy"},
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    out, _ = await proc.communicate()
    if proc.returncode != 0:
        raise RuntimeError(t(f"OpenCV ließ sich nicht einrichten: {out.decode(errors='replace')[-400:]}",
                             f"Could not set up OpenCV: {out.decode(errors='replace')[-400:]}"))


def measure_eyes(video: Path, times: list[float]) -> dict[str, Any]:
    """Augen je Zeitpunkt (face_tools eyes) für „Köpfe in der Überblendung angleichen“ (studio, synchron, kurz).
    Fehlt OpenCV, wird es wie beim Nachrechnen einmal per uv eingerichtet."""
    py = face_python()
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    probe = subprocess.run([str(py), "-I", "-c", "import cv2"], capture_output=True, creationflags=flags)
    if probe.returncode != 0:
        uv = config.ROOT / "tools" / ("uv.exe" if sys.platform == "win32" else "uv")
        uv_exe = str(uv) if uv.exists() else shutil.which("uv")
        if not uv_exe:
            raise RuntimeError(t("Für die Gesichtserkennung fehlt OpenCV, und uv zum Einrichten fehlt auch.",
                                 "Face detection needs OpenCV, and uv to set it up is missing too."))
        subprocess.run([uv_exe, "pip", "install", "--python", str(py), "--no-deps", OPENCV], capture_output=True,
                       env={**os.environ, "UV_LINK_MODE": "copy"}, creationflags=flags, timeout=600, check=True)
    proc = subprocess.run([str(py), "-I", str(TOOLS), "eyes", str(video), json.dumps(times)], capture_output=True,
                          text=True, timeout=300, creationflags=flags)
    if proc.returncode != 0:
        raise RuntimeError(t(f"Augen messen fehlgeschlagen: {proc.stderr[-400:]}",
                             f"Measuring the eyes failed: {proc.stderr[-400:]}"))
    return json.loads(proc.stdout.strip().splitlines()[-1])


def _path_of(asset: Any) -> Path:
    return config.ASSET_DIR / asset.filename


def _next_to_source(asset_id: str, src: Any, p: dict[str, Any]) -> None:
    """Ohne Studio-Projekt neben die Quelle legen (wie upscale_video), etwa in ihren Projektordner; mit Projekt legt
    studio._place_job_assets das Ergebnis in dessen Ordner."""
    if p.get("studio_project") or not src.folder:
        return
    try:
        db.move_asset(asset_id, src.folder)
    except (OSError, ValueError):
        traceback.print_exc()  # bleibt im Verlauf


def _is_video(asset: Any) -> bool:
    return asset.kind == "video" or (asset.kind == "upload" and comfy.kind_for(_path_of(asset)) == "video")


@register("face_fix")
async def _face_fix(job: Job, ctx: JobContext) -> list[str]:
    p = job.params
    src = db.get_asset(p.get("asset_id", ""))
    ref = db.get_asset(p.get("reference_asset_id", ""))
    if src is None or not _path_of(src).exists():
        raise RuntimeError(t("Bild oder Video nicht gefunden.", "Image or video not found."))
    if ref is None or not _path_of(ref).exists() or comfy.kind_for(_path_of(ref)) != "image":
        raise RuntimeError(t("Originalfoto fehlt: ein Foto der Person als Vorlage wählen.",
                             "The original photo is missing: choose a photo of the person as the reference."))
    video = _is_video(src)
    await _ensure_opencv(ctx)
    seed = int(p["seed"]) if p.get("seed") is not None else random.randint(0, 2 ** 31 - 1)
    tmp = Path(tempfile.mkdtemp(prefix="nvai_face_", dir=config.DATA_DIR))
    try:
        ctx.progress(0.05, t("sucht das Gesicht", "finding the face"))
        if video:
            source = master_path(src) or _path_of(src)
            key = tmp / "key.png"
            key_info = await _run("frame", source, float(p.get("key_seconds") or KEY_SECONDS), WORK_WIDTH, key)
        else:
            key, key_info = _path_of(src), {}
        faces = (await _run("detect", key))["faces"]
        if not faces:
            raise RuntimeError(t("Kein Gesicht gefunden (frontal, ab rund 40 px Höhe).",
                                 "No face found (frontal, about 40 px tall or more)."))
        face = faces[min(int(p.get("face_index") or 0), len(faces) - 1)]
        crop, soft = tmp / "crop.png", tmp / "soft.png"
        await _run("prepare", key, json.dumps(face), crop, soft)

        entry = _restore_model({"model_id": p.get("model_id")})
        await _ensure_backend(ctx)
        pp: dict[str, Any] = {"prompt": PROMPT, "negative_prompt": "",
                              "reference_images": [comfy.stage_input(soft), comfy.stage_input(_path_of(ref))],
                              "width": 1024, "height": 1024, "batch_size": 1, "seed": seed,
                              "reference_megapixels": 1.0, "upsample_prompt": False}
        graph, _ = workflows.build(entry, pp)
        comfy.set_loaded_model(_name(entry))
        stage = t("Gesicht nachrechnen", "Recomputing the face")

        def on_progress(frac: float, step: str) -> None:
            ctx.progress(0.10 + frac * (0.45 if video else 0.80), f"{stage} · {step}")

        t0 = time.time()
        outs = await comfy.run_workflow(graph, on_progress=on_progress, timeout=900.0)
        if not outs:
            raise RuntimeError(t("ComfyUI lieferte kein Bild zurück.", "ComfyUI returned no image."))
        flux_s = round(time.time() - t0, 1)
        base = {"source_asset_id": src.id, "reference_asset_id": ref.id, "model_name": _name(entry), "seed": seed,
                **_badge_meta(p)}
        if not video:
            out = config.ASSET_DIR / f"{uuid.uuid4().hex[:12]}_nvai_face.png"
            info = await _run("composite", key, outs[0], crop, json.dumps(face), out)
            for f in outs:
                Path(f).unlink(missing_ok=True)
            asset = db.create_asset(kind="image", filename=out.name, job_id=job.id, prompt=src.prompt or "",
                                    model_id=entry["id"],
                                    meta={**base, "face_fix": {"face": face, "faces_found": len(faces), "align": info,
                                                               "seconds": flux_s}})
            _next_to_source(asset.id, src, p)
            return [asset.id]
        keyfix = tmp / "key_fix.png"
        info = await _run("composite", key, outs[0], crop, json.dumps(face), keyfix)
        for f in outs:
            Path(f).unlink(missing_ok=True)
        ctx.progress(0.60, f"{stage} · " + t("legt das Gesicht auf jedes Bild", "placing the face on every frame"))
        out = config.ASSET_DIR / f"{uuid.uuid4().hex[:12]}_nvai_face.mp4"
        t1 = time.time()
        vinfo = await _run("video", source, key, keyfix, json.dumps([face]), WORK_WIDTH, out)
        asset = db.create_asset(
            kind="video", filename=out.name, job_id=job.id, prompt=src.prompt or "", model_id=entry["id"],
            meta={**base, "width": vinfo["width"], "height": vinfo["height"], "fps": vinfo["fps"],
                  "frames": vinfo["frames"], "duration_s": round(vinfo["frames"] / max(1.0, vinfo["fps"]), 3),
                  "face_fix": {"face": face, "faces_found": len(faces), "align": info, "key": key_info,
                               "key_frame": vinfo["key_frame"], "track_misses": vinfo["track_misses"],
                               "seconds": {"flux": flux_s, "video": round(time.time() - t1, 1)}}})
        _next_to_source(asset.id, src, p)
        return [asset.id]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
