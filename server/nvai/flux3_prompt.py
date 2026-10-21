"""FLUX 3 Image Klein: Prompt-Upsampler und Bounding-Box-Tabelle.

FLUX 3 ist auf die Bildbeschreibungen trainiert, die sein eigener Upsampler schreibt
(ein von BFL feinjustiertes Qwen3.5-9B). Ein kurzer Prompt, so wie getippt, liefert
laut BFL generische Bilder. Deshalb laeuft vor dem Bild ein eigener ComfyUI-Durchgang,
der die Anfrage zur vollen Bildbeschreibung ausbaut -- getrennt vom Bild-Graphen,
damit die fertige Beschreibung im Asset landet und Claude sie sehen und verbessern kann.

Systemprompts, Sampling-Werte, das Geruest fuer Referenzbilder und die Box-Logik
(plan, reconcile) stammen aus BFLs Referenzcode
github.com/black-forest-labs/flux-3-image-klein (src/flux3/pup.py, bbox.py,
pup_prompts.json; Apache-2.0). Die Systemprompts liegen unveraendert in
flux3_pup_prompts.json.
"""
from __future__ import annotations

import hashlib
import json
import math
import re
from collections import OrderedDict
from pathlib import Path
from typing import Any

PROMPTS: dict[str, str] = json.loads(
    Path(__file__).with_name("flux3_pup_prompts.json").read_text(encoding="utf-8")
)

MAX_REFERENCES = 10
MAX_TOKENS = 3584
# BFL dekodiert gierig (temperature 0). ComfyUIs TextGenerate erlaubt keine 0 --
# top_k 1 bewirkt dasselbe, so macht es auch ComfyUIs eigene Vorlage. Die Strafen
# wirken dort auch beim gierigen Dekodieren (llama.py: sample_token).
PRESENCE_PENALTY = {"t2i": 1.5, "i2i": 0.0}
I2I_SCAFFOLD = {
    False: ("Reference images follow in order (the first image, the second image, ...).\n"
            "User request: {instruction}\n"
            "Output the caption."),
    True: ("Reference images follow in attachment order: ref_image_0, ref_image_1, ...\n"
           "User editing instruction: {instruction}\n"
           "Decide the edit, imagine the target image, and output the annotation record."),
}
# Bildbudget je Referenz, das der Upsampler sieht (pup.py: MAX_PIXELS_BY_REFS).
REF_MEGAPIXELS = {1: 1.0, 2: 0.5}  # ab drei Referenzen je 512 x 512
SCALE = 1000
ID = re.compile(r"[A-Za-z][A-Za-z0-9_]*")


# ------------------------------------------------------------ Planung

def canvas_line(width: int, height: int) -> str:
    """Seitenverhaeltnis fuer den Upsampler. Sein t2i-Systemprompt kennt die Zeile
    "TARGET CANVAS: W:H" und komponiert danach -- breit verteilt seitlich, hoch
    stapelt. Beim Quadrat bleibt sie weg, das ist sein Normalfall."""
    if width == height:
        return ""
    g = math.gcd(width, height)
    return f"TARGET CANVAS: {width // g}:{height // g}\n"


def plan(prompt: str, n_refs: int, width: int, height: int) -> tuple[str, str, list[dict] | None]:
    """(Systemprompt-Schluessel, Nutzertext, gesperrte Box-Zeilen) fuer den Upsampler.

    Haengt am Prompt eine Box-Tabelle, wechselt er in den Layout-Modus und bekommt
    die Boxen als unverrueckbare Vorgabe; reconcile() setzt sie danach wieder durch.
    """
    task = "i2i" if n_refs else "t2i"
    found = detect(prompt)
    if found:
        text, locked = found
        key, user = f"{task}_bbox", upsampling_input(text, locked)
    else:
        key, user, locked = task, prompt.strip(), None
    if n_refs:
        user = I2I_SCAFFOLD[locked is not None].format(instruction=user)
    else:
        user = canvas_line(width, height) + user
    return key, user, locked


def upsampling_input(prompt: str, rows: list[dict]) -> str:
    return (
        f"ORIGINAL PROMPT:\n{prompt.strip()}\n\n"
        "LOCKED BOUNDING-BOX ANNOTATIONS ([y_min, x_min, y_max, x_max] on a 0-1000 canvas, with (0, 0) at "
        "the top-left). This is an authoritative JSON list of dictionaries; preserve every supplied identity, "
        f"provenance value, null, and coordinate exactly:\n{json.dumps(rows, ensure_ascii=False)}"
    )


def is_finished(prompt: str) -> bool:
    """Schon eine fertige Upsampler-Antwort: Box-Tabelle vollstaendig als <id> zitiert.
    BFL schickt so einen Prompt unveraendert ans Bildmodell."""
    found = detect(prompt)
    return found is not None and all(f"<{row['id']}>" in found[0] for row in found[1])


# ------------------------------------------------------------ Box-Tabelle

def split(text: str) -> tuple[str, list | None]:
    """Beschreibung und Zeilen: ab der letzten '[', ab der der Rest als JSON-Liste parst.
    Kein Regex -- Beschreibungen duerfen selbst Klammern und Anfuehrungszeichen enthalten."""
    for i in range(len(text) - 1, -1, -1):
        if text[i] == "[":
            try:
                rows = json.loads(text[i:])
            except json.JSONDecodeError:
                continue
            if isinstance(rows, list):
                return text[:i].rstrip(), rows
    return text.strip(), None


def detect(prompt: str) -> tuple[str, list[dict]] | None:
    """(Prompt, Zeilen), wenn der Prompt Boxen auf dem 0-1000-Raster mitbringt.
    Eine Liste am Ende, die nicht nur aus Box-Zeilen besteht (etwa "[SALE]"), zaehlt nicht."""
    text, rows = split(prompt)
    if not rows or not all(
        isinstance(r, dict) and isinstance(r.get("id"), str) and ID.fullmatch(r["id"])
        and any(valid_box(r.get(k)) for k in ("bbox", "src_bbox", "tgt_bbox"))
        for r in rows
    ):
        return None
    locked = re.fullmatch(r"ORIGINAL PROMPT:\n(.*?)\n\nLOCKED BOUNDING-BOX ANNOTATIONS .*", text, re.S)
    return (locked.group(1) if locked else text), rows


def valid_box(box: Any) -> list | None:
    if not isinstance(box, (list, tuple)) or len(box) != 4:
        return None
    if any(isinstance(v, bool) or not isinstance(v, (int, float)) or v != v or abs(v) == float("inf")
           for v in box):
        return None
    y1, x1, y2, x2 = box
    # max <= 1 hiesse 0-1-Koordinaten statt des 0-1000-Rasters
    if y1 < 0 or x1 < 0 or y2 <= y1 or x2 <= x1 or y2 > SCALE or x2 > SCALE or max(box) <= 1:
        return None
    return list(box)


def _valid_added(row: Any, caption: str) -> dict | None:
    """Eine Zeile, die der Upsampler ergaenzt hat: bleibt nur, wenn ihre id als <id>
    zitiert wird und sie wohlgeformt ist."""
    if not isinstance(row, dict):
        return None
    row_id, desc = row.get("id"), row.get("desc")
    if not isinstance(row_id, str) or not ID.fullmatch(row_id) or f"<{row_id}>" not in caption \
            or not isinstance(desc, str) or not desc.strip():
        return None
    if (box := valid_box(row.get("bbox"))) is not None:
        return {"id": row_id, "bbox": box, "desc": desc.strip()}
    origin, src, tgt = row.get("from"), row.get("src_bbox"), row.get("tgt_bbox")
    src_box = valid_box(src) if src is not None else None
    tgt_box = valid_box(tgt) if tgt is not None else None
    if (not isinstance(origin, str) or not re.fullmatch(r"ref_image_\d+|target", origin)
            or (src is not None and src_box is None) or (tgt is not None and tgt_box is None)
            or (src_box is None and tgt_box is None) or (origin == "target") == (src_box is not None)):
        return None
    return {"id": row_id, "from": origin, "src_bbox": src_box, "tgt_bbox": tgt_box, "desc": desc.strip()}


def _iou(a: list, b: list) -> float:
    inter = max(0, min(a[2], b[2]) - max(a[0], b[0])) * max(0, min(a[3], b[3]) - max(a[1], b[1]))
    union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / union if union > 0 else 0.0


def reconcile(text: str, locked: list[dict]) -> str:
    """Die Antwort des Upsamplers mit den Boxen des Nutzers wieder durchgesetzt.

    1. Plant er eine gesperrte Box unter eigener id neu (IoU >= 0.9), bekommt sie die
       gesperrte id zurueck -- in den Zeilen und in den <id>-Zitaten.
    2. Gesperrte Zeilen bleiben woertlich, uebernehmen aber seine Beschreibung; seine
       eigenen Zeilen folgen, wenn sie gueltig sind.
    """
    caption, rows = split(text)
    rows = rows or []
    locked_ids = {r["id"] for r in locked}
    row_ids = {r.get("id") for r in rows if isinstance(r, dict)}
    renamed: dict[str, str] = {}
    for lock in locked:
        lock_box = lock.get("bbox") or lock.get("tgt_bbox") or lock.get("src_bbox")
        if lock["id"] in row_ids or lock_box is None:
            continue
        for row in rows:
            if not isinstance(row, dict) or row.get("id") in renamed or row.get("id") in locked_ids:
                continue
            box = valid_box(row.get("bbox") or row.get("tgt_bbox") or row.get("src_bbox"))
            if box is not None and _iou(box, lock_box) >= 0.9:
                renamed[row["id"]] = lock["id"]
                break
    for row in rows:
        if isinstance(row, dict) and row.get("id") in renamed:
            row["id"] = renamed[row["id"]]
    for old, new in renamed.items():
        caption = caption.replace(f"<{old}>", f"<{new}>")

    by_id = {r.get("id"): r for r in rows if isinstance(r, dict) and isinstance(r.get("id"), str)}
    out = []
    for lock in locked:
        desc = by_id.get(lock["id"], {}).get("desc")
        out.append({**lock, "desc": desc.strip() if isinstance(desc, str) and desc.strip()
                    else lock.get("desc", "")})
    for row in rows:
        added = _valid_added(row, caption)
        if added is not None and added["id"] not in {r["id"] for r in out}:
            out.append(added)
    return f"{caption} {json.dumps(out, ensure_ascii=False)}"


# ------------------------------------------------------------ Graph

def build_graph(upsampler_file: str, system_key: str, user_text: str,
                ref_images: list[str], system_text: str | None = None) -> dict[str, Any]:
    """ComfyUI-Graph, der nur die Beschreibung erzeugt. PreviewAny liefert den Text
    als UI-Ausgabe zurueck (comfy.run_text_workflow).

    Nachgebaut nach ComfyUIs Vorlagen image_flux3_klein_*: CLIPLoader Typ "flux3"
    laedt auch den Upsampler, TextGenerate traegt den Systemprompt. system_text ersetzt
    BFLs Systemprompt (Video, Audio, 3D: prompt_targets.py).
    """
    task = "i2i" if ref_images else "t2i"
    graph: dict[str, Any] = {
        "1": {"class_type": "CLIPLoader", "inputs": {
            "clip_name": upsampler_file, "type": "flux3", "device": "default"}},
        "2": {"class_type": "PrimitiveStringMultiline", "inputs": {"value": system_text or PROMPTS[system_key]}},
        "3": {"class_type": "TextGenerate", "inputs": {
            "clip": ["1", 0], "prompt": user_text, "max_length": MAX_TOKENS,
            "sampling_mode": "on",
            "sampling_mode.temperature": 1.0, "sampling_mode.top_k": 1,
            "sampling_mode.top_p": 0.95, "sampling_mode.min_p": 0.0,
            "sampling_mode.repetition_penalty": 1.0, "sampling_mode.seed": 0,
            "sampling_mode.presence_penalty": PRESENCE_PENALTY[task],
            "thinking": False, "use_default_template": True, "mtp": "off",
            "system_prompt": ["2", 0]}},
        "4": {"class_type": "PreviewAny", "inputs": {"source": ["3", 0]}},
    }
    if ref_images:
        # Der Upsampler sieht die Referenzen verkleinert, wie in BFLs pup.py: eine mit
        # 1 MP, zwei mit je 0,5 MP, ab drei je 0,25 MP.
        mp = REF_MEGAPIXELS.get(len(ref_images), 0.25)
        batch: dict[str, Any] = {}
        for i, name in enumerate(ref_images):
            load, scale = f"1{i:02d}", f"2{i:02d}"
            graph[load] = {"class_type": "LoadImage", "inputs": {"image": name}}
            graph[scale] = {"class_type": "ImageScaleToTotalPixels", "inputs": {
                "image": [load, 0], "upscale_method": "lanczos", "megapixels": mp,
                "resolution_steps": 32}}
            batch[f"images.image{i}"] = [scale, 0]
        graph["5"] = {"class_type": "BatchImagesNode", "inputs": batch}
        graph["3"]["inputs"]["image"] = ["5", 0]
    return graph


# ------------------------------------------------------------ Zwischenspeicher

# Gierig dekodiert ist die Beschreibung fuer dieselbe Anfrage immer dieselbe. Neue
# Seeds oder eine zweite Charge brauchen den Upsampler deshalb nicht noch einmal.
_CACHE: OrderedDict[str, str] = OrderedDict()
_CACHE_MAX = 128


def cache_key(upsampler_file: str, system_key: str, user_text: str, ref_ids: list[str]) -> str:
    raw = json.dumps([upsampler_file, system_key, user_text, ref_ids], ensure_ascii=False)
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def cache_get(key: str) -> str | None:
    caption = _CACHE.get(key)
    if caption is not None:
        _CACHE.move_to_end(key)
    return caption


def cache_put(key: str, caption: str) -> None:
    _CACHE[key] = caption
    _CACHE.move_to_end(key)
    while len(_CACHE) > _CACHE_MAX:
        _CACHE.popitem(last=False)
