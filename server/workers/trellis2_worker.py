"""TRELLIS.2-Worker: Bild -> Mesh mit PBR-Texturen (GLB).

Eigener Prozess und eigenes venv, weil TRELLIS.2 sechs selbst kompilierte
CUDA-Extensions braucht (o_voxel, cumesh, flex_gemm, nvdiffrast, nvdiffrec,
flash_attn), die gegen genau eine torch-Version gelinkt sind.

Unterschied zu TripoSG: liefert Albedo, Normal und Roughness/Metallic als echte
Bitmaps, nicht nur Geometrie.

Konfiguration ueber die Umgebung:
    TRELLIS2_ROOT   geklontes TRELLIS.2-Repo (Python-Package)
    TRELLIS2_MODEL  Modellordner mit pipeline.json und ckpts/
    TRELLIS2_PORT   Port (Standard 8201)
"""
from __future__ import annotations

import gc
import os
import sys
import time
from pathlib import Path
from typing import Any

os.environ.setdefault("OPENCV_IO_ENABLE_OPENEXR", "1")
os.environ.setdefault("ATTN_BACKEND", "flash_attn")

import numpy as np
import torch
from fastapi import FastAPI, HTTPException
from PIL import Image
from pydantic import BaseModel, Field

ROOT = Path(os.environ.get("TRELLIS2_ROOT", "")).resolve()
MODEL_DIR = Path(os.environ.get("TRELLIS2_MODEL", "")).resolve()
PORT = int(os.environ.get("TRELLIS2_PORT", "8201"))

if not ROOT.exists():
    raise SystemExit(f"TRELLIS2_ROOT fehlt: {ROOT}")
sys.path.insert(0, str(ROOT))

from trellis2.pipelines import Trellis2ImageTo3DPipeline  # noqa: E402

app = FastAPI(title="NVAI-open TRELLIS.2-Worker")

_pipeline: Trellis2ImageTo3DPipeline | None = None
_device = "cuda" if torch.cuda.is_available() else "cpu"


class GenerateRequest(BaseModel):
    image_path: str
    output_path: str
    resolution: int = Field(512, description="512 oder 1024; 1024 sprengt 16 GB VRAM")
    texture_size: int = Field(2048, ge=512, le=4096)
    faces: int = Field(100_000, description="Zielanzahl Dreiecke nach Dezimierung")
    seed: int | None = None
    remove_background: bool = True
    background_mode: str = Field(
        "birefnet",
        description="birefnet (Segmentierungsmodell, sauberste Kanten) | "
                    "flood (Randfarben-Fuellung, schnell) | alpha (Bild bringt Alpha mit)",
    )
    clean_specks: bool = Field(
        True,
        description="Die schwarzen Nadeln entfernen: langgestreckte Splitterkoerper "
                    "aus der Voxel-Stufe. Gemessen an einem Sphinx-Mesh: 2364 von "
                    "2601 Komponenten entfernt, dabei 21 % der Faces -- der "
                    "Hauptkoerper (77 %) bleibt unangetastet.",
    )
    speck_ratio: float = Field(
        0.02, ge=0.0, le=0.5,
        description="Komponenten unter diesem Anteil der groessten Flaeche fliegen raus",
    )


# Meta gibt DINOv3 nur nach manueller Freigabe heraus; diese Spiegelung ist
# frei zugaenglich und inhaltsgleich.
DINOV3_MIRROR = "camenduru/dinov3-vitl16-pretrain-lvd1689m"
# BiRefNet statt briaai/RMBG-2.0: gleiche Architektur, aber MIT statt gated
# und nicht-kommerziell.
BIREFNET_MIT = "ZhengPeng7/BiRefNet"


def _adapt_config(cfg_path: Path) -> list[str]:
    """Passt die pipeline.json an eine 16-GB-Karte an. Gibt die Aenderungen zurueck.

    Drei Punkte:
    1. Teilmodelle ohne lokale Datei entfernen -- die Pipeline laedt sonst stur
       alles aus der Config, auch die 1024er-Varianten, und scheitert am 401.
    2. default_pipeline_type auf '512'; ab Werk steht dort '1024_cascade',
       was die fehlenden 1024er-Modelle braucht.
    3. Den gated DINOv3-Encoder auf eine freie Spiegelung umbiegen.
    """
    import json

    # Immer vom Original ausgehen: eine frueher angepasste Fassung kann Eintraege
    # verloren haben, deren Datei erst spaeter dazukam.
    backup = cfg_path.with_suffix(".json.orig")
    original = cfg_path.read_text(encoding="utf-8")
    cfg = json.loads(backup.read_text(encoding="utf-8") if backup.exists() else original)
    args = cfg.setdefault("args", {})
    changes: list[str] = []

    models = args.get("models", {})
    for key, rel in list(models.items()):
        if (MODEL_DIR / f"{rel}.safetensors").exists():
            continue
        # Verweise in ein anderes Repo ("microsoft/TRELLIS-image-large/ckpts/ss_dec_...",
        # der Sparse-Structure-Decoder): der Katalog legt die Datei nach ckpts/.
        local = "/".join(rel.split("/")[2:])
        if local and (MODEL_DIR / f"{local}.safetensors").exists():
            models[key] = local
            changes.append(f"{key}=lokal")
        else:
            models.pop(key)
            changes.append(f"-{key}")

    if args.get("default_pipeline_type") != "512":
        args["default_pipeline_type"] = "512"
        changes.append("pipeline_type=512")

    cond = args.get("image_cond_model", {}).get("args", {})
    if cond.get("model_name", "").startswith("facebook/"):
        cond["model_name"] = DINOV3_MIRROR
        changes.append(f"dinov3={DINOV3_MIRROR}")

    # briaai/RMBG-2.0 ist gated UND nicht-kommerziell -- das wuerde den MIT-Vorteil
    # von TRELLIS.2 aufheben. BiRefNet ist dieselbe Architektur unter MIT.
    # (Der Worker stellt ohnehin selbst frei und uebergibt RGBA mit echtem Alpha,
    # das Modell wird also im Normalfall gar nicht benutzt -- die Pipeline
    # verlangt den Config-Eintrag aber zwingend.)
    rembg = args.get("rembg_model", {}).get("args", {})
    if rembg.get("model_name", "").startswith("briaai/"):
        rembg["model_name"] = BIREFNET_MIT
        changes.append(f"rembg={BIREFNET_MIT}")

    if changes:
        if not backup.exists():
            backup.write_text(original, encoding="utf-8")
        cfg_path.write_text(json.dumps(cfg, indent=4), encoding="utf-8")
    return changes


def _load() -> Trellis2ImageTo3DPipeline:
    """Laedt die Pipeline. Muss aus dem Modellordner heraus geschehen:
    models.from_pretrained prueft os.path.exists relativ zum Arbeitsverzeichnis
    und haelt relative Pfade sonst faelschlich fuer HuggingFace-Repos."""
    global _pipeline
    if _pipeline is None:
        cfg = MODEL_DIR / "pipeline.json"
        if not cfg.exists():
            raise RuntimeError(f"pipeline.json fehlt in {MODEL_DIR}")
        changes = _adapt_config(cfg)
        if changes:
            print(f"[TRELLIS.2] Config angepasst: {changes}", flush=True)
        cwd = os.getcwd()
        try:
            os.chdir(MODEL_DIR)
            _pipeline = Trellis2ImageTo3DPipeline.from_pretrained(str(MODEL_DIR))
            _pipeline.cuda()
        finally:
            os.chdir(cwd)
    return _pipeline


def _segment_background(img: Image.Image, tolerance: int = 28) -> Image.Image:
    """Freistellen per Flood-Fill vom Bildrand.

    Bewusst kein RMBG-Modell: dessen Lizenz ist nicht-kommerziell und wuerde den
    MIT-Vorteil von TRELLIS.2 aufheben.
    """
    from collections import deque

    rgb = np.asarray(img.convert("RGB"), dtype=np.int16)
    h, w = rgb.shape[:2]
    corners = np.stack([rgb[0, 0], rgb[0, w - 1], rgb[h - 1, 0], rgb[h - 1, w - 1]])
    similar = np.abs(rgb - np.median(corners, axis=0)).max(axis=2) <= tolerance

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

    if bg.mean() > 0.95:
        return img.convert("RGBA")
    alpha = np.where(bg, 0, 255).astype(np.uint8)
    return Image.fromarray(np.dstack([np.asarray(img.convert("RGB")), alpha]), mode="RGBA")


def _prepare(path: Path, remove_bg: bool, mode: str) -> Image.Image:
    """Bereitet das Eingangsbild vor.

    Wichtig fuer die Mesh-Qualitaet: Bleibt Hintergrund stehen, baut TRELLIS.2
    ihn als Geometrie mit -- das sind die typischen duennen Saeulen und Striche.

    mode='birefnet' gibt das Bild OHNE Alpha weiter; preprocess_image der
    Pipeline erkennt das und segmentiert selbst mit BiRefNet. Das liefert
    deutlich sauberere Kanten als unser Flood-Fill, der nur zusammenhaengende
    Randflaechen aehnlicher Farbe entfernt.
    """
    img = Image.open(path)
    has_alpha = img.mode in ("RGBA", "LA") and np.asarray(img.split()[-1]).min() < 250

    if has_alpha:
        img = img.convert("RGBA")  # vorhandenes Alpha schlaegt jeden Modus
    elif mode == "flood" and remove_bg:
        img = _segment_background(img)
    else:
        # birefnet, oder 'alpha' bei einem Bild ohne Alphakanal: RGB durchreichen,
        # die Pipeline stellt selbst frei.
        #
        # Wichtig: Hier NICHT nach RGBA wandeln und aufs Canvas legen. Der dabei
        # entstehende transparente Rand liesse die Pipeline "hat schon Alpha"
        # schliessen -- sie wuerde nicht mehr freistellen und der komplette
        # Hintergrund landete im Mesh.
        if mode == "alpha":
            print("[TRELLIS.2] background_mode=alpha, aber das Bild hat keinen "
                  "Alphakanal -- stelle stattdessen selbst frei", flush=True)
        return img.convert("RGB")

    alpha = np.asarray(img.split()[-1])
    ys, xs = np.nonzero(alpha > 10)
    if len(ys) and len(xs):
        img = img.crop((int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1))
    side = int(max(img.size) * 1.1)
    canvas = Image.new("RGBA", (side, side), (255, 255, 255, 0))
    canvas.paste(img, ((side - img.width) // 2, (side - img.height) // 2), img)
    return canvas


def _remove_specks(
    mesh,
    min_ratio: float,
    max_faces: int = 200,
    min_elongation: float = 4.0,
) -> tuple[object, int]:
    """Entfernt die schwarzen Nadeln aus TRELLIS.2-Ausgaben.

    Was diese Nadeln wirklich sind: Die Voxel-Stufe erzeugt entlang der
    Silhouette ein Voxel breite Streuketten. Das Remeshing huellt jede davon in
    einen eigenen, geschlossenen Koerper; die Dezimierung presst ihn auf wenige
    Dreiecke zusammen. Schwarz erscheinen sie, weil der Textur-Bake an so
    duennen Strukturen fast nur leere Nachbarvoxel interpoliert.

    Zwei Kriterien, die frueher falsch gewaehlt waren:

    1. VERSCHWEISSEN VOR DER ANALYSE. trimesh trennt Vertices an UV-Naehten.
       Ohne merge_vertices zerfaellt ein Mesh in tausende Chart-Fragmente statt
       in seine echten Koerper -- der "groesste Teil" waere dann ein einzelnes
       UV-Chart mit einem halben Prozent der Flaeche, und jeder Groessenvergleich
       ginge ins Leere.

    2. FORM STATT ABSTAND. Ein Abstandskriterium versagt hier grundsaetzlich:
       Nadeln ragen aus dem Koerper heraus, ihre Bounding-Box ueberlappt seine,
       der Abstand ist null. Entscheidend ist die Gestalt -- Nadeln sind extrem
       langgestreckt (Median 32:1), echte Kleinteile wie Augen oder Beschlaege
       sind kompakt (etwa 2:1).

    Die Face-Indizes bleiben beim Verschweissen unveraendert, deshalb laesst
    sich die Maske direkt auf das texturierte Originalnetz anwenden.
    """
    import trimesh

    if len(mesh.faces) == 0:
        return mesh, 0

    # Analysekopie mit verschweissten Vertices -- nur fuer die Topologie.
    # merge_tex/merge_norm sind entscheidend: ohne sie bleiben an UV-Naehten
    # getrennte Vertices getrennt, und das Netz zerfaellt in tausende Charts
    # statt in seine echten Koerper (gemessen: 8088 statt 2601).
    probe = mesh.copy()
    try:
        probe.merge_vertices(merge_tex=True, merge_norm=True)
        comps = trimesh.graph.connected_components(probe.face_adjacency, min_len=1)
    except Exception:
        return mesh, 0
    if len(comps) <= 1:
        return mesh, 0

    areas = np.array([mesh.area_faces[c].sum() for c in comps])
    main = int(areas.argmax())
    verts = probe.vertices
    faces = probe.faces
    total_diag = float(np.linalg.norm(mesh.bounding_box.extents)) or 1.0

    keep = np.zeros(len(mesh.faces), dtype=bool)
    keep[comps[main]] = True
    dropped = 0

    for i, comp in enumerate(comps):
        if i == main:
            continue
        v = verts[np.unique(faces[comp])]
        extents = v.max(axis=0) - v.min(axis=0)
        longest = float(extents.max())
        shortest = float(max(extents.min(), total_diag * 1e-5))
        elongation = longest / shortest

        small = len(comp) <= max_faces or areas[i] < areas[main] * min_ratio
        if small and elongation >= min_elongation:
            dropped += 1          # langgestreckter Splitter -> weg
        else:
            keep[comp] = True     # kompakt oder gross -> gehoert zum Objekt

    if dropped == 0:
        return mesh, 0

    mesh.update_faces(keep)
    mesh.remove_unreferenced_vertices()
    return mesh, dropped


@app.get("/health")
def health() -> dict[str, Any]:
    vram = None
    if torch.cuda.is_available():
        free, total = torch.cuda.mem_get_info()
        vram = {"free_mb": round(free / 1024**2), "total_mb": round(total / 1024**2)}
    return {
        "ok": True,
        "loaded": _pipeline is not None,
        "device": _device,
        "model_dir": str(MODEL_DIR),
        "model_present": (MODEL_DIR / "pipeline.json").exists(),
        "vram": vram,
    }


@app.post("/unload")
def unload() -> dict[str, bool]:
    global _pipeline
    _pipeline = None
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
        pipeline = _load()
    except Exception as exc:
        raise HTTPException(500, f"Modell laden fehlgeschlagen: {exc}") from exc

    image = _prepare(src, req.remove_background, req.background_mode)
    if req.seed is not None:
        torch.manual_seed(int(req.seed))

    # Das freigestellte Bild mit ECHTER Transparenz ablegen (RGBA, Alpha=0 im
    # Hintergrund). Es dient nicht nur der Sichtkontrolle, sondern laesst sich
    # direkt als Quellbild wiederverwenden -- dann greift background_mode='alpha'
    # und es wird kein zweites Mal freigestellt.
    cutout_path = Path(req.output_path).with_name(Path(req.output_path).stem + "_cutout.png")
    try:
        preview = image
        if preview.mode != "RGBA":
            rembg = getattr(pipeline, "rembg_model", None)
            if rembg is not None:
                # Die Pipeline laeuft im Low-VRAM-Modus und parkt Modelle
                # zwischendurch auf der CPU -- der Wrapper schickt seinen Input
                # aber immer nach CUDA.
                rembg.to("cuda")
                preview = rembg(preview.copy())
        preview.convert("RGBA").save(cutout_path)
    except Exception as exc:  # Vorschau ist Beiwerk, kein Grund zum Abbruch
        print(f"[TRELLIS.2] Freistell-Vorschau fehlgeschlagen: {exc}", flush=True)
        cutout_path = None

    try:
        # Die API heisst pipeline_type ('512', '1024', '1024_cascade'), nicht resolution.
        mesh = pipeline.run(image, pipeline_type=str(req.resolution))[0]
    except torch.cuda.OutOfMemoryError as exc:
        torch.cuda.empty_cache()
        raise HTTPException(
            507, f"VRAM reicht nicht fuer resolution={req.resolution}. Mit 512 versuchen."
        ) from exc
    except Exception as exc:
        raise HTTPException(500, f"Generierung fehlgeschlagen: {type(exc).__name__}: {exc}") from exc

    gen_s = time.time() - started

    import o_voxel

    out = Path(req.output_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    glb = o_voxel.postprocess.to_glb(
        vertices=mesh.vertices,
        faces=mesh.faces,
        attr_volume=mesh.attrs,
        coords=mesh.coords,
        attr_layout=mesh.layout,
        voxel_size=mesh.voxel_size,
        aabb=[[-0.5, -0.5, -0.5], [0.5, 0.5, 0.5]],
        decimation_target=req.faces,
        texture_size=req.texture_size,
        remesh=True,
        remesh_band=1,
        remesh_project=0,
        verbose=False,
    )
    glb.export(str(out))

    # Nachbearbeitung auf der exportierten Datei: erst hier liegt ein normales
    # Dreiecksnetz vor, auf dem sich Komponenten trennen lassen.
    specks = 0
    final_faces = int(mesh.faces.shape[0])
    if req.clean_specks:
        import trimesh

        scene = trimesh.load(str(out))
        tri = scene.to_geometry() if isinstance(scene, trimesh.Scene) else scene
        tri, specks = _remove_specks(tri, req.speck_ratio)
        if specks:
            # to_glb schreibt Vertex-Normalen mit; trimesh tut das beim Export
            # nicht von sich aus. Ohne sie berechnet der Browser-Viewer eigene
            # und erzeugt dabei Schattierungsartefakte.
            tri.vertex_normals  # erzwingt die Berechnung und legt sie im Cache ab
            tri.export(str(out), include_normals=True)
            final_faces = int(len(tri.faces))
            print(f"[TRELLIS.2] {specks} lose Fragmente entfernt "
                  f"(Normalen neu berechnet)", flush=True)

    return {
        "ok": True,
        "path": str(out),
        "vertices": int(mesh.vertices.shape[0]),
        "faces": final_faces,
        "raw_faces": int(mesh.faces.shape[0]),
        "specks_removed": specks,
        "seconds": round(gen_s, 1),
        "total_seconds": round(time.time() - started, 1),
        "textured": True,
        "texture_size": req.texture_size,
        "resolution": req.resolution,
        "background_mode": req.background_mode,
        "cutout_path": str(cutout_path) if cutout_path else None,
    }


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="127.0.0.1", port=PORT, log_level="info")
