"""TripoSG-Worker: erzeugt aus einem Bild ein 3D-Mesh (GLB).

Laeuft in einem EIGENEN venv und Prozess (external/triposg/.venv), weil TripoSG
andere diffusers-/numpy-Versionen braucht als ComfyUI. Kommunikation ueber HTTP.

Dieses Modul importiert bewusst nichts aus `nvai` -- es muss in einem venv
lauffaehig sein, das den Orchestrator nicht kennt. Konfiguration kommt aus der
Umgebung:

    TRIPOSG_ROOT   Pfad zum geklonten TripoSG-Repo (fuer das Python-Package)
    TRIPOSG_MODEL  Pfad zum heruntergeladenen Modell-Snapshot
    TRIPOSG_PORT   Port (Standard 8200)
"""
from __future__ import annotations

import gc
import os
import sys
import time
import types
from pathlib import Path
from typing import Any

import numpy as np
import torch
import trimesh
from fastapi import FastAPI, HTTPException
from PIL import Image
from pydantic import BaseModel, Field

ROOT = Path(os.environ.get("TRIPOSG_ROOT", "")).resolve()
MODEL_DIR = Path(os.environ.get("TRIPOSG_MODEL", "")).resolve()
PORT = int(os.environ.get("TRIPOSG_PORT", "8200"))

if not ROOT.exists():
    raise SystemExit(f"TRIPOSG_ROOT fehlt oder existiert nicht: {ROOT}")
sys.path.insert(0, str(ROOT))

# ---------------------------------------------------------------- diso
# TripoSG importiert `diso` auf Modulebene, benutzt es aber nur im
# flash-Decoder-Pfad. Ohne kompilierte CUDA-Extension stellen wir einen Stub
# bereit und weichen auf den hierarchischen Decoder (skimage marching_cubes) aus.
try:
    import diso  # noqa: F401

    HAS_DISO = True
except ImportError:
    HAS_DISO = False
    _stub = types.ModuleType("diso")

    class _MissingDiffDMC:
        def __init__(self, *args: Any, **kwargs: Any) -> None:
            raise RuntimeError("diso ist nicht installiert - use_flash_decoder=False noetig")

    _stub.DiffDMC = _MissingDiffDMC  # type: ignore[attr-defined]
    sys.modules["diso"] = _stub

from triposg.pipelines.pipeline_triposg import TripoSGPipeline  # noqa: E402

app = FastAPI(title="NVAI-open TripoSG-Worker")

_pipe: TripoSGPipeline | None = None
_device = "cuda" if torch.cuda.is_available() else "cpu"
_dtype = torch.float16 if _device == "cuda" else torch.float32


class GenerateRequest(BaseModel):
    image_path: str = Field(..., description="Absoluter Pfad zum Eingangsbild")
    output_path: str = Field(..., description="Zielpfad fuer die GLB-Datei")
    num_inference_steps: int = Field(50, ge=1, le=200)
    guidance_scale: float = Field(7.0, ge=0.0, le=20.0)
    seed: int | None = None
    faces: int = Field(-1, description="Zielanzahl Faces; -1 = keine Reduktion")
    remove_background: bool = Field(True, description="Hintergrund automatisch freistellen")
    project_front: bool = Field(False, description="Vorderseite aus dem Bild aufs Mesh projizieren "
                                                    "(front_projection.py), damit Schrift lesbar bleibt")


def _load_pipeline() -> TripoSGPipeline:
    global _pipe
    if _pipe is None:
        if not (MODEL_DIR / "transformer").exists():
            raise RuntimeError(f"Modell nicht gefunden unter {MODEL_DIR}")
        _pipe = TripoSGPipeline.from_pretrained(str(MODEL_DIR)).to(_device, _dtype)
    return _pipe


def _segment_background(img: Image.Image, tolerance: int = 28) -> Image.Image:
    """Stellt ein Bild ohne Alphakanal frei.

    Bewusst kein RMBG-Modell: dessen Lizenz ist nicht-kommerziell, was den
    Lizenzvorteil von TripoSG (MIT) zunichtemachen wuerde. Stattdessen ein
    Flood-Fill von den Bildraendern -- ausreichend fuer generierte Assets mit
    ruhigem Hintergrund, wofuer dieser Pfad gedacht ist.
    """
    from collections import deque

    rgb = np.asarray(img.convert("RGB"), dtype=np.int16)
    h, w = rgb.shape[:2]

    # Referenzfarbe aus den vier Ecken (Median gegen Ausreisser)
    corners = np.stack([rgb[0, 0], rgb[0, w - 1], rgb[h - 1, 0], rgb[h - 1, w - 1]])
    ref = np.median(corners, axis=0)

    similar = (np.abs(rgb - ref).max(axis=2) <= tolerance)

    # Nur vom Rand zusammenhaengende Flaechen entfernen -- gleichfarbige
    # Bereiche im Objektinneren bleiben so erhalten.
    bg = np.zeros((h, w), dtype=bool)
    queue: deque[tuple[int, int]] = deque()
    for x in range(w):
        for y in (0, h - 1):
            if similar[y, x] and not bg[y, x]:
                bg[y, x] = True
                queue.append((y, x))
    for y in range(h):
        for x in (0, w - 1):
            if similar[y, x] and not bg[y, x]:
                bg[y, x] = True
                queue.append((y, x))

    while queue:
        y, x = queue.popleft()
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < h and 0 <= nx < w and similar[ny, nx] and not bg[ny, nx]:
                bg[ny, nx] = True
                queue.append((ny, nx))

    if bg.mean() > 0.95:  # alles als Hintergrund erkannt -> Heuristik versagt
        return img.convert("RGBA")

    alpha = np.where(bg, 0, 255).astype(np.uint8)
    out = np.dstack([np.asarray(img.convert("RGB")), alpha])
    return Image.fromarray(out, mode="RGBA")


def _prepare(path: Path, remove_bg: bool) -> Image.Image:
    img = Image.open(path)
    has_alpha = img.mode in ("RGBA", "LA") and np.asarray(img.split()[-1]).min() < 250
    if has_alpha:
        img = img.convert("RGBA")
    elif remove_bg:
        img = _segment_background(img)
    else:
        img = img.convert("RGBA")

    # Auf den sichtbaren Bereich zuschneiden und quadratisch einbetten --
    # TripoSG erwartet ein zentriertes, formatfuellendes Objekt.
    alpha = np.asarray(img.split()[-1])
    ys, xs = np.nonzero(alpha > 10)
    if len(ys) and len(xs):
        img = img.crop((int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1))

    side = int(max(img.size) * 1.1)
    canvas = Image.new("RGBA", (side, side), (255, 255, 255, 0))
    canvas.paste(img, ((side - img.width) // 2, (side - img.height) // 2), img)
    return canvas


def _simplify(mesh: trimesh.Trimesh, target_faces: int) -> trimesh.Trimesh:
    if target_faces <= 0 or mesh.faces.shape[0] <= target_faces:
        return mesh
    try:
        import pymeshlab

        ms = pymeshlab.MeshSet()
        ms.add_mesh(pymeshlab.Mesh(vertex_matrix=mesh.vertices, face_matrix=mesh.faces))
        ms.meshing_decimation_quadric_edge_collapse(targetfacenum=target_faces)
        m = ms.current_mesh()
        return trimesh.Trimesh(vertices=m.vertex_matrix(), faces=m.face_matrix())
    except Exception:
        # Reduktion ist Komfort, kein Muss -- lieber das volle Mesh liefern.
        return mesh


@app.get("/health")
def health() -> dict[str, Any]:
    vram = None
    if torch.cuda.is_available():
        free, total = torch.cuda.mem_get_info()
        vram = {"free_mb": round(free / 1024**2), "total_mb": round(total / 1024**2)}
    return {
        "ok": True,
        "loaded": _pipe is not None,
        "device": _device,
        "flash_decoder": HAS_DISO,
        "model_dir": str(MODEL_DIR),
        "model_present": (MODEL_DIR / "transformer").exists(),
        "vram": vram,
    }


@app.post("/unload")
def unload() -> dict[str, bool]:
    """Gibt den VRAM frei, damit ComfyUI wieder Platz hat."""
    global _pipe
    _pipe = None
    gc.collect()
    if torch.cuda.is_available():
        torch.cuda.empty_cache()
    return {"ok": True}


@app.post("/generate")
def generate(req: GenerateRequest) -> dict[str, Any]:
    src = Path(req.image_path)
    if not src.exists():
        raise HTTPException(400, f"Bild nicht gefunden: {src}")

    started = time.time()
    try:
        pipe = _load_pipeline()
    except Exception as exc:
        raise HTTPException(500, f"Modell laden fehlgeschlagen: {exc}") from exc

    image = _prepare(src, req.remove_background)

    generator = None
    if req.seed is not None:
        generator = torch.Generator(device=_device).manual_seed(int(req.seed))

    try:
        outputs = pipe(
            image=image,
            num_inference_steps=req.num_inference_steps,
            guidance_scale=req.guidance_scale,
            generator=generator,
            use_flash_decoder=HAS_DISO,
        ).samples[0]
    except Exception as exc:
        raise HTTPException(500, f"Generierung fehlgeschlagen: {type(exc).__name__}: {exc}") from exc

    vertices = np.asarray(outputs[0], dtype=np.float32)
    faces = np.ascontiguousarray(outputs[1])
    mesh = trimesh.Trimesh(vertices, faces)
    mesh = _simplify(mesh, req.faces)

    out = Path(req.output_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    # Die Freistellung, die TripoSG gesehen hat, als eigene Datei: daran laesst sich nachvollziehen,
    # was ins Mesh eingegangen ist, und die Projektion der Vorderseite nimmt genau dieses Bild.
    cutout = out.with_name(out.stem + "_cutout.png")
    image.save(cutout)
    projection = None
    if req.project_front:
        from front_projection import project_front

        scene, projection = project_front(mesh, image)
        scene.export(str(out), include_normals=True)
    else:
        mesh.export(str(out))

    return {
        "ok": True,
        "path": str(out),
        "vertices": int(mesh.vertices.shape[0]),
        "faces": int(mesh.faces.shape[0]),
        "seconds": round(time.time() - started, 1),
        "flash_decoder": HAS_DISO,
        "cutout_path": str(cutout),
        "textured": projection is not None,
        "front_projection": projection,
    }


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="127.0.0.1", port=PORT, log_level="info")
