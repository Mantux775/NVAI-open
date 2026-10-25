"""Vorderseite aus dem Bild: projiziert das freigestellte Quellbild auf die Flächen eines Meshes, die zur
Kamera zeigen und sichtbar sind, damit Schrift und Aufkleber lesbar bleiben (Nutzerwunsch 25.10.2026).

Nur numpy, trimesh und Pillow -- läuft im venv jedes 3D-Workers und braucht kein UV-Abwickeln: Die
Vorderseite bekommt planare UV-Koordinaten direkt ins Bild, der übrige Körper Vertexfarben aus dem stark
weichgezeichneten Bild (so landet keine gespiegelte Schrift auf der Rückseite). Ergebnis ist eine Szene mit
zwei Teilen, "front" und "body".

Die Blickachse folgt aus dem Vergleich der Silhouetten (Mesh entlang der Achse gegen die Freistellung);
liegen zwei Achsen gleichauf (symmetrische Form, vorn und hinten spiegelgleich) oder deckt keine sicher
(MIN_IOU), gilt DEFAULT_AXIS.

    python front_projection.py <mesh.glb> <freigestellt.png> <ziel.glb> [--axis +z]
"""
from __future__ import annotations

import argparse
from typing import Any

import numpy as np
import trimesh
from PIL import Image, ImageFilter

# Blickachsen: (rechts, oben, zur Kamera) im Mesh-Koordinatensystem, Y oben
AXES: dict[str, tuple[tuple[float, float, float], ...]] = {
    "+z": ((1, 0, 0), (0, 1, 0), (0, 0, 1)),
    "-z": ((-1, 0, 0), (0, 1, 0), (0, 0, -1)),
    "+x": ((0, 0, -1), (0, 1, 0), (1, 0, 0)),
    "-x": ((0, 0, 1), (0, 1, 0), (-1, 0, 0)),
}
DEFAULT_AXIS = "+z"
FACING = 0.25          # Mindest-Kosinus zwischen Flächennormale und Blickrichtung
GRID = 384             # Raster für Tiefenpuffer und Silhouette
SAMPLES = 600_000      # Oberflächenpunkte für den Tiefenpuffer
TIE = 0.02             # IoU-Abstand, unter dem zwei Achsen als gleichauf gelten
# Darunter passt keine Achse sicher, die Wahl wäre Zufall: Ein Fass mit Bodenresten in der Freistellung kam
# auf 0,52-0,58 für alle vier und landete auf -x statt vorn. Der Wegweiser (saubere Freistellung) hatte 0,93.
MIN_IOU = 0.75
KEEP_PART = 0.25       # lose Teile der Freistellung unter diesem Anteil des größten fallen weg


def _basis(axis: str) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    right, up, toward = (np.asarray(a, dtype=np.float64) for a in AXES[axis])
    return right, up, toward


def _clean_alpha(alpha: np.ndarray) -> np.ndarray:
    """Lose Reste der Freistellung (Bodenflecken, Krümel) entfernen: Sie vergrößern den Rahmen, auf den das
    Mesh gelegt wird. Beim Fass mit Bodenresten war der zweitgrößte Teil ein Bodenfleck mit 12 % der Fläche."""
    try:
        from scipy import ndimage
    except ImportError:  # ohne scipy wie bisher
        return alpha
    labels, count = ndimage.label(alpha)
    if count <= 1:
        return alpha
    sizes = np.bincount(labels.ravel())[1:]
    return np.isin(labels, np.flatnonzero(sizes >= KEEP_PART * sizes.max()) + 1)


def _alpha_box(rgba: np.ndarray) -> tuple[np.ndarray, tuple[int, int, int, int]]:
    alpha = _clean_alpha(rgba[..., 3] > 10)
    ys, xs = np.nonzero(alpha)
    if not len(xs):
        raise ValueError("Freistellung ist leer")
    return alpha, (int(xs.min()), int(xs.max()) + 1, int(ys.min()), int(ys.max()) + 1)


def _silhouette_iou(points: np.ndarray, axis: str, alpha: np.ndarray, box: tuple[int, int, int, int]) -> float:
    """Wie gut deckt sich die Silhouette des Meshes entlang `axis` mit der Freistellung?"""
    right, up, _ = _basis(axis)
    px, py = points @ right, points @ up
    gx = ((px - px.min()) / max(np.ptp(px), 1e-9) * (GRID - 1)).astype(int)
    gy = ((py.max() - py) / max(np.ptp(py), 1e-9) * (GRID - 1)).astype(int)
    sil = np.zeros((GRID, GRID), bool)
    sil[gy, gx] = True
    x0, x1, y0, y1 = box
    ref = Image.fromarray((alpha[y0:y1, x0:x1] * 255).astype(np.uint8)).resize((GRID, GRID), Image.NEAREST)
    ref = np.asarray(ref) > 127
    return float((sil & ref).sum() / max((sil | ref).sum(), 1))


def _dilate_max(a: np.ndarray) -> np.ndarray:
    """3 x 3-Maximum, schließt Lücken im punktweise gefüllten Tiefenpuffer."""
    p = np.pad(a, 1, constant_values=-np.inf)
    return np.max([p[dy:dy + a.shape[0], dx:dx + a.shape[1]] for dy in range(3) for dx in range(3)], axis=0)


def _refine(qx: np.ndarray, qy: np.ndarray, alpha: np.ndarray,
            base: tuple[float, float, float, float, int, int]) -> tuple[float, float, float, float]:
    """Maßstab (je Achse) und Versatz in Pixeln um die Boxmitte, die die Übereinstimmung von Umriss und
    Freistellung erhöhen. Schrittweise Suche auf halber Auflösung, höchstens ±4 % und ±12 px."""
    mx0, my1, sx, sy, bx0, by0 = base
    h, w = alpha.shape
    ys, xs = np.nonzero(alpha)
    cx, cy = (xs.min() + xs.max() + 1) / 2, (ys.min() + ys.max() + 1) / 2
    pcx, pcy = (qx.min() + qx.max()) / 2, (qy.min() + qy.max()) / 2
    keep = np.random.default_rng(0).choice(len(qx), size=min(len(qx), 200_000), replace=False)
    qx, qy = qx[keep], qy[keep]
    small = alpha[::2, ::2]
    hh, ww = small.shape

    def score(f: tuple[float, float, float, float]) -> float:
        ix = ((cx + (qx - pcx) * sx * f[0] + f[2]) / 2).astype(int)
        iy = ((cy + (pcy - qy) * sy * f[1] + f[3]) / 2).astype(int)
        ok = (ix >= 0) & (ix < ww) & (iy >= 0) & (iy < hh)
        m = np.zeros((hh, ww), bool)
        m[iy[ok], ix[ok]] = True
        p = np.pad(m, 1)
        m = np.max([p[a:a + hh, b:b + ww] for a in range(3) for b in range(3)], axis=0)
        return float((m & small).sum() / max((m | small).sum(), 1))

    best = (1.0, 1.0, 0.0, 0.0)
    best_score = score(best)
    for scale_step, px_step in ((0.02, 6.0), (0.01, 3.0), (0.005, 1.5)):
        improved = True
        while improved:
            improved = False
            for i, step in ((0, scale_step), (1, scale_step), (2, px_step), (3, px_step)):
                for sign in (1, -1):
                    cand = list(best)
                    cand[i] += sign * step
                    if not (0.96 <= cand[0] <= 1.04 and 0.96 <= cand[1] <= 1.04
                            and abs(cand[2]) <= 12 and abs(cand[3]) <= 12):
                        continue
                    s = score(tuple(cand))
                    if s > best_score + 1e-4:
                        best, best_score, improved = tuple(cand), s, True
    return best


def project_front(mesh: trimesh.Trimesh, image: Image.Image, axis: str | None = None) -> tuple[trimesh.Scene, dict[str, Any]]:
    rgba = np.asarray(image.convert("RGBA"))
    h, w = rgba.shape[:2]
    alpha, box = _alpha_box(rgba)
    bx0, bx1, by0, by1 = box

    pts, _ = trimesh.sample.sample_surface(mesh, SAMPLES)
    scores = {a: _silhouette_iou(pts, a, alpha, box) for a in AXES}
    if axis is None:
        best = max(scores, key=scores.get)
        sure = scores[best] >= MIN_IOU and scores[best] - scores[DEFAULT_AXIS] >= TIE
        axis = best if sure else DEFAULT_AXIS
    right, up, toward = _basis(axis)

    verts = np.asarray(mesh.vertices, dtype=np.float64)
    px, py, depth = verts @ right, verts @ up, verts @ toward
    mx0, my1 = px.min(), py.max()
    # Box auf Box, dann Feinsuche um die Mitte: Maßstab und Versatz, die den Umriss am besten auf die
    # Freistellung legen (gemessen am Wegweiser: Übereinstimmung 0,936 -> 0,945).
    sx = (bx1 - bx0) / max(np.ptp(px), 1e-9)
    sy = (by1 - by0) / max(np.ptp(py), 1e-9)
    fit = _refine(pts @ right, pts @ up, alpha, (mx0, my1, sx, sy, bx0, by0))
    cx, cy = (bx0 + bx1) / 2, (by0 + by1) / 2
    pcx, pcy = (px.min() + px.max()) / 2, (py.min() + py.max()) / 2
    ix = cx + (px - pcx) * sx * fit[0] + fit[2]     # Bildspalte je Vertex
    iy = cy + (pcy - py) * sy * fit[1] + fit[3]     # Bildzeile je Vertex (Bild-y wächst nach unten)

    # Tiefenpuffer aus Oberflächenpunkten: je Rasterzelle die Tiefe des vordersten Punkts
    qx, qy, qd = pts @ right, pts @ up, pts @ toward
    gx = np.clip(((qx - mx0) / max(np.ptp(px), 1e-9) * (GRID - 1)).astype(int), 0, GRID - 1)
    gy = np.clip(((my1 - qy) / max(np.ptp(py), 1e-9) * (GRID - 1)).astype(int), 0, GRID - 1)
    zbuf = np.full((GRID, GRID), -np.inf)
    np.maximum.at(zbuf, (gy, gx), qd)
    zbuf = _dilate_max(zbuf)

    faces = np.asarray(mesh.faces)
    cen = verts[faces].mean(axis=1)
    cgx = np.clip(((cen @ right - mx0) / max(np.ptp(px), 1e-9) * (GRID - 1)).astype(int), 0, GRID - 1)
    cgy = np.clip(((my1 - cen @ up) / max(np.ptp(py), 1e-9) * (GRID - 1)).astype(int), 0, GRID - 1)
    eps = 0.015 * max(np.ptp(depth), 1e-9)
    visible = cen @ toward >= zbuf[cgy, cgx] - eps
    facing = np.asarray(mesh.face_normals) @ toward > FACING
    front = visible & facing

    # Textur: Freistellung mit der mittleren Vordergrundfarbe hinterlegt (keine grauen Kanten)
    rgb = rgba[..., :3].astype(np.float64)
    med = np.median(rgb[alpha], axis=0)
    rgb[~alpha] = med
    texture = Image.fromarray(rgb.astype(np.uint8))
    blurred = np.asarray(texture.filter(ImageFilter.GaussianBlur(radius=max(4, w // 30)))).astype(np.uint8)

    # Normalen vom ganzen Netz: sonst bekäme jeder Teil an der Naht eigene und die Kante würde sichtbar
    normals = np.asarray(mesh.vertex_normals)

    def part(mask: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
        sel = faces[mask]
        used, inv = np.unique(sel, return_inverse=True)
        return used, verts[used], inv.reshape(-1, 3)

    parts: list[tuple[str, trimesh.Trimesh]] = []

    def add(name: str, used: np.ndarray, geom: trimesh.Trimesh) -> None:
        geom.vertex_normals = normals[used]
        parts.append((name, geom))

    if front.any():
        used, fv, ff = part(front)
        uv = np.column_stack([ix[used] / w, 1.0 - iy[used] / h])
        material = trimesh.visual.material.PBRMaterial(
            name="front", baseColorTexture=texture, metallicFactor=0.0, roughnessFactor=0.85)
        add("front", used, trimesh.Trimesh(fv, ff, process=False,
                                           visual=trimesh.visual.TextureVisuals(uv=uv, material=material)))
    if (~front).any():
        used, rv, rf = part(~front)
        old_uv = getattr(mesh.visual, "uv", None) if getattr(mesh.visual, "kind", None) == "texture" else None
        if old_uv is not None:
            # TRELLIS.2 & Co.: der übrige Körper behält seine eigene Textur
            body_visual: Any = trimesh.visual.TextureVisuals(uv=np.asarray(old_uv)[used],
                                                            material=mesh.visual.material)
            add("body", used, trimesh.Trimesh(rv, rf, process=False, visual=body_visual))
        else:
            vx = np.clip(ix[used].round().astype(int), 0, w - 1)
            vy = np.clip(iy[used].round().astype(int), 0, h - 1)
            rgb_body = blurred[vy, vx].copy()
            # Was nach hinten zeigt, bekommt die mittlere Farbe: Die weichgezeichnete Vorderseite hellte die
            # Rückseite des Wegweisers durch die weiße Schrift auf.
            rgb_body[normals[used] @ toward < -0.3] = med.astype(np.uint8)
            colors = np.column_stack([rgb_body, np.full(len(used), 255, np.uint8)])
            add("body", used, trimesh.Trimesh(rv, rf, process=False, vertex_colors=colors))

    scene = trimesh.Scene()
    for name, geom in parts:
        scene.add_geometry(geom, node_name=name, geom_name=name)
    stats = {"axis": axis, "silhouette_iou": {k: round(v, 3) for k, v in scores.items()},
             "front_faces": int(front.sum()), "faces": int(len(faces)),
             "front_share": round(float(front.mean()), 3), "texture": [w, h],
             "fit": {"scale": [round(fit[0], 3), round(fit[1], 3)], "offset_px": [fit[2], fit[3]]}}
    return scene, stats


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("mesh")
    ap.add_argument("image")
    ap.add_argument("out")
    ap.add_argument("--axis", choices=sorted(AXES), default=None)
    args = ap.parse_args()
    mesh = trimesh.load(args.mesh, force="mesh", process=False)
    scene, stats = project_front(mesh, Image.open(args.image), args.axis)
    scene.export(args.out, include_normals=True)
    print(stats)


if __name__ == "__main__":
    main()
