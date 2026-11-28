"""Gesicht nachrechnen (seit 28.11.2026): Werkzeuge für den Auftrag face_fix. Läuft als eigenes Skript im ComfyUI-venv
(OpenCV aus opencv-python-headless < 5 mit Haar-Kaskaden, numpy, Pillow, PyAV); der Server-venv hat sie nicht.

    python face_tools.py detect <bild>
    python face_tools.py prepare <bild> <gesicht-json> <ausschnitt.png> <weich.png>
    python face_tools.py composite <bild> <ergebnis> <ausschnitt.png> <gesicht-json> <ziel.png>
    python face_tools.py frame <video> <sekunden> <breite> <ziel.png>
    python face_tools.py video <video> <schlüsselbild.png> <schlüssel_neu.png> <gesichter-json> <breite> <ziel.mp4>
    python face_tools.py eyes <video> <zeiten-json>

Hintergrund: In 1344 × 768 hatte ein Gesicht ab den Knien rund 105 px,
ein Auge 10 px; das Videomodell rechnet in Einheiten von 32 × 32 px und verlor die Pupillen ab dem ersten Bild, jeder
Seed anders. Hier wird ein Bild mit FLUX 3 und dem Originalfoto neu gemalt (der Server macht den Modelllauf) und dann
in jedem Bild per ECC auf den laufenden Kopf gelegt, mit angeglichenem Licht. Mit „Keep the first image exactly“
übernahm FLUX das schon abweichende Gesicht; deshalb gehen die Gesichtszüge weichgezeichnet ins Modell (prepare), das
Gesicht kommt dann aus dem Foto. Alles ist auf Listen von Gesichtern gebaut, damit später mehrere getauscht werden
können; der Auftrag nimmt vorerst eins.
Ausgabe: eine JSON-Zeile.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

# Mit python -I fehlt der eigene Ordner in sys.path; outpaint_align.py liegt daneben.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from outpaint_align import measure, refine  # noqa: E402

SIDE = 1024          # Arbeitsgröße des Modells für den Kopfausschnitt
CROP = 2.4           # Ausschnitt = 2,4 × Gesichtsbreite (Haar-Box), quadratisch


def detect(path: str | Path) -> list[dict[str, Any]]:
    """Frontale Gesichter, sicherste zuerst: [{x, y, w, h, score}]. Zwei Haar-Kaskaden; Gewicht der letzten Stufe
    statt Größe (große Kästen umfassten Helm und Schultern)."""
    img = cv2.imread(str(path))
    if img is None:
        raise SystemExit(f"Bild nicht lesbar: {path}")
    return _faces(cv2.equalizeHist(cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)))


def _faces(gray: np.ndarray) -> list[dict[str, Any]]:
    """Kern von detect() auf einem ausgeglichenen Graubild."""
    found: list[dict[str, Any]] = []
    for name in ("haarcascade_frontalface_alt2.xml", "haarcascade_frontalface_default.xml"):
        cas = cv2.CascadeClassifier(str(Path(cv2.data.haarcascades) / name))
        min_side = max(24, min(gray.shape) // 40)
        boxes, _, weights = cas.detectMultiScale3(gray, scaleFactor=1.05, minNeighbors=6,
                                                  minSize=(min_side, min_side), outputRejectLevels=True)
        for (x, y, w, h), wt in zip(boxes, np.ravel(weights) if len(boxes) else []):
            found.append({"x": int(x), "y": int(y), "w": int(w), "h": int(h), "score": round(float(wt), 3)})
        if found:
            break
    # sich überlappende Kästen zusammenfassen: der sicherste bleibt
    found.sort(key=lambda f: -f["score"])
    keep: list[dict[str, Any]] = []
    for f in found:
        cx, cy = f["x"] + f["w"] / 2, f["y"] + f["h"] / 2
        if all(abs(cx - (k["x"] + k["w"] / 2)) > k["w"] * 0.5 or abs(cy - (k["y"] + k["h"] / 2)) > k["h"] * 0.5
               for k in keep):
            keep.append(f)
    return keep


def _eye_pair(gray: np.ndarray, face: dict[str, Any]) -> tuple[float, float, float] | None:
    """Augenmitte (x, y) und Augenabstand im Gesicht `face`: Augen-Kaskade in den oberen 60 %, als Paar gilt, was
    etwa auf einer Höhe links und rechts der Gesichtsmitte liegt (Gesichtskästen allein maßen bei Mützen die
    Größe um 26 % falsch, der Augenabstand traf sie auf 4 %)."""
    x, y, w, h = face["x"], face["y"], face["w"], face["h"]
    roi = gray[y:y + int(h * 0.6), x:x + w]
    if roi.size == 0:
        return None
    cas = cv2.CascadeClassifier(str(Path(cv2.data.haarcascades) / "haarcascade_eye.xml"))
    side = max(8, int(w * 0.12))
    found = cas.detectMultiScale(roi, scaleFactor=1.05, minNeighbors=5, minSize=(side, side),
                                 maxSize=(int(w * 0.4), int(w * 0.4)))
    pts = sorted((x + ex + ew / 2, y + ey + eh / 2) for ex, ey, ew, eh in found)
    mid, best = x + w / 2, None
    for i in range(len(pts)):
        for j in range(i + 1, len(pts)):
            a, b = pts[i], pts[j]
            d = b[0] - a[0]
            if 0.25 * w <= d <= 0.65 * w and abs(b[1] - a[1]) < 0.25 * d and a[0] < mid < b[0]:
                off = abs((a[0] + b[0]) / 2 - mid)
                if best is None or off < best[0]:
                    best = (off, ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2, d))
    return best[1] if best else None


def eyes(video: str, times: list[float]) -> dict[str, Any]:
    """Augen je Zeitpunkt (Sekunden Medienzeit) für „Köpfe in der Überblendung angleichen“: je Zeit das Bild, das dort
    beginnt, das Gesicht nahe dem vorigen (anfangs das sicherste), darin Augenmitte und -abstand. Koordinaten in
    Pixeln des Videos. {width, height, fps, frames: [{t, face, eyes: [x, y, abstand] | null}]}."""
    import av
    want = sorted(float(v) for v in times)
    frames: list[dict[str, Any]] = []
    last = None
    with av.open(video) as c:
        st = c.streams.video[0]
        fps = float(st.average_rate or 24)
        width, height = st.codec_context.width, st.codec_context.height
        i = 0
        for fr in c.decode(video=0):
            if i >= len(want):
                break
            ft = float(fr.time or 0.0)
            while i < len(want) and ft >= want[i] - 0.5 / fps:
                gray = cv2.equalizeHist(cv2.cvtColor(fr.to_ndarray(format="bgr24"), cv2.COLOR_BGR2GRAY))
                # Vorrang: Gesichter mit Augenpaar; anfangs das größte (die sicherste Haar-Erkennung war im
                # Test-Clip ein Licht im Hintergrund, 89 statt 229 px), danach das dem vorigen nächste
                cands = [(f, _eye_pair(gray, f)) for f in _faces(gray)]
                pool = [c for c in cands if c[1]] or cands
                if last is None:
                    pool.sort(key=lambda c: -c[0]["w"])
                else:
                    pool.sort(key=lambda c: abs(c[0]["x"] + c[0]["w"] / 2 - last[0])
                              + abs(c[0]["y"] + c[0]["h"] / 2 - last[1]))
                face, pair = pool[0] if pool else (None, None)
                if face:
                    last = (face["x"] + face["w"] / 2, face["y"] + face["h"] / 2)
                frames.append({"t": want[i], "face": face, "eyes": [round(v, 2) for v in pair] if pair else None})
                i += 1
    return {"width": width, "height": height, "fps": fps, "frames": frames}


def crop_box(face: dict[str, Any], size: tuple[int, int]) -> tuple[int, int, int]:
    W, H = size
    side = min(min(W, H), int(round(max(face["w"], face["h"]) * CROP)))
    cx, cy = face["x"] + face["w"] / 2, face["y"] + face["h"] * 0.55
    x0 = max(0, min(W - side, int(round(cx - side / 2))))
    y0 = max(0, min(H - side, int(round(cy - side / 2))))
    return x0, y0, side


def prepare(image: str, face: dict[str, Any], crop_out: str, soft_out: str) -> dict[str, Any]:
    """Kopfausschnitt auf SIDE vergrößert, dazu eine Fassung mit weichgezeichneten Gesichtszügen fürs Modell."""
    orig = Image.open(image).convert("RGB")
    x0, y0, side = crop_box(face, orig.size)
    crop = orig.crop((x0, y0, x0 + side, y0 + side)).resize((SIDE, SIDE), Image.LANCZOS)
    crop.save(crop_out)
    sc = SIDE / side
    cx, cy = (face["x"] + face["w"] / 2 - x0) * sc, (face["y"] + face["h"] / 2 - y0) * sc
    rx, ry = face["w"] * 0.36 * sc, face["h"] * 0.42 * sc
    mask = Image.new("L", (SIDE, SIDE), 0)
    ImageDraw.Draw(mask).ellipse((cx - rx, cy - ry, cx + rx, cy + ry), fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(face["w"] * 0.08 * sc))
    Image.composite(crop.filter(ImageFilter.GaussianBlur(face["w"] * 0.10 * sc)), crop, mask).save(soft_out)
    return {"box": [x0, y0, side]}


def composite(image: str, result: str, crop_path: str, face: dict[str, Any], out: str) -> dict[str, Any]:
    """Ergebnis des Modells am unveränderten Ausschnitt ausrichten und mit weicher Ellipse einsetzen; außerhalb bleibt
    jedes Pixel."""
    orig = Image.open(image).convert("RGB")
    x0, y0, side = crop_box(face, orig.size)
    crop = Image.open(crop_path).convert("RGB")
    res = Image.open(result).convert("RGB").resize((SIDE, SIDE), Image.LANCZOS)
    s, px, py, v = measure(res, crop, 0, 0)
    s, px, py, v = refine(res, crop, s, px, py)
    aligned = res.transform((SIDE, SIDE), Image.AFFINE, (s, 0, px, 0, s, py), resample=Image.BICUBIC)
    small = aligned.resize((side, side), Image.LANCZOS)
    cx, cy = face["x"] + face["w"] / 2 - x0, face["y"] + face["h"] * 0.62 - y0
    rx, ry = face["w"] * 0.62, face["h"] * 0.80
    mask = Image.new("L", (side, side), 0)
    ImageDraw.Draw(mask).ellipse((cx - rx, cy - ry, cx + rx, cy + ry), fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(max(2.0, face["w"] * 0.07)))
    region = orig.crop((x0, y0, x0 + side, y0 + side))
    orig.paste(Image.composite(small, region, mask), (x0, y0))
    orig.save(out)
    return {"scale": round(float(s), 4), "dx": round(float(px), 1), "dy": round(float(py), 1), "ncc": round(float(v), 4)}


def _size(w: int, h: int, width: int) -> tuple[int, int]:
    """Arbeitsbreite: kleinere Videos auf `width` vergrößern (Lanczos; das Gesicht bekommt mehr Pixel), größere bleiben."""
    if width and w < width:
        return width, int(round(h * width / w / 2)) * 2
    return w, h


def frame(video: str, seconds: float, width: int, out: str) -> dict[str, Any]:
    import av
    with av.open(video) as c:
        st = c.streams.video[0]
        fps = float(st.average_rate or 24)
        pick, n = None, 0
        for fr in c.decode(video=0):
            pick = fr
            if fr.time is not None and fr.time >= seconds - 0.5 / fps:
                break
            n += 1
        if pick is None:
            raise SystemExit("Video ohne Bild")
        img = pick.to_image()
        W, H = _size(img.width, img.height, width)
        if (W, H) != img.size:
            img = img.resize((W, H), Image.LANCZOS)
        img.save(out)
        return {"frame": n, "time": pick.time, "width": W, "height": H, "fps": fps}


def video(src: str, key_png: str, key_fixed_png: str, faces: list[dict[str, Any]], width: int, out: str) -> dict[str, Any]:
    """Jedes Gesicht des Schlüsselbilds (Liste, vorerst eins) per ECC über alle Bilder verfolgen und die nachgerechnete
    Fassung mit derselben affinen Abbildung einsetzen; Licht über den Lab-Mittelwert (wie hat sich das Originalgesicht
    gegenüber dem Schlüsselbild verändert); weicher Rand. Ton bleibt (neu kodiert als AAC)."""
    import av
    key = cv2.imread(key_png)
    fixed = cv2.imread(key_fixed_png)
    if key is None or fixed is None or key.shape != fixed.shape:
        raise SystemExit("Schlüsselbild fehlt oder hat eine andere Größe")
    H, W = key.shape[:2]
    tracks = []
    for f in faces:
        fx, fy, fw, fh = f["x"], f["y"], f["w"], f["h"]
        t0 = (fx + int(fw * 0.15), fy + int(fh * 0.12), fx + int(fw * 0.85), fy + int(fh * 0.92))
        p0 = (max(0, fx - int(fw * 0.35)), max(0, fy - int(fh * 0.35)),
              min(W, fx + fw + int(fw * 0.35)), min(H, fy + fh + int(fh * 0.35)))
        mask = np.zeros((p0[3] - p0[1], p0[2] - p0[0]), np.float32)
        cv2.ellipse(mask, (fx + fw // 2 - p0[0], fy + fh // 2 - p0[1]), (int(fw * 0.31), int(fh * 0.40)), 0, 0, 360,
                    1.0, -1)
        mask = cv2.GaussianBlur(mask, (0, 0), max(1.0, fw * 0.07))
        tracks.append({
            "tmpl": cv2.cvtColor(key, cv2.COLOR_BGR2GRAY)[t0[1]:t0[3], t0[0]:t0[2]].astype(np.float32),
            "fix": fixed[p0[1]:p0[3], p0[0]:p0[2]].astype(np.float32),
            "key": key[p0[1]:p0[3], p0[0]:p0[2]].astype(np.float32), "mask": mask,
            "d": np.array([p0[0] - t0[0], p0[1] - t0[1]], np.float64), "t0": t0, "face": f,
            "start": np.array([[1, 0, t0[0]], [0, 1, t0[1]]], np.float32)})

    def color_frames():
        """Zweiter Durchgang: Farbbilder einzeln (bei 15 s in 1080p sonst über 2 GB im Speicher)."""
        with av.open(src) as cc:
            for fr in cc.decode(video=0):
                arr = fr.to_ndarray(format="bgr24")
                if arr.shape[1] != W or arr.shape[0] != H:
                    arr = cv2.resize(arr, (W, H), interpolation=cv2.INTER_LANCZOS4)
                yield arr

    # Erster Durchgang: nur Graustufen für die Verfolgung und eine kleine Fassung zum Finden des Schlüsselbilds
    grays: list[np.ndarray] = []
    diffs: list[float] = []
    key_small = cv2.resize(key, (160, 90)).astype(np.float32)
    audio: list[Any] = []
    with av.open(src) as c:
        vst = c.streams.video[0]
        fps = vst.average_rate or 24
        has_audio = bool(c.streams.audio)
    for arr in color_frames():
        grays.append(cv2.cvtColor(arr, cv2.COLOR_BGR2GRAY))
        diffs.append(float(np.abs(cv2.resize(arr, (160, 90)).astype(np.float32) - key_small).mean()))
    if has_audio:
        with av.open(src) as c:
            audio = list(c.decode(audio=0))
    crit = (cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT, 80, 1e-5)
    # Schlüsselbild im Video finden (das ähnlichste Bild), von dort vor- und rückwärts verfolgen
    ki = int(np.argmin(diffs))
    misses = 0
    for tr in tracks:
        warps: list[np.ndarray | None] = [None] * len(grays)

        def track(i: int, init: np.ndarray) -> np.ndarray:
            nonlocal misses
            g = grays[i].astype(np.float32)
            try:
                cc, w = cv2.findTransformECC(tr["tmpl"], g, init.copy(), cv2.MOTION_AFFINE, crit, None, 5)
                if cc > 0.6:
                    return w
            except cv2.error:
                pass
            misses += 1
            return init

        warps[ki] = track(ki, tr["start"])
        for i in range(ki + 1, len(grays)):
            warps[i] = track(i, warps[i - 1])
        for i in range(ki - 1, -1, -1):
            warps[i] = track(i, warps[i + 1])
        tr["warps"] = warps
    n_frames = len(grays)
    grays.clear()

    out_c = av.open(out, "w", options={"movflags": "+faststart"})
    vs = out_c.add_stream("libx264", rate=fps)
    vs.width, vs.height, vs.pix_fmt = W, H, "yuv420p"
    vs.options = {"crf": "12", "preset": "medium"}
    # Tonspur vor dem ersten Paket anlegen (danach lehnt der Container neue Spuren ab)
    ast = out_c.add_stream("aac", rate=audio[0].sample_rate) if audio else None
    ones = None
    for i, f in enumerate(color_frames()):
        if i >= n_frames:
            break
        o = f.astype(np.float32)
        for tr in tracks:
            w = tr["warps"][i]
            a, b = w[:, :2].astype(np.float64), w[:, 2].astype(np.float64)
            pw = np.hstack([a, (a @ tr["d"] + b)[:, None]]).astype(np.float32)
            wf = cv2.warpAffine(tr["fix"], pw, (W, H), flags=cv2.INTER_CUBIC, borderMode=cv2.BORDER_REPLICATE)
            wk = cv2.warpAffine(tr["key"], pw, (W, H), flags=cv2.INTER_CUBIC, borderMode=cv2.BORDER_REPLICATE)
            m = cv2.warpAffine(tr["mask"], pw, (W, H), flags=cv2.INTER_LINEAR)
            if ones is None or ones.shape != tr["mask"].shape:
                ones = np.ones_like(tr["mask"])
            m *= cv2.warpAffine(ones, pw, (W, H), flags=cv2.INTER_NEAREST)
            sel = m > 0.5
            if sel.any():
                lab_f = cv2.cvtColor(np.clip(o, 0, 255).astype(np.uint8), cv2.COLOR_BGR2LAB).astype(np.float32)
                lab_k = cv2.cvtColor(np.clip(wk, 0, 255).astype(np.uint8), cv2.COLOR_BGR2LAB).astype(np.float32)
                lab_x = cv2.cvtColor(np.clip(wf, 0, 255).astype(np.uint8), cv2.COLOR_BGR2LAB).astype(np.float32)
                lab_x += lab_f[sel].mean(axis=0) - lab_k[sel].mean(axis=0)
                wf = cv2.cvtColor(np.clip(lab_x, 0, 255).astype(np.uint8), cv2.COLOR_LAB2BGR).astype(np.float32)
            o = o * (1 - m[..., None]) + wf * m[..., None]
        vf = av.VideoFrame.from_ndarray(np.clip(o + 0.5, 0, 255).astype(np.uint8), format="bgr24")
        for pkt in vs.encode(vf):
            out_c.mux(pkt)
    for pkt in vs.encode():
        out_c.mux(pkt)
    if ast is not None:
        for af in audio:
            af.pts = None
            for pkt in ast.encode(af):
                out_c.mux(pkt)
        for pkt in ast.encode():
            out_c.mux(pkt)
    out_c.close()
    return {"frames": n_frames, "width": W, "height": H, "fps": float(fps), "key_frame": ki,
            "faces": len(tracks), "track_misses": misses}


def main(argv: list[str]) -> None:
    cmd = argv[0] if argv else ""
    if cmd == "detect" and len(argv) == 2:
        result: Any = {"faces": detect(argv[1])}
    elif cmd == "prepare" and len(argv) == 5:
        result = prepare(argv[1], json.loads(argv[2]), argv[3], argv[4])
    elif cmd == "composite" and len(argv) == 6:
        result = composite(argv[1], argv[2], argv[3], json.loads(argv[4]), argv[5])
    elif cmd == "frame" and len(argv) == 5:
        result = frame(argv[1], float(argv[2]), int(argv[3]), argv[4])
    elif cmd == "video" and len(argv) == 7:
        result = video(argv[1], argv[2], argv[3], json.loads(argv[4]), int(argv[5]), argv[6])
    elif cmd == "eyes" and len(argv) == 3:
        result = eyes(argv[1], json.loads(argv[2]))
    else:
        raise SystemExit(__doc__)
    print(json.dumps(result))


if __name__ == "__main__":
    main(sys.argv[1:])
