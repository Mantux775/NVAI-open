"""LoRA erstellen/Bearbeiten (seit 0.5.29). Nutzer 16.11.2026: „integriere neuen Bereich ‚LoRA erstellen/Bearbeiten'.
dort soll ich mit eigenen loras arbeiten können“.

Eigene LoRAs für Qwen-Image-2512 trainieren, auf dem Weg, der die Somi-LoRAs gemacht hat (notizen/loras.md):

1. Datensatz: Bilder mit Bildbeschreibung, aus dem Verlauf, aus einem Ordner oder aus einer Vorlage erzeugt
   (Qwen-Image-Edit-2511 mit der 8-Schritt-Lightning-LoRA, Apache-2.0: dieselbe Figur in 24 Haltungen, Ausschnitten
   und Umgebungen, 44 s je Bild). Bilder aus FLUX 3 nimmt er nicht an: Die FLUX Kommunity License verbietet in 4(b),
   mit ihren Ausgaben ein anderes Bildmodell zu trainieren.
2. Training mit musubi-tuner (kohya-ss, Apache-2.0) in eigener Umgebung unter <Daten>/LoRA-Training/musubi-tuner:
   Qwen-Image-2512 in bf16 (nur fürs Training), fp8 + Block-Swap 40, Text-Encoder-Cache auf dem Prozessor.
   Gemessen 15./16.11. (RTX 5060 Ti 16 GB, 64 GB RAM): höchstens 14,3 GB Grafikspeicher, 16,3 s je Schritt,
   24 Bilder x 20 Epochen = 480 Schritte in 130 min, Text-Encoder 17,7 s je Bildbeschreibung.
3. Probebilder je Zwischenstand (mit festem Seed, dazu ohne LoRA), dann den besten Stand als LoRA übernehmen
   (registry.add_upload, wie eine hochgeladene Datei).

Ablage unter <Daten>/LoRA-Training: musubi-tuner/ (Trainer), modelle/ (bf16-Gewichte), datasets/<id>/ (Bilder,
dataset.json), output/<lauf>/ (Zwischenstände, run.json, test/), train/ und cache/ (Arbeitsdateien), logs/.
"""
from __future__ import annotations

import asyncio
import contextlib
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import traceback
import uuid
import zipfile
from pathlib import Path
from typing import Any

from fastapi import APIRouter, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

from . import comfy, config, db, gpu, i18n, imagesize, jobs, loras, mesh_workers, registry, workflows
from .i18n import t
from .schemas import Job

ROOT = config.DATA_DIR / "LoRA-Training"
TOOL = ROOT / "musubi-tuner"
WEIGHTS = ROOT / "modelle"
DATASETS = ROOT / "datasets"
OUTPUT = ROOT / "output"
CACHE = ROOT / "cache"
TRAIN = ROOT / "train"
LOGS = ROOT / "logs"

MUSUBI_TAG = "v0.3.6"
MUSUBI_ZIP = f"https://github.com/kohya-ss/musubi-tuner/archive/refs/tags/{MUSUBI_TAG}.zip"

# bf16-Gewichte nur fürs Training: musubi-tuner liest weder NVFP4 noch die skalierten fp8-Dateien von ComfyUI
TRAIN_FILES = [
    {"key": "dit", "repo": "Comfy-Org/Qwen-Image_ComfyUI",
     "file": "split_files/diffusion_models/qwen_image_2512_bf16.safetensors", "size_gb": 40.9,
     "label": "Qwen-Image-2512 bf16"},
    {"key": "te", "repo": "Comfy-Org/Qwen-Image_ComfyUI",
     "file": "split_files/text_encoders/qwen_2.5_vl_7b.safetensors", "size_gb": 16.6,
     "label": "Qwen2.5-VL 7B bf16 (Text-Encoder)", "label_en": "Qwen2.5-VL 7B bf16 (text encoder)"},
]
# Datensatz aus einer Vorlage: Qwen-Image-Edit-2511 (Apache-2.0) mit der Lightning-LoRA (8 Schritte, CFG 1);
# Text-Encoder und VAE kommen von Qwen-Image-2512
EDIT_FILES = [
    {"key": "edit", "repo": "Comfy-Org/Qwen-Image-Edit_ComfyUI",
     "file": "split_files/diffusion_models/qwen_image_edit_2511_fp8mixed.safetensors", "target": "diffusion_models",
     "size_gb": 20.5, "label": "Qwen-Image-Edit-2511 fp8"},
    {"key": "lightning", "repo": "lightx2v/Qwen-Image-Edit-2511-Lightning",
     "file": "Qwen-Image-Edit-2511-Lightning-8steps-V1.0-bf16.safetensors", "target": "loras", "size_gb": 0.85,
     "label": "Qwen-Image-Edit-2511 Lightning (8 Schritte)", "label_en": "Qwen-Image-Edit-2511 Lightning (8 steps)"},
]
TE_FP8 = "qwen_2.5_vl_7b_fp8_scaled.safetensors"
VAE = "qwen_image_vae.safetensors"

# Gemessen 15./16.11.2026 (RTX 5060 Ti 16 GB): Schritt samt Laden und Speichern, Text-Encoder auf dem Prozessor je
# Bildbeschreibung, Probebild Qwen-Image-2512 NVFP4 896 x 1152 mit 50 Schritten, Vorlagenbild mit Edit-2511
SECONDS_PER_STEP = 16.3
TE_SECONDS_PER_CAPTION = 17.7
TEST_SECONDS_PER_IMAGE = 100.0
EDIT_SECONDS_PER_IMAGE = 44.0
# alpha: musubi-tuner speichert ohne Angabe network_alpha = 1, die LoRA wirkt dann nur mit alpha/Rang = 1/16. Gemessen
# 16.11. an Somi Dark (Probebilder Stärke 1, Seed 777): alpha 1 / lr 1e-4 / 480 Schritte kaum Wirkung (schwarzer Hase,
# erst 2,5 traf die Figur); alpha 16 / lr 5e-5 / 288 Schritte stärker (Delta 4,7-fach), aber noch nicht genug, auch auf
# fp8 statt NVFP4. Beide zu schwach, keiner zu stark. 17.11. mit alpha 16 / lr 2e-4 / 20 Epochen (340-480 Schritte):
# alle drei Somi-LoRAs treffen die Figur bei Stärke 1, ab Epoche 15; deshalb diese Vorgabe.
DEFAULTS = {"epochs": 20, "lr": "2e-4", "rank": 16, "alpha": 16, "save_every": 5}
MIN_IMAGES = 10
KINDS = ("lora_train", "lora_test", "lora_dataset")
# Pausieren (seit 17.11.2026): musubi speichert nach jeder Epoche einen Zustand (Gewichte, Optimierer, Zufall); der
# laufende Auftrag liest hier, ob er nach der Epoche („epoch“) oder sofort („now“) anhalten soll.
_PAUSE: dict[str, str] = {}
_run_lock = threading.Lock()
LOSS_MAX = 6000
QUICK_MAX = 60
_EPOCH_LINE = re.compile(r"^epoch (\d+)/(\d+)$")

# Bilder, deren Lizenz das Training eines anderen Bildmodells verbietet (FLUX Kommunity License 4(b)), und solche, bei
# denen die Bedingungen des Modells mitgehen
BLOCKED_LICENSES = ("FLUX Kommunity License",)
WARN_LICENSES = ("Krea 2 Community License", "Qwen Research License")

IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp"}
_DS_ID = re.compile(r"^ds_[a-z0-9]{6,16}$")
_RUN_ID = re.compile(r"^[A-Za-z0-9_\-]{1,64}$")
_TRIGGER = re.compile(r"^[a-z0-9][a-z0-9_]{2,39}$")
_FILE = re.compile(r"^[A-Za-z0-9_\-.]{1,120}$")
_lock = threading.Lock()

# Größen wie beim Somi-Datensatz: Hochformat für ganze Figuren, Quadrat für Halbnah und Gesicht, Querformat für Szenen
PORTRAIT, SQUARE, WIDE = (896, 1152), (1024, 1024), (1152, 896)
POSES: list[tuple[str, str, tuple[int, int]]] = [
    ("full body, standing, facing the viewer, plain light grey background",
     "Full body, standing upright and facing the viewer, arms hanging relaxed at the sides, on a plain light grey "
     "background.", PORTRAIT),
    ("full body, standing, facing the viewer, plain white background",
     "Full body, standing upright and facing the viewer, on a plain white background.", PORTRAIT),
    ("full body, standing on a city street at night",
     "Full body, standing on a city street at night between old houses with lit windows, facing the viewer.", PORTRAIT),
    ("full body, standing in an empty office",
     "Full body, standing in an empty office with desks and office chairs in the background, facing the viewer.", WIDE),
    ("full body, standing in front of a brick wall",
     "Full body, standing in front of a grey brick wall, facing the viewer.", PORTRAIT),
    ("full body, sitting on a wooden chair, dark background",
     "Full body, sitting on a simple wooden chair, facing the viewer, dark background.", SQUARE),
    ("full body, walking towards the viewer, dark background",
     "Full body, walking towards the viewer with one foot raised in mid-step, dark background.", PORTRAIT),
    ("full body, sitting on the floor, hugging the knees, dark background",
     "Full body, sitting on the floor and hugging the knees, facing the viewer, dark background.", SQUARE),
    ("medium shot, arms crossed, dark background",
     "Medium shot from the waist up, arms crossed in front of the chest, facing the viewer, dark background.", SQUARE),
    ("medium shot, holding a coffee mug, plain light grey background",
     "Medium shot from the waist up, holding a white coffee mug with both hands, plain light grey background.", SQUARE),
    ("medium shot, sitting at a desk, typing, office at night",
     "Medium shot, sitting at a desk in an office at night and typing on a computer keyboard, facing the viewer over "
     "the monitor.", WIDE),
    ("medium shot, pointing at the viewer, dark background",
     "Medium shot from the waist up, pointing straight at the viewer with one finger, dark background.", SQUARE),
    ("medium shot, waving one hand, plain white background",
     "Medium shot from the waist up, waving one hand at the viewer, plain white background.", SQUARE),
    ("medium shot, scratching the head, plain light grey background",
     "Medium shot from the waist up, scratching the top of the head with one hand, plain light grey background.",
     SQUARE),
    ("medium shot, hands on the hips, plain white background",
     "Medium shot from the waist up, both hands on the hips, facing the viewer, plain white background.", SQUARE),
    ("medium shot, holding a smartphone, dark background",
     "Medium shot from the waist up, holding a smartphone in both hands and looking at the screen, dark background.",
     SQUARE),
    ("close-up of the face, dark background",
     "Close-up of the face, facing the viewer, dark background.", SQUARE),
    ("close-up of the face, plain white background",
     "Close-up of the face, facing the viewer, plain white background.", SQUARE),
    ("close-up of the face, head tilted, plain light grey background",
     "Close-up of the face, head slightly tilted to one side, plain light grey background.", SQUARE),
    ("full body, standing in a park with trees, daylight",
     "Full body, standing on a path in a park with trees in daylight, facing the viewer.", PORTRAIT),
    ("full body, jumping with both arms raised, plain white background",
     "Full body, jumping in the air with both arms raised, plain white background.", PORTRAIT),
    ("medium shot, laughing, plain light grey background",
     "Medium shot from the waist up, laughing, facing the viewer, plain light grey background.", SQUARE),
    ("full body, running towards the viewer, dark background",
     "Full body, running towards the viewer, dark background.", PORTRAIT),
    ("medium shot, reading a book in an armchair, warm lamp light",
     "Medium shot, sitting in an armchair and reading an open book, warm lamp light.", WIDE),
]
SAME = ("The character from the first image, exactly the same character: the same face, eyes, colors, proportions, "
        "clothing and accessories, drawn or rendered in exactly the same style as the first image.")
# Entwürfe (Assistent, seit 17.11.2026): Figur frontal und ganz, damit sich die Vorlage gut vergleichen lässt
DRAFT_FROM_IMAGE = ("Turn the first image into a finished, clean drawing of the same character: keep its shape, "
                    "proportions and features, and redraw it as one complete character.")
DRAFT_POSE = ("Full body from the top of the head to the feet, standing upright and facing the viewer frontally, both "
              "arms hanging at the sides, on a plain light grey background.")
MAX_DRAFTS = 48
TEST_PROMPTS = ("full body, standing, facing the viewer, plain light grey background",
                "medium shot, sitting at a desk in an office, facing the viewer")


class LoraTrainError(Exception):
    """Fehler, den der Nutzer beheben kann (fehlende Dateien, falsche Angaben); die Route macht 400 daraus."""


# ----------------------------------------------------------------------------------------------- Einrichtung

def tool_python() -> Path:
    return TOOL / ".venv" / ("Scripts/python.exe" if sys.platform == "win32" else "bin/python")


def tool_accelerate() -> Path:
    return TOOL / ".venv" / ("Scripts/accelerate.exe" if sys.platform == "win32" else "bin/accelerate")


def tool_installed() -> bool:
    return tool_python().exists() and tool_accelerate().exists() and (TOOL / "src" / "musubi_tuner").is_dir()


def tool_version() -> str | None:
    with contextlib.suppress(OSError):
        m = re.search(r'^version\s*=\s*"([^"]+)"', (TOOL / "pyproject.toml").read_text(encoding="utf-8"), re.M)
        return m.group(1) if m else None
    return None


def _train_file(key: str) -> Path:
    f = next(x for x in TRAIN_FILES if x["key"] == key)
    return WEIGHTS / Path(f["file"]).name


def _edit_file(f: dict[str, Any]) -> Path:
    return config.COMFY_MODEL_DIR / f["target"] / Path(f["file"]).name


def _vae() -> Path:
    return config.COMFY_MODEL_DIR / "vae" / VAE


def _uv() -> str | None:
    bundled = config.ROOT / "tools" / ("uv.exe" if sys.platform == "win32" else "uv")
    return str(bundled) if bundled.exists() else shutil.which("uv")


def inference_entry() -> dict[str, Any] | None:
    """Das installierte Qwen-Image-2512 für Probebilder (volle Fassung mit 50 Schritten, nicht Lightning); die aktive
    Bildwahl zuerst, sonst die empfohlene Fassung."""
    candidates = [e for e in registry.all_entries()
                  if e.get("kind") == "image" and e.get("workflow") == "qwen_image" and registry.is_installed(e)]
    if not candidates:
        return None
    active = registry.get_active_model("image")
    for e in candidates:
        if e["id"] == active:
            return e
    order = ("qwen-image-2512-nvfp4", "qwen-image-2512-int8", "qwen-image-2512-fp8")
    candidates.sort(key=lambda e: order.index(e["id"]) if e["id"] in order else len(order))
    return candidates[0]


def status() -> dict[str, Any]:
    """Was zum Trainieren da ist und was fehlt, dazu Datensätze und Läufe."""
    vendor = gpu.vendor()
    try:
        card = gpu.device_for("image")
        vram = gpu.card_vram_gb(card)
    except Exception:  # noqa: BLE001 - nur Anzeige
        vram = None
    with contextlib.suppress(OSError):
        ROOT.mkdir(parents=True, exist_ok=True)
    free_gb = round(shutil.disk_usage(ROOT if ROOT.exists() else config.DATA_DIR).free / 1024**3, 1)
    entry = inference_entry()
    return {
        "root": str(ROOT),
        "nvidia": vendor == "nvidia",
        "vendor": vendor,
        "vram_gb": vram,
        "free_gb": free_gb,
        "tool": {"installed": tool_installed(), "version": tool_version(), "tag": MUSUBI_TAG, "size_gb": 6.5,
                 "uv": bool(_uv())},
        "weights": [{"key": f["key"], "label": t(f["label"], f.get("label_en", f["label"])), "size_gb": f["size_gb"],
                     "installed": _train_file(f["key"]).exists()} for f in TRAIN_FILES],
        "edit": [{"key": f["key"], "label": t(f["label"], f.get("label_en", f["label"])), "size_gb": f["size_gb"],
                  "installed": _edit_file(f).exists()} for f in EDIT_FILES],
        "base": {"installed": entry is not None and _vae().exists(), "model_id": entry["id"] if entry else None,
                 "te_fp8": (config.COMFY_MODEL_DIR / "text_encoders" / TE_FP8).exists()},
        "ready": tool_installed() and all(_train_file(f["key"]).exists() for f in TRAIN_FILES) and _vae().exists(),
        "template_ready": all(_edit_file(f).exists() for f in EDIT_FILES)
        and (config.COMFY_MODEL_DIR / "text_encoders" / TE_FP8).exists() and _vae().exists(),
        "defaults": DEFAULTS,
        "timing": {"seconds_per_step": SECONDS_PER_STEP, "te_seconds_per_caption": TE_SECONDS_PER_CAPTION,
                   "test_seconds_per_image": TEST_SECONDS_PER_IMAGE, "edit_seconds_per_image": EDIT_SECONDS_PER_IMAGE},
        "poses": [p[0] for p in POSES],
        "test_prompts": list(TEST_PROMPTS),
        "min_images": MIN_IMAGES,
        "datasets": list_datasets(),
        "runs": list_runs(),
    }


async def _setup(job: Job, ctx: jobs.JobContext) -> list[str]:
    """Trainer einrichten und Dateien laden (Download-Warteschlange): parts = tool, weights, edit."""
    parts = job.params.get("parts") or ["tool", "weights"]
    steps: list[tuple[str, Any]] = []
    if "tool" in parts and not tool_installed():
        steps.append(("tool", None))
    if "weights" in parts:
        steps += [("file", (f, _train_file(f["key"]))) for f in TRAIN_FILES if not _train_file(f["key"]).exists()]
    if "edit" in parts:
        steps += [("file", (f, _edit_file(f))) for f in EDIT_FILES if not _edit_file(f).exists()]
    for i, (what, arg) in enumerate(steps):
        base, span = i / max(len(steps), 1), 1 / max(len(steps), 1)
        if what == "tool":
            await _install_tool(ctx, base, span)
        else:
            f, dest = arg
            await asyncio.to_thread(registry._download_file, {"repo": f["repo"], "file": f["file"]}, dest, f["label"],
                                    base, span, ctx.progress, ctx.should_stop)
    ctx.progress(1.0, t("eingerichtet", "set up"))
    return []


async def _install_tool(ctx: jobs.JobContext, base: float, span: float) -> None:
    """musubi-tuner (Stand MUSUBI_TAG) als ZIP von GitHub, dann uv sync mit PyTorch für CUDA 13.0."""
    if gpu.vendor() != "nvidia":
        raise LoraTrainError(t("Das Training läuft nur auf NVIDIA-Karten (musubi-tuner mit CUDA).",
                               "Training runs on NVIDIA cards only (musubi-tuner with CUDA)."))
    uv = _uv()
    if not uv:
        raise LoraTrainError(t("uv fehlt (gehört zur Installation von NVAI-open, Ordner tools).",
                               "uv is missing (part of the NVAI-open installation, folder tools)."))
    ROOT.mkdir(parents=True, exist_ok=True)
    archive = ROOT / f"musubi-tuner-{MUSUBI_TAG}.zip"
    await asyncio.to_thread(registry._download_url, MUSUBI_ZIP, archive, "musubi-tuner", base, span * 0.1,
                            ctx.progress, ctx.should_stop)
    staging = ROOT / f".musubi-{uuid.uuid4().hex[:6]}"
    try:
        def extract() -> None:
            with zipfile.ZipFile(archive) as z:
                z.extractall(staging)
            inner = next(p for p in staging.iterdir() if p.is_dir())
            if TOOL.exists():
                shutil.rmtree(TOOL)
            inner.replace(TOOL)
        await asyncio.to_thread(extract)
    finally:
        shutil.rmtree(staging, ignore_errors=True)
        archive.unlink(missing_ok=True)
    ctx.progress(base + span * 0.15, t("richte die Umgebung ein (PyTorch, rund 6 GB) …",
                                       "setting up the environment (PyTorch, about 6 GB) …"))
    log = LOGS / f"setup-{time.strftime('%Y%m%d-%H%M')}.log"
    await _run([uv, "sync", "--extra", "cu130"], ctx, log, base + span * 0.15, span * 0.85,
               t("Umgebung", "environment"), env_extra={"UV_LINK_MODE": "copy"})
    if not tool_installed():
        raise RuntimeError(t(f"musubi-tuner ist nach der Einrichtung nicht vollständig. Protokoll: {log}",
                             f"musubi-tuner is incomplete after the setup. Log: {log}"))


# ------------------------------------------------------------------------------------------------ Datensätze

def _ds_dir(ds_id: str) -> Path:
    if not _DS_ID.match(ds_id or ""):
        raise LookupError(t(f"Unbekannter Datensatz: {ds_id}", f"Unknown dataset: {ds_id}"))
    path = DATASETS / ds_id
    if not (path / "dataset.json").exists():
        raise LookupError(t(f"Unbekannter Datensatz: {ds_id}", f"Unknown dataset: {ds_id}"))
    return path


def _write_json(path: Path, data: dict[str, Any]) -> None:
    tmp = path.with_suffix(f".{uuid.uuid4().hex[:6]}.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    db.replace_file(tmp, path)  # unter Windows scheitert os.replace kurz, solange jemand die Datei liest


def load_dataset(ds_id: str) -> dict[str, Any]:
    ds = json.loads((_ds_dir(ds_id) / "dataset.json").read_text(encoding="utf-8"))
    ds["images"] = [im for im in ds.get("images", []) if (DATASETS / ds_id / im["file"]).exists()]
    ds["drafts"] = [d for d in ds.get("drafts", []) if (DATASETS / ds_id / d["file"]).exists()]
    return ds


def _save_dataset(ds: dict[str, Any]) -> None:
    ds["updated"] = time.time()
    _write_json(DATASETS / ds["id"] / "dataset.json", ds)


def _summary(ds: dict[str, Any]) -> dict[str, Any]:
    keep = [im for im in ds["images"] if im.get("status") != "reject"]
    return {"id": ds["id"], "name": ds["name"], "trigger": ds["trigger"], "class_word": ds.get("class_word", ""),
            "images": len(ds["images"]), "keep": len(keep), "updated": ds.get("updated"),
            "cover": keep[0]["file"] if keep else None, "template": ds.get("template"),
            "sketch": ds.get("sketch"), "drafts": len(ds.get("drafts") or [])}


def list_datasets() -> list[dict[str, Any]]:
    out = []
    if DATASETS.exists():
        for path in DATASETS.glob("ds_*/dataset.json"):
            with contextlib.suppress(OSError, ValueError, KeyError, LookupError):
                out.append(_summary(load_dataset(path.parent.name)))
    return sorted(out, key=lambda d: -(d.get("updated") or 0))


def _check_trigger(trigger: str) -> str:
    trigger = (trigger or "").strip().lower()
    if not _TRIGGER.match(trigger):
        raise LoraTrainError(t("Das Auslösewort braucht 3 bis 40 Zeichen aus Kleinbuchstaben, Ziffern und _ "
                               "(etwa somi_dark1); es sollte kein echtes Wort sein.",
                               "The trigger word needs 3 to 40 characters of lowercase letters, digits and _ "
                               "(such as somi_dark1); it should not be a real word."))
    return trigger


def create_dataset(name: str, trigger: str, class_word: str = "", notes: str = "") -> dict[str, Any]:
    trigger = _check_trigger(trigger)
    ds_id = f"ds_{uuid.uuid4().hex[:8]}"
    (DATASETS / ds_id).mkdir(parents=True, exist_ok=True)
    ds = {"id": ds_id, "name": (name or trigger).strip()[:80], "trigger": trigger,
          "class_word": (class_word or "").strip()[:80], "notes": (notes or "").strip()[:1000],
          "created": time.time(), "images": [], "template": None, "base": "qwenimage"}
    _save_dataset(ds)
    return ds


def update_dataset(ds_id: str, **fields: Any) -> dict[str, Any]:
    with _lock:
        ds = load_dataset(ds_id)
        if fields.get("trigger") is not None:
            ds["trigger"] = _check_trigger(fields["trigger"])
        for key, limit in (("name", 80), ("class_word", 80), ("notes", 1000)):
            if fields.get(key) is not None:
                ds[key] = str(fields[key]).strip()[:limit]
        _save_dataset(ds)
    return ds


def delete_dataset(ds_id: str) -> None:
    path = _ds_dir(ds_id)
    busy = [j for j in db.list_jobs(limit=200, active=True)
            if j.kind in KINDS and (j.params or {}).get("dataset_id") == ds_id]
    if busy:
        raise LoraTrainError(t("Mit diesem Datensatz läuft gerade ein Auftrag.", "A job is running with this dataset."))
    shutil.rmtree(path)


def _strip_prefix(caption: str, ds: dict[str, Any]) -> str:
    """Bildbeschreibungen aus einem Training enthalten vorn Auslösewort und Gattung; die setzt das Training selbst."""
    text = " ".join((caption or "").split())
    for word in (ds["trigger"], ds.get("class_word") or ""):
        if word and text.lower().startswith(word.lower()):
            text = text[len(word):].lstrip(" ,;:")
    return text[:600]


def _next_name(ds_id: str, suffix: str) -> str:
    numbers = [int(m.group(1)) for p in (DATASETS / ds_id).iterdir() if (m := re.fullmatch(r"img_(\d+)", p.stem))]
    return f"img_{max(numbers, default=0) + 1:04d}{suffix}"


def _common_head(captions: list[str]) -> list[str]:
    """Gemeinsamer Anfang (durch Kommas getrennte Teile) aller Bildbeschreibungen eines kohya-Datensatzes, meist
    Auslösewort und Gattung („somi_dark1, a cartoon rabbit“); höchstens zwei Teile."""
    split = [[x.strip() for x in c.split(",")] for c in captions if c.strip()]
    if len(split) < 2:
        return []
    head: list[str] = []
    for i in range(2):
        first = {parts[i].lower() for parts in split if len(parts) > i + 1}
        if len(first) != 1 or any(len(parts) <= i + 1 for parts in split):
            break
        head.append(split[0][i])
    return head


def _license_of(model_id: str | None) -> str:
    entry = registry.get_entry(model_id) if model_id else None
    return str(entry.get("license") or "") if entry else ""


def _add_file(ds: dict[str, Any], src: Path, caption: str, source: str, **extra: Any) -> dict[str, Any]:
    suffix = src.suffix.lower()
    name = _next_name(ds["id"], ".jpg" if suffix == ".jpeg" else suffix)
    shutil.copyfile(src, DATASETS / ds["id"] / name)
    dims = imagesize.size(DATASETS / ds["id"] / name) or (0, 0)
    item = {"file": name, "caption": _strip_prefix(caption, ds), "status": "keep", "source": source,
            "width": dims[0], "height": dims[1], "added": time.time(), **{k: v for k, v in extra.items() if v}}
    ds["images"].append(item)
    return item


def add_assets(ds_id: str, asset_ids: list[str], caption: str = "") -> dict[str, Any]:
    """Bilder aus dem Verlauf. FLUX-3-Bilder werden abgelehnt (Lizenz 4(b)), bei anderen eingeschränkten Lizenzen
    bekommt das Bild einen Hinweis."""
    refused, warned = [], []
    with _lock:
        ds = load_dataset(ds_id)
        for aid in asset_ids[:200]:
            asset = db.get_asset(aid)
            path = db.asset_file(asset.filename) if asset else None
            if asset is None or path is None or not path.exists() or path.suffix.lower() not in IMAGE_SUFFIXES:
                continue
            lic = _license_of(asset.model_id)
            if any(b in lic for b in BLOCKED_LICENSES):
                refused.append(path.name)
                continue
            note = lic if any(w in lic for w in WARN_LICENSES) else ""
            if note:
                warned.append(path.name)
            _add_file(ds, path, caption or "", "asset", asset_id=aid, model_id=asset.model_id, license_note=note)
        _save_dataset(ds)
    msg = []
    if refused:
        msg.append(t(f"{len(refused)} Bild(er) aus FLUX 3 nicht übernommen: Die FLUX Kommunity License verbietet in "
                     "4(b), mit ihren Bildern ein anderes Bildmodell zu trainieren.",
                     f"{len(refused)} image(s) from FLUX 3 not added: the FLUX Kommunity License forbids in 4(b) "
                     "training another image model with its images."))
    if warned:
        msg.append(t(f"{len(warned)} Bild(er) aus einem Modell mit eingeschränkter Lizenz (Krea 2, Qwen Research): "
                     "Deren Bedingungen gelten für die LoRA mit.",
                     f"{len(warned)} image(s) from a model with a restricted license (Krea 2, Qwen Research): their "
                     "terms carry over to the LoRA."))
    return {**ds, "message": " ".join(msg)}


def add_folder(ds_id: str, folder: str) -> dict[str, Any]:
    """Bilder samt gleichnamiger .txt (Bildbeschreibung) aus einem Ordner dieses Rechners, etwa einem kohya-Datensatz."""
    src = Path(folder.strip().strip('"'))
    if not src.is_dir():
        raise LoraTrainError(t(f"Ordner nicht gefunden: {src}", f"Folder not found: {src}"))
    files = sorted(p for p in src.iterdir() if p.suffix.lower() in IMAGE_SUFFIXES)[:500]
    if not files:
        raise LoraTrainError(t("Im Ordner liegen keine Bilder (png, jpg, webp).",
                               "The folder holds no images (png, jpg, webp)."))
    captions = {}
    for p in files:
        txt = p.with_suffix(".txt")
        captions[p] = " ".join(txt.read_text(encoding="utf-8", errors="replace").split()) if txt.exists() else ""
    head = _common_head(list(captions.values()))
    with _lock:
        ds = load_dataset(ds_id)
        for p in files:
            caption = captions[p]
            if head:
                parts = [x.strip() for x in caption.split(",")]
                caption = ", ".join(parts[len(head):])
            _add_file(ds, p, caption, "folder", origin=str(p))
        if len(head) == 2 and not ds.get("class_word"):
            ds["class_word"] = head[1][:80]
        _save_dataset(ds)
    message = ""
    if head:
        message = t(f"Gemeinsamer Anfang „{', '.join(head)}“ aus den Bildbeschreibungen entfernt: Auslösewort und "
                    "Gattung setzt das Training selbst davor.",
                    f"Common start “{', '.join(head)}” removed from the captions: the training puts the trigger word "
                    "and class in front by itself.")
    return {**ds, "message": message}


def set_template(ds_id: str, asset_id: str) -> dict[str, Any]:
    asset = db.get_asset(asset_id)
    path = db.asset_file(asset.filename) if asset else None
    if path is None or not path.exists() or path.suffix.lower() not in IMAGE_SUFFIXES:
        raise LoraTrainError(t("Die Vorlage muss ein Bild sein.", "The template must be an image."))
    if any(b in _license_of(asset.model_id) for b in BLOCKED_LICENSES):
        raise LoraTrainError(t("Eine Vorlage aus FLUX 3 geht nicht: Die FLUX Kommunity License verbietet in 4(b), mit "
                               "ihren Bildern ein anderes Bildmodell zu trainieren. Eine Skizze oder ein Bild aus "
                               "Qwen-Image geht.",
                               "A template from FLUX 3 is not possible: the FLUX Kommunity License forbids in 4(b) "
                               "training another image model with its images. A sketch or an image from Qwen-Image "
                               "works."))
    with _lock:
        ds = load_dataset(ds_id)
        name = f"vorlage{path.suffix.lower()}"
        for old in (DATASETS / ds_id).glob("vorlage.*"):
            old.unlink(missing_ok=True)
        shutil.copyfile(path, DATASETS / ds_id / name)
        ds["template"] = name
        _save_dataset(ds)
    return ds


def _image_asset(asset_id: str, what: str) -> Path:
    asset = db.get_asset(asset_id)
    path = db.asset_file(asset.filename) if asset else None
    if asset is None or path is None or not path.exists() or path.suffix.lower() not in IMAGE_SUFFIXES:
        raise LoraTrainError(t(f"{what} muss ein Bild sein.", f"The {what.lower()} must be an image."))
    if any(b in _license_of(asset.model_id) for b in BLOCKED_LICENSES):
        raise LoraTrainError(t(f"{what} aus FLUX 3 geht nicht: Die FLUX Kommunity License verbietet in 4(b), mit "
                               "ihren Bildern ein anderes Bildmodell zu trainieren. Eine eigene Zeichnung, ein Foto "
                               "oder ein Bild aus Qwen-Image geht.",
                               f"A {what.lower()} from FLUX 3 is not possible: the FLUX Kommunity License forbids in "
                               "4(b) training another image model with its images. A drawing of your own, a photo or "
                               "an image from Qwen-Image works."))
    return path


def set_sketch(ds_id: str, asset_id: str) -> dict[str, Any]:
    """Ausgangsbild für Entwürfe: eine Skizze, ein Foto oder ein fertiges Bild der Figur."""
    path = _image_asset(asset_id, t("Die Skizze", "Sketch"))
    with _lock:
        ds = load_dataset(ds_id)
        for old in (DATASETS / ds_id).glob("skizze.*"):
            old.unlink(missing_ok=True)
        name = f"skizze{path.suffix.lower()}"
        shutil.copyfile(path, DATASETS / ds_id / name)
        ds["sketch"] = name
        _save_dataset(ds)
    return ds


def pick_template(ds_id: str, file: str) -> dict[str, Any]:
    """Die Skizze selbst oder einen Entwurf zur Vorlage machen, aus der die Bilder des Datensatzes entstehen."""
    with _lock:
        ds = load_dataset(ds_id)
        allowed = {d["file"] for d in ds.get("drafts", [])} | ({ds["sketch"]} if ds.get("sketch") else set())
        if file not in allowed or not _FILE.match(file):
            raise LookupError(t(f"Unbekanntes Bild: {file}", f"Unknown image: {file}"))
        src = DATASETS / ds_id / file
        for old in (DATASETS / ds_id).glob("vorlage.*"):
            old.unlink(missing_ok=True)
        name = f"vorlage{src.suffix.lower()}"
        shutil.copyfile(src, DATASETS / ds_id / name)
        ds["template"] = name
        ds["template_from"] = file
        _save_dataset(ds)
    return ds


def clear_drafts(ds_id: str, keep_file: str | None = None) -> dict[str, Any]:
    with _lock:
        ds = load_dataset(ds_id)
        for d in ds.get("drafts", []):
            if d["file"] != keep_file:
                (DATASETS / ds_id / d["file"]).unlink(missing_ok=True)
        ds["drafts"] = [d for d in ds.get("drafts", []) if d["file"] == keep_file]
        _save_dataset(ds)
    return ds


def update_image(ds_id: str, file: str, caption: str | None = None, status: str | None = None) -> dict[str, Any]:
    with _lock:
        ds = load_dataset(ds_id)
        item = next((im for im in ds["images"] if im["file"] == file), None)
        if item is None:
            raise LookupError(t(f"Unbekanntes Bild: {file}", f"Unknown image: {file}"))
        if caption is not None:
            item["caption"] = _strip_prefix(caption, ds)
        if status is not None:
            if status not in ("keep", "reject"):
                raise LoraTrainError(t("status ist keep oder reject.", "status is keep or reject."))
            item["status"] = status
        _save_dataset(ds)
    return item


def remove_image(ds_id: str, file: str) -> dict[str, Any]:
    with _lock:
        ds = load_dataset(ds_id)
        if not _FILE.match(file) or not any(im["file"] == file for im in ds["images"]):
            raise LookupError(t(f"Unbekanntes Bild: {file}", f"Unknown image: {file}"))
        ds["images"] = [im for im in ds["images"] if im["file"] != file]
        (DATASETS / ds_id / file).unlink(missing_ok=True)
        _save_dataset(ds)
    return ds


def _edit_graph(prompt: str, image: str | None, width: int, height: int, seed: int) -> dict[str, Any]:
    """Wie ComfyUIs Vorlage image_qwen_image_edit_2511 (Shift 3,1, CFGNorm, index_timestep_zero) mit der
    Lightning-LoRA; die Ausgabegröße kommt aus einem leeren Latent, nicht aus der Vorlage. Ohne Bild (image=None)
    zeichnet das Modell nur nach der Beschreibung."""
    edit, lightning = (Path(f["file"]).name for f in EDIT_FILES)
    graph = {
        "1": {"class_type": "UNETLoader", "inputs": {"unet_name": edit, "weight_dtype": "default"}},
        "2": {"class_type": "CLIPLoader", "inputs": {"clip_name": TE_FP8, "type": "qwen_image", "device": "default"}},
        "3": {"class_type": "VAELoader", "inputs": {"vae_name": VAE}},
        "5": {"class_type": "ModelSamplingAuraFlow", "inputs": {"model": ["1", 0], "shift": 3.1}},
        "6": {"class_type": "CFGNorm", "inputs": {"model": ["5", 0], "strength": 1.0}},
        "7": {"class_type": "LoraLoaderModelOnly", "inputs": {"model": ["6", 0], "lora_name": lightning,
                                                              "strength_model": 1.0}},
        "10": {"class_type": "LoadImage", "inputs": {"image": image}},
        "11": {"class_type": "FluxKontextImageScale", "inputs": {"image": ["10", 0]}},
        "12": {"class_type": "TextEncodeQwenImageEditPlus", "inputs": {"clip": ["2", 0], "vae": ["3", 0],
                                                                       "image1": ["11", 0], "prompt": prompt}},
        "13": {"class_type": "TextEncodeQwenImageEditPlus", "inputs": {"clip": ["2", 0], "vae": ["3", 0],
                                                                       "image1": ["11", 0], "prompt": ""}},
        "14": {"class_type": "FluxKontextMultiReferenceLatentMethod",
               "inputs": {"conditioning": ["12", 0], "reference_latents_method": "index_timestep_zero"}},
        "15": {"class_type": "FluxKontextMultiReferenceLatentMethod",
               "inputs": {"conditioning": ["13", 0], "reference_latents_method": "index_timestep_zero"}},
        "16": {"class_type": "EmptySD3LatentImage", "inputs": {"width": width, "height": height, "batch_size": 1}},
        "17": {"class_type": "KSampler", "inputs": {"model": ["7", 0], "positive": ["14", 0], "negative": ["15", 0],
                                                    "latent_image": ["16", 0], "seed": seed, "steps": 8, "cfg": 1.0,
                                                    "sampler_name": "euler", "scheduler": "simple", "denoise": 1.0}},
        "18": {"class_type": "VAEDecode", "inputs": {"samples": ["17", 0], "vae": ["3", 0]}},
        "19": {"class_type": "SaveImage", "inputs": {"images": ["18", 0], "filename_prefix": "nvai_lora_ds"}},
    }
    if image is None:
        for key in ("10", "11"):
            graph.pop(key)
        for key in ("12", "13"):
            graph[key]["inputs"].pop("image1")
    return graph


async def _drafts(job: Job, ctx: jobs.JobContext) -> list[str]:
    """Entwürfe der Figur, frontal und ganz: aus der Skizze (falls da) und der Beschreibung, sonst nur aus der
    Beschreibung. Der Nutzer wählt einen davon als Vorlage."""
    p = job.params
    ds = load_dataset(p["dataset_id"])
    notes = " ".join((p.get("notes") if p.get("notes") is not None else ds.get("notes") or "").split())
    if not ds.get("sketch") and not notes:
        raise LoraTrainError(t("Für Entwürfe braucht es eine Skizze oder eine Beschreibung der Figur.",
                               "Drafts need a sketch or a description of the character."))
    await jobs._ensure_backend(ctx)
    staged = comfy.stage_input(DATASETS / ds["id"] / ds["sketch"]) if ds.get("sketch") else None
    prompt = " ".join(x for x in ((DRAFT_FROM_IMAGE if staged else ""), notes, DRAFT_POSE) if x)
    count = max(1, min(int(p.get("count") or 4), 12))
    base_seed = int(p.get("seed") or (int(time.time()) % 90000) * 10)
    for n in range(count):
        seed = base_seed + n
        ctx.progress(n / count, t(f"Entwurf {n + 1} von {count}", f"draft {n + 1} of {count}"))

        def on_progress(frac: float, stage: str, n: int = n) -> None:
            ctx.progress((n + frac) / count, stage)

        comfy.set_loaded_model("Qwen-Image-Edit-2511")
        paths = await comfy.run_workflow(_edit_graph(prompt, staged, *PORTRAIT, seed), on_progress=on_progress,
                                         timeout=900)
        if not paths:
            raise RuntimeError(t("ComfyUI lieferte kein Bild.", "ComfyUI returned no image."))
        with _lock:
            ds = load_dataset(ds["id"])
            numbers = [int(m.group(1)) for d in ds.get("drafts", []) if (m := re.fullmatch(r"entwurf_(\d+)\.png",
                                                                                           d["file"]))]
            name = f"entwurf_{max(numbers, default=0) + 1:03d}.png"
            shutil.copyfile(paths[0], DATASETS / ds["id"] / name)
            ds.setdefault("drafts", []).append({"file": name, "seed": seed, "prompt": prompt,
                                                "from_sketch": bool(staged), "added": time.time()})
            ds["drafts"] = ds["drafts"][-MAX_DRAFTS:]
            _save_dataset(ds)
        for path in paths:
            path.unlink(missing_ok=True)
        jobs.publish({"type": "lora.changed", "dataset_id": ds["id"]})
    return []


async def _dataset_from_template(job: Job, ctx: jobs.JobContext) -> list[str]:
    """Bilder aus der Vorlage: je Haltung ein Bild (replace: dieselben Haltungen wie die genannten Bilder, neuer Seed).
    Mit sources nehmen die genannten Bilder des Datensatzes reihum die Rolle der Vorlage ein („weitere aus
    ausgewählten“). mode=drafts erzeugt stattdessen Entwürfe."""
    p = job.params
    if p.get("mode") == "drafts":
        return await _drafts(job, ctx)
    ds = load_dataset(p["dataset_id"])
    sources = [f for f in (p.get("sources") or []) if any(im["file"] == f for im in ds["images"])]
    if not ds.get("template") and not sources:
        raise LoraTrainError(t("Erst eine Vorlage wählen.", "Choose a template first."))
    if not status()["template_ready"]:
        raise LoraTrainError(t("Für Bilder aus der Vorlage fehlen Dateien (Qwen-Image-Edit-2511 oder Qwen-Image-2512).",
                               "Files for images from the template are missing (Qwen-Image-Edit-2511 or "
                               "Qwen-Image-2512)."))
    plan: list[tuple[int, int]] = []   # (Haltung, Versuch)
    replace = p.get("replace") or []
    if replace:
        for name in replace:
            item = next((im for im in ds["images"] if im["file"] == name), None)
            if item is not None and item.get("pose") is not None:
                plan.append((int(item["pose"]), int(item.get("attempt", 0)) + 1))
    else:
        done = {int(im["pose"]) for im in ds["images"] if im.get("pose") is not None}
        wanted = [i for i in range(len(POSES)) if i not in done] or list(range(len(POSES)))
        plan = [(i, 0) for i in wanted[: max(1, min(int(p.get("count") or len(POSES)), len(POSES)))]]
    if not plan:
        return []
    await jobs._ensure_backend(ctx)
    refs = [(f, comfy.stage_input(DATASETS / ds["id"] / f)) for f in sources] or \
        [(None, comfy.stage_input(DATASETS / ds["id"] / ds["template"]))]
    notes = " ".join((p.get("notes") if p.get("notes") is not None else ds.get("notes") or "").split())
    base_seed = int(p.get("seed") or 50000)
    for n, (pose, attempt) in enumerate(plan):
        caption, sentence, (w, h) = POSES[pose]
        prompt = " ".join(x for x in (SAME, notes, sentence) if x)
        ref_file, staged = refs[n % len(refs)]
        if ref_file:  # anderes Ausgangsbild, anderer Seed als aus der Vorlage
            attempt += 1 + n % 7
        seed = base_seed + pose * 101 + attempt * 7919
        ctx.progress(n / len(plan), t(f"Bild {n + 1} von {len(plan)}: {caption}",
                                      f"image {n + 1} of {len(plan)}: {caption}"))

        def on_progress(frac: float, stage: str, n: int = n) -> None:
            ctx.progress((n + frac) / len(plan), stage)

        comfy.set_loaded_model("Qwen-Image-Edit-2511")
        paths = await comfy.run_workflow(_edit_graph(prompt, staged, w, h, seed), on_progress=on_progress,
                                         timeout=900)
        if not paths:
            raise RuntimeError(t("ComfyUI lieferte kein Bild.", "ComfyUI returned no image."))
        with _lock:
            ds = load_dataset(ds["id"])
            item = _add_file(ds, paths[0], caption, "template", model_id="qwen-image-edit-2511")
            item.update({"pose": pose, "attempt": attempt, "seed": seed, "prompt": prompt})
            if ref_file:
                item["ref"] = ref_file
            _save_dataset(ds)
        for path in paths:
            path.unlink(missing_ok=True)
        jobs.publish({"type": "lora.changed", "dataset_id": ds["id"]})
    return []


# ---------------------------------------------------------------------------------------------------- Läufe

def _run_dir(run_id: str) -> Path:
    if not _RUN_ID.match(run_id or "") or not (OUTPUT / run_id).is_dir():
        raise LookupError(t(f"Unbekanntes Training: {run_id}", f"Unknown training: {run_id}"))
    return OUTPUT / run_id


def _epoch(path: Path, trigger: str) -> int | None:
    m = re.fullmatch(re.escape(trigger) + r"-(\d+)", path.stem)
    return int(m.group(1)) if m else None


def checkpoints(run: dict[str, Any]) -> list[dict[str, Any]]:
    """Zwischenstände eines Laufs, nach Epoche; der Endstand (ohne Nummer) bekommt die Zahl der Epochen."""
    folder = OUTPUT / run["id"]
    out = []
    for f in folder.glob("*.safetensors"):
        ep = _epoch(f, run["trigger"])
        if ep is None and f.stem != run["trigger"]:
            continue
        final = ep is None
        out.append({"file": f.name, "epoch": ep if not final else int(run.get("settings", {}).get("epochs") or 0),
                    "final": final, "size_mb": round(f.stat().st_size / 1024**2)})
    return sorted(out, key=lambda c: (c["epoch"], c["final"]))


def load_run(run_id: str) -> dict[str, Any]:
    folder = _run_dir(run_id)
    meta = folder / "run.json"
    if meta.exists():
        run = json.loads(meta.read_text(encoding="utf-8"))
    else:  # Lauf von Hand (etwa die Somi-LoRAs vom 15.11.): Auslösewort = Ordnername
        run = {"id": run_id, "trigger": run_id, "name": run_id, "status": "done", "settings": {}, "class_word": ""}
    run["checkpoints"] = checkpoints(run)
    run.setdefault("tests", {})
    return run


def _save_run(run: dict[str, Any]) -> None:
    data = {k: v for k, v in run.items() if k != "checkpoints"}
    _write_json(OUTPUT / run["id"] / "run.json", data)


def _update_run(run_id: str, **fields: Any) -> dict[str, Any]:
    """Felder eines Laufs setzen, ohne parallele Änderungen (Pause, Fortschritt, Tests) zu überschreiben."""
    with _run_lock:
        run = load_run(run_id)
        run.update(fields)
        _save_run(run)
    return run


def _dir_mb(path: Path) -> int:
    return round(sum(f.stat().st_size for f in path.rglob("*") if f.is_file()) / 1024**2)


def _state_ok(path: Path) -> bool:
    """Vollständiger accelerate-Zustand: Optimierer und Zufallszustand geschrieben (ein beim Speichern beendeter
    Prozess hinterlässt einen halben Ordner)."""
    return path.is_dir() and (path / "optimizer.bin").exists() and any(path.glob("random_states*"))


def list_runs() -> list[dict[str, Any]]:
    out = []
    if OUTPUT.exists():
        for folder in OUTPUT.iterdir():
            if folder.is_dir() and _RUN_ID.match(folder.name):
                with contextlib.suppress(OSError, ValueError, LookupError):
                    run = load_run(folder.name)
                    if run["checkpoints"] or run.get("status") in ("scheduled", "queued", "running", "error",
                                                                   "cancelled", "paused"):
                        out.append({k: v for k, v in run.items() if k not in ("loss", "quick", "captions")})
    return sorted(out, key=lambda r: -(r.get("started") or r.get("queued") or (OUTPUT / r["id"]).stat().st_mtime))


def delete_run(run_id: str) -> None:
    run = load_run(run_id)
    if run.get("status") in ("queued", "running"):
        raise LoraTrainError(t("Das Training läuft noch.", "The training is still running."))
    _PAUSE.pop(run_id, None)
    shutil.rmtree(OUTPUT / run_id)
    shutil.rmtree(TRAIN / run_id, ignore_errors=True)
    shutil.rmtree(CACHE / run_id, ignore_errors=True)


def _free_run_id(trigger: str) -> str:
    run_id, n = trigger, 2
    while (OUTPUT / run_id).exists():
        run_id, n = f"{trigger}_{n}", n + 1
    return run_id


def estimate(images: int, epochs: int, checkpoints_: int, prompts: int = 2, test: bool = True) -> int:
    secs = images * epochs * SECONDS_PER_STEP + images * TE_SECONDS_PER_CAPTION + 60
    if test:
        secs += (checkpoints_ + 1) * prompts * TEST_SECONDS_PER_IMAGE
    return int(secs)


async def submit_training(ds_id: str, epochs: int, lr: str, rank: int, save_every: int, test: bool,
                          prompts: list[str] | None, alpha: float | None = None,
                          start_at: float | None = None) -> Job | dict[str, Any]:
    """Training einreihen; mit start_at in der Zukunft nur vormerken (Status „scheduled“), der Planer reiht es zur
    Startzeit ein. Bis dahin lässt sich der Datensatz weiter bearbeiten: Es zählen die Bilder beim Start."""
    st = status()
    if not st["ready"]:
        raise LoraTrainError(t("Zum Training fehlt noch etwas (Trainer, bf16-Gewichte oder Qwen-Image-2512): "
                               "oben unter „Einrichten“.",
                               "Something is still missing for training (trainer, bf16 weights or Qwen-Image-2512): "
                               "see “Set up” above."))
    ds = load_dataset(ds_id)
    keep = [im for im in ds["images"] if im.get("status") != "reject"]
    if len(keep) < MIN_IMAGES:
        raise LoraTrainError(t(f"Zu wenige Bilder: {len(keep)} von mindestens {MIN_IMAGES} (gut sind 20 bis 30).",
                               f"Too few images: {len(keep)} of at least {MIN_IMAGES} (20 to 30 work well)."))
    try:
        float(lr)
    except ValueError:
        raise LoraTrainError(t(f"Lernrate unlesbar: {lr}", f"Learning rate unreadable: {lr}")) from None
    epochs, rank, save_every = max(1, min(int(epochs), 100)), max(4, min(int(rank), 128)), max(1, int(save_every))
    alpha = float(alpha) if alpha else float(rank)
    alpha = int(alpha) if alpha.is_integer() else alpha
    run_id = _free_run_id(ds["trigger"])
    (OUTPUT / run_id).mkdir(parents=True)
    run = {"id": run_id, "dataset_id": ds_id, "name": ds["name"], "trigger": ds["trigger"],
           "class_word": ds.get("class_word", ""), "base": "qwenimage", "images": len(keep),
           "settings": {"epochs": epochs, "lr": lr, "rank": rank, "alpha": alpha, "save_every": save_every},
           "status": "queued", "queued": time.time(), "test_prompts": prompts or [], "tests": {},
           "test_after": bool(test), "lang": i18n.lang()}
    if start_at and start_at > time.time() + 60:
        run.update({"status": "scheduled", "start_at": float(start_at)})
        _save_run(run)
        jobs.publish({"type": "lora.changed", "run_id": run_id})
        return {**run, "scheduled": True}
    _save_run(run)
    job = await jobs.submit("lora_train", {"run_id": run_id, "dataset_id": ds_id, "test": bool(test)})
    run["job_id"] = job.id
    _save_run(run)
    return job


async def _start_due() -> None:
    now = time.time()
    for run in await asyncio.to_thread(list_runs):
        if run.get("status") != "scheduled" or (run.get("start_at") or 0) > now:
            continue
        # Der Planer läuft ohne Anfrage (sonst Englisch): Meldungen und Auftrag in der Sprache beim Vormerken.
        # Nur einzelne Felder setzen: list_runs lässt loss, quick und captions weg; zurückgeschrieben gingen sonst
        # Verlustkurve, Schnelltests und der Abgleich geänderter Bildbeschreibungen beim Fortsetzen verloren.
        with i18n.language(run.get("lang")):
            if load_run(run["id"]).get("status") != "scheduled":  # inzwischen zurückgestellt
                continue
            try:
                ds = load_dataset(run["dataset_id"])
            except LookupError:
                _update_run(run["id"], status="error", error=t("Datensatz gelöscht.", "Dataset deleted."))
                jobs.publish({"type": "lora.changed", "run_id": run["id"]})
                continue
            images = len([im for im in ds["images"] if im.get("status") != "reject"])
            job = await jobs.submit("lora_train", {"run_id": run["id"], "dataset_id": run["dataset_id"],
                                                   "test": bool(run.get("test_after", True)),
                                                   "resume": bool(run.get("resume_pending"))})
            _update_run(run["id"], status="queued", queued=now, job_id=job.id, images=images)
        jobs.publish({"type": "lora.changed", "run_id": run["id"]})


_scheduler: asyncio.Task | None = None


async def _scheduler_loop() -> None:
    while True:
        try:
            await _start_due()
        except Exception:  # noqa: BLE001 - der Planer soll weiterlaufen
            traceback.print_exc()
        await asyncio.sleep(20)


def _reconcile_runs() -> None:
    """Beim Start: Läufe, die beim Beenden noch liefen oder warteten (Absturz, Neustart von Windows), haben keinen
    Auftrag mehr (jobs._requeue_orphans bricht alle ab). Ohne Abgleich blieben sie für immer auf „läuft“: Fortsetzen,
    Löschen und „Zustand löschen“ lehnten ab. Was der letzte Abschnitt noch schrieb, wird vorher eingeordnet."""
    if not OUTPUT.exists():
        return
    for folder in OUTPUT.iterdir():
        if not (folder.is_dir() and _RUN_ID.match(folder.name) and (folder / "run.json").exists()):
            continue
        try:
            run = load_run(folder.name)
            if run.get("status") not in ("running", "queued"):
                continue
            segs = run.get("segments") or []
            if run.get("status") == "running" and segs:
                s = run.get("settings") or {}
                first = int(segs[-1].get("from_epoch") or 0)
                _sync_outputs(run["id"], f"{run['trigger']}__s{first}", first, int(s.get("epochs") or 0),
                              int(s.get("save_every") or 1))
            st = load_run(folder.name).get("state")
            with i18n.language(run.get("lang")):
                note = (t(f"Durch einen Neustart unterbrochen; Fortsetzen macht nach Epoche {st['epoch']} weiter.",
                          f"Interrupted by a restart; resume continues after epoch {st['epoch']}.") if st else
                        t("Durch einen Neustart unterbrochen, bevor ein Haltepunkt gespeichert war; Fortsetzen "
                          "beginnt von vorn.",
                          "Interrupted by a restart before a checkpoint was saved; resume starts over."))
            _update_run(run["id"], status="cancelled", finished=time.time(), live=None, pause=None, note=note)
        except Exception:  # noqa: BLE001 - ein kaputter Lauf darf den Start nicht verhindern
            traceback.print_exc()


def start_scheduler() -> None:
    """Beim Start der App: hängende Läufe abgleichen, dann vorgemerkte Trainings zur Startzeit einreihen (auch nach
    einem Neustart)."""
    global _scheduler
    if _scheduler is None or _scheduler.done():
        _reconcile_runs()
        _scheduler = asyncio.create_task(_scheduler_loop())


def _collect_images(run: dict[str, Any], ds: dict[str, Any]) -> tuple[Path, dict[str, str]]:
    """Die behaltenen Bilder mit Bildbeschreibung in einen Trainingsordner; liefert dazu Datei → Beschreibung."""
    dst = TRAIN / run["id"]
    if dst.exists():
        shutil.rmtree(dst)
    dst.mkdir(parents=True)
    prefix = ", ".join(x for x in (ds["trigger"], ds.get("class_word") or "") if x)
    captions: dict[str, str] = {}
    for im in ds["images"]:
        if im.get("status") == "reject":
            continue
        src = DATASETS / ds["id"] / im["file"]
        shutil.copyfile(src, dst / im["file"])
        caption = ", ".join(x for x in (prefix, im.get("caption") or "") if x)
        (dst / f"{Path(im['file']).stem}.txt").write_text(caption + "\n", encoding="utf-8")
        captions[im["file"]] = caption
    return dst, captions


def _toml(run: dict[str, Any], images: Path, keep_cache: bool = False) -> Path:
    """keep_cache: beim Fortsetzen bleiben Latents und Text-Encoder-Ausgaben (fehlende rechnet --skip_existing nach,
    musubi entfernt die von Bildern, die nicht mehr im Datensatz sind)."""
    cache = CACHE / run["id"]
    if cache.exists() and not keep_cache:
        shutil.rmtree(cache)
    cache.mkdir(parents=True, exist_ok=True)
    path = TRAIN / f"{run['id']}.toml"
    path.write_text(
        "[general]\nresolution = [1024, 1024]\ncaption_extension = \".txt\"\nbatch_size = 1\nenable_bucket = true\n"
        "bucket_no_upscale = false\n\n[[datasets]]\n"
        f"image_directory = \"{images.as_posix()}\"\ncache_directory = \"{cache.as_posix()}\"\nnum_repeats = 1\n",
        encoding="utf-8")
    return path


_STEPS = re.compile(r"steps:\s*\d+%\|[^|]*\|\s*(\d+)/(\d+)\s*\[([\d:]+)<([\d:?]+)(?:,\s*([\d.]+)s/it)?"
                    r"(?:,\s*avr_loss=([\d.]+))?")
_TQDM = re.compile(r"(\d+)/(\d+)\s*\[")
_TQDM_OPEN = re.compile(r"(\d+)it \[[\d:]+,\s*([\d.]+)s/it")  # ohne Gesamtzahl (Text-Encoder-Cache): „15it [04:13, 16.90s/it]“


def _kill_tree(proc: asyncio.subprocess.Process) -> None:
    if proc.returncode is not None:
        return
    if sys.platform == "win32":
        # accelerate launch startet das Training als Kindprozess; nur /T beendet beide
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(proc.pid)], capture_output=True,
                       creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    with contextlib.suppress(ProcessLookupError):
        proc.kill()


async def _run(cmd: list[Any], ctx: jobs.JobContext, log: Path, base: float, span: float, title: str,
               env_extra: dict[str, str] | None = None, on_line: Any = None, total: int | None = None,
               should_stop: Any = None) -> bool:
    """Ein Schritt als Prozess; tqdm-Zeilen werden zu Fortschritt, alles geht ins Protokoll. total: Zahl der Einheiten,
    wenn tqdm keine nennt (Text-Encoder-Cache: eine Bildbeschreibung je „it“). should_stop: wird nach jeder Zeile
    gefragt; True beendet den Prozess (Pause) und liefert True statt eines Fehlers."""
    ctx.progress(base, title)  # sofort zeigen, welcher Schritt läuft (vorher blieb die Anzeige beim vorigen stehen)
    LOGS.mkdir(parents=True, exist_ok=True)
    # ungepuffert: musubi schreibt „epoch N/M“ mit print (gepuffert), den Fortschritt über stderr (sofort)
    env = {**os.environ, "PYTHONUTF8": "1", "PYTHONIOENCODING": "utf-8", "PYTHONUNBUFFERED": "1", **(env_extra or {})}
    for key in ("PYTHONPATH", "PYTHONHOME", "VIRTUAL_ENV"):
        env.pop(key, None)
    if gpu.multi_gpu() and not gpu.cpu_mode():
        # mehrere Karten: dieselbe, die _free_gpu räumt (sonst rechnete accelerate auf Karte 0)
        env["CUDA_VISIBLE_DEVICES"] = str(gpu.device_for("image"))
    cwd = TOOL if TOOL.exists() else ROOT
    with log.open("a", encoding="utf-8") as fh:
        fh.write(f"\n=== {title} {time.strftime('%Y-%m-%d %H:%M:%S')}\n{' '.join(map(str, cmd))}\n")
        proc = await asyncio.create_subprocess_exec(
            *[str(c) for c in cmd], cwd=str(cwd), env=env, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        tail: list[str] = []
        stopped = False
        try:
            assert proc.stdout is not None
            buf = ""
            while True:
                if should_stop is not None and should_stop():
                    stopped = True
                    fh.write(f"=== angehalten {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
                    _kill_tree(proc)
                    break
                try:
                    chunk = await asyncio.wait_for(proc.stdout.read(4096), timeout=5)
                except asyncio.TimeoutError:
                    continue  # nichts Neues: erneut fragen, ob angehalten werden soll
                if not chunk:
                    break
                buf += chunk.decode("utf-8", errors="replace")
                parts = re.split(r"[\r\n]", buf)
                buf = parts.pop()
                for line in parts:
                    line = line.rstrip()
                    if not line:
                        continue
                    fh.write(line + "\n")
                    tail = (tail + [line])[-25:]
                    if on_line is not None:
                        on_line(line)
                        continue
                    m = _TQDM.search(line)
                    if m and int(m.group(2)):
                        ctx.progress(base + span * int(m.group(1)) / int(m.group(2)),
                                     f"{title}: {m.group(1)}/{m.group(2)}")
                    elif total and (m := _TQDM_OPEN.search(line)):
                        done = min(int(m.group(1)), total)
                        left = max(0, total - done) * float(m.group(2))
                        ctx.progress(base + span * done / total,
                                     t(f"{title}: {done}/{total}, noch {int(left // 60)} min",
                                       f"{title}: {done}/{total}, {int(left // 60)} min left"))
                fh.flush()
            rc = await proc.wait()
        finally:
            _kill_tree(proc)
    if stopped:
        return True
    if rc != 0:
        text = "\n".join(tail[-12:])
        if "out of memory" in text.lower():
            raise RuntimeError(t(f"{title}: Grafikspeicher voll. Andere Programme, die die Karte nutzen, schließen "
                                 f"und neu starten. Protokoll: {log}",
                                 f"{title}: graphics memory full. Close other programs that use the card and start "
                                 f"again. Log: {log}"))
        raise RuntimeError(t(f"{title} gescheitert (Code {rc}). Protokoll: {log}\n{text[-900:]}",
                             f"{title} failed (code {rc}). Log: {log}\n{text[-900:]}"))
    return False


async def _free_gpu(ctx: jobs.JobContext) -> None:
    """Grafikspeicher für das Training räumen: ComfyUI entladen, Mesh- und Stimm-Worker entladen."""
    ctx.progress(0.0, t("gibt den Grafikspeicher frei", "freeing graphics memory"))
    with contextlib.suppress(Exception):
        if await comfy.is_running():
            await comfy.free_memory()
            comfy.set_loaded_model(None)
    for w in mesh_workers.all_workers():
        with contextlib.suppress(Exception):
            if await w.is_running():
                await w.unload()


def _sync_outputs(run_id: str, seg: str, offset: int, total: int, save_every: int, final: bool = False) -> None:
    """Dateien eines Abschnitts einordnen: musubi zählt nach einem Fortsetzen ab Epoche 1 und schreibt jede Epoche
    (für den Zustand). Behalten werden die Zwischenstände im Raster „alle save_every“ unter ihrer echten Epoche
    (<trigger>-<epoche>), der Endstand als <trigger>.safetensors und nur der neueste vollständige Zustand."""
    folder = OUTPUT / run_id
    with _run_lock:
        run = load_run(run_id)
        trig = run["trigger"]
        pattern = re.compile(re.escape(seg) + r"-(\d+)")
        for f in folder.glob(f"{seg}-*.safetensors"):
            m = pattern.fullmatch(f.stem)
            if not m:
                continue
            g = offset + int(m.group(1))
            if g % max(1, save_every) == 0 and g < total:
                os.replace(f, folder / f"{trig}-{g:06d}.safetensors")
            else:
                f.unlink(missing_ok=True)
        fin = folder / f"{seg}.safetensors"
        if final and fin.exists():
            os.replace(fin, folder / f"{trig}.safetensors")
        states: list[tuple[int, Path]] = []
        state_re = re.compile(r"(.+)-(\d+)-state")
        for d in folder.glob("*-state"):
            if not _state_ok(d):
                continue
            if d.name == f"{seg}-state":
                states.append((total, d))  # Zustand am Ende des Abschnitts
            elif (m := state_re.fullmatch(d.name)) and m.group(1) == seg:
                states.append((offset + int(m.group(2)), d))
            elif (run.get("state") or {}).get("dir") == d.name:
                states.append((int(run["state"]["epoch"]), d))
        if states:
            g, d = max(states, key=lambda x: x[0])
            run["state"] = {"dir": d.name, "epoch": g, "size_mb": _dir_mb(d)}
            run["epochs_done"] = g
            for other in folder.glob("*-state"):
                if other.is_dir() and other != d:
                    shutil.rmtree(other, ignore_errors=True)
        _save_run(run)


async def _train(job: Job, ctx: jobs.JobContext) -> list[str]:
    """Ein Trainingsabschnitt: neu (ab Epoche 0 oder ab einem Zwischenstand eines anderen Laufs, epoch_base) oder
    fortgesetzt (resume: ab dem gespeicherten Zustand). Hält auf Wunsch nach einer Epoche oder sofort an."""
    p = job.params
    run_id = p["run_id"]
    run = load_run(run_id)
    ds = load_dataset(p["dataset_id"])
    resume = bool(p.get("resume")) and bool(run.get("state"))
    start_epoch = int(run["state"]["epoch"]) if resume else int(run.get("epoch_base") or 0)
    s = run["settings"]
    total = int(s["epochs"])
    save_every = max(1, int(s["save_every"]))
    if total <= start_epoch:
        raise LoraTrainError(t(f"Nichts zu trainieren: {start_epoch} von {total} Epochen sind schon fertig.",
                               f"Nothing to train: {start_epoch} of {total} epochs are already done."))
    _PAUSE.pop(run_id, None)
    now = time.time()
    log = LOGS / f"{run_id}-{time.strftime('%Y%m%d-%H%M')}.log"
    segs = list(run.get("segments") or [])
    segs.append({"start": now, "from_epoch": start_epoch, "log": str(log)})
    run = _update_run(run_id, status="running", started=run.get("started") if resume and run.get("started") else now,
                      resumed=now if resume else None, job_id=job.id, error=None, pause=None, segments=segs,
                      log=str(log), resume_pending=None)
    test = bool(p.get("test"))
    trained = False
    stop = {"epoch": False}

    def should_stop() -> bool:
        return _PAUSE.get(run_id) == "now" or stop["epoch"]

    def pause_now() -> bool:
        return _PAUSE.get(run_id) is not None

    async def paused(message: str) -> list[str]:
        _PAUSE.pop(run_id, None)
        _update_run(run_id, status="paused", paused=time.time(), pause=None, live=None, note=message)
        jobs.publish({"type": "lora.changed", "run_id": run_id})
        return []

    try:
        await _free_gpu(ctx)
        images, captions = await asyncio.to_thread(_collect_images, run, ds)
        if resume:
            # geänderte Bildbeschreibungen: deren Text-Encoder-Ausgabe neu rechnen
            old = run.get("captions") or {}
            for f, cap in captions.items():
                if old.get(f) is not None and old.get(f) != cap:
                    (CACHE / run_id / f"{Path(f).stem}_qi_te.safetensors").unlink(missing_ok=True)
        n_images = len(captions)
        _update_run(run_id, captions=captions, images=n_images)
        cfg = _toml(run, images, keep_cache=resume)
        src = TOOL / "src" / "musubi_tuner"
        py = tool_python()
        train_span = 0.84 if test else 0.92
        if await _run([py, src / "qwen_image_cache_latents.py", "--dataset_config", cfg, "--vae", _vae(),
                       "--model_version", "original", "--skip_existing"], ctx, log, 0.0, 0.01,
                      t("Latents", "latents"), should_stop=pause_now):
            return await paused(t("Vor dem Training angehalten.", "Paused before the training."))
        # Text-Encoder auf dem Prozessor in bf16: --fp8_vl scheitert mit transformers 5.17 (musubi hängt sich an
        # Qwen2RMSNorm, die Klasse heißt jetzt Qwen2_5_VLRMSNorm), bf16 (16,6 GB) passt nicht in 16 GB
        if await _run([py, src / "qwen_image_cache_text_encoder_outputs.py", "--dataset_config", cfg,
                       "--text_encoder", _train_file("te"), "--batch_size", "1", "--model_version", "original",
                       "--device", "cpu", "--skip_existing"], ctx, log, 0.01, 0.07,
                      t("Text-Encoder", "text encoder"), total=n_images, should_stop=pause_now):
            return await paused(t("Vor dem Training angehalten.", "Paused before the training."))
        if pause_now():
            return await paused(t("Vor dem Training angehalten.", "Paused before the training."))

        remaining = total - start_epoch
        steps_per_epoch = n_images
        total_steps = steps_per_epoch * total
        base_step = start_epoch * steps_per_epoch
        seg = f"{run['trigger']}__s{start_epoch}"
        loss_pts = [pt for pt in (run.get("loss") or []) if pt[0] <= base_step] if (resume or start_epoch) else []
        live = {"t_save": 0.0, "epoch": start_epoch}

        def on_line(line: str) -> None:
            # Haltepunkt fertig: accelerate meldet den Zufallszustand als Letztes (über stderr, also sofort)
            if "Random states saved in" in line and "-state" in line:
                with contextlib.suppress(Exception):
                    _sync_outputs(run_id, seg, start_epoch, total, save_every)
                # nur nach einem Epochen-Zustand (<seg>-000005-state) anhalten: den End-Zustand (<seg>-state) schreibt
                # musubi vor dem Endmodell, ein Anhalten dort verlöre die fertige LoRA (Pause in der letzten Epoche)
                if _PAUSE.get(run_id) == "epoch" and re.search(re.escape(seg) + r"-\d+-state", line):
                    stop["epoch"] = True
                jobs.publish({"type": "lora.changed", "run_id": run_id})
                return
            me = _EPOCH_LINE.match(line.strip())
            if me:
                live["epoch"] = start_epoch + int(me.group(1)) - 1
                return
            m = _STEPS.search(line)
            if not m:
                return
            done = int(m.group(1))
            g = base_step + done
            loss = float(m.group(6)) if m.group(6) else None
            if loss is not None and (not loss_pts or loss_pts[-1][0] != g):
                loss_pts.append([g, round(loss, 5)])
            ep = min(total, g // max(1, steps_per_epoch) + (1 if g % max(1, steps_per_epoch) else 0))
            loss_txt = f", {t('Verlust', 'loss')} {loss:.3f}" if loss is not None else ""
            ctx.progress(0.08 + train_span * g / total_steps,
                         t(f"Training: Epoche {ep} von {total}, Schritt {g} von {total_steps}, noch {m.group(4)}{loss_txt}",
                           f"training: epoch {ep} of {total}, step {g} of {total_steps}, {m.group(4)} left{loss_txt}"))
            now_ = time.time()
            if now_ - live["t_save"] > 15:
                live["t_save"] = now_
                with contextlib.suppress(Exception):
                    _update_run(run_id, loss=loss_pts[-LOSS_MAX:],
                                live={"step": g, "steps": total_steps, "epoch": ep, "epochs": total,
                                      "s_per_step": float(m.group(5)) if m.group(5) else None, "eta": m.group(4),
                                      "loss": loss, "time": now_})
                jobs.publish({"type": "lora.changed", "run_id": run_id})

        cmd: list[Any] = [
            tool_accelerate(), "launch", "--num_cpu_threads_per_process", "1", "--mixed_precision", "bf16",
            src / "qwen_image_train_network.py", "--dit", _train_file("dit"), "--vae", _vae(),
            "--text_encoder", _train_file("te"), "--dataset_config", cfg, "--model_version", "original",
            "--sdpa", "--mixed_precision", "bf16", "--timestep_sampling", "shift",
            "--discrete_flow_shift", "2.2", "--weighting_scheme", "none", "--optimizer_type", "adamw8bit",
            "--learning_rate", s["lr"], "--gradient_checkpointing", "--network_module",
            "networks.lora_qwen_image", "--network_dim", s["rank"], "--network_alpha", s.get("alpha", 1),
            "--fp8_base", "--fp8_scaled",
            "--blocks_to_swap", "40", "--seed", str(42 + start_epoch), "--output_dir", OUTPUT / run_id,
            "--output_name", seg, "--max_train_epochs", remaining,
            # jede Epoche ein Zustand zum Fortsetzen; die Zwischenstände sortiert _sync_outputs ins Raster
            "--save_every_n_epochs", "1", "--save_state", "--save_last_n_epochs_state", "1",
            "--save_state_on_train_end"]
        if resume:
            cmd += ["--resume", OUTPUT / run_id / run["state"]["dir"]]
        elif run.get("init_weights"):
            cmd += ["--network_weights", run["init_weights"]]
        stopped = await _run(cmd, ctx, log, 0.08, train_span, t("Training", "training"), on_line=on_line,
                             should_stop=should_stop)
        await asyncio.to_thread(_sync_outputs, run_id, seg, start_epoch, total, save_every, not stopped)
        if stopped:
            _update_run(run_id, loss=loss_pts[-LOSS_MAX:])
            st = load_run(run_id).get("state")
            return await paused(t(f"Angehalten nach Epoche {st['epoch']}; Fortsetzen macht dort weiter."
                                  if st else "Angehalten vor dem ersten Haltepunkt; Fortsetzen beginnt von vorn.",
                                  f"Paused after epoch {st['epoch']}; resume continues there."
                                  if st else "Paused before the first checkpoint; resume starts over."))
        run = _update_run(run_id, status="done", finished=time.time(), loss=loss_pts[-LOSS_MAX:], live=None,
                          pause=None, note=None)
        jobs.publish({"type": "lora.changed", "run_id": run_id})
        trained = True
    except asyncio.CancelledError:
        with contextlib.suppress(Exception):
            _update_run(run_id, status="cancelled", finished=time.time(), live=None, pause=None)
        raise
    except Exception as exc:
        with contextlib.suppress(Exception):
            _update_run(run_id, status="error", error=str(exc)[:1500], finished=time.time(), live=None, pause=None)
        raise
    finally:
        _PAUSE.pop(run_id, None)
        shutil.rmtree(TRAIN / run_id, ignore_errors=True)
        jobs.publish({"type": "lora.changed", "run_id": run_id})
    if test and trained:
        await _tests_after_training(run_id, run, ctx)
    return []


async def _tests_after_training(run_id: str, run: dict[str, Any], ctx: jobs.JobContext) -> None:
    """Probebilder nach dem Training als eigener Schritt: Ein Fehler oder Abbrechen hier lässt den Lauf fertig (vorher
    wurde aus „fertig“ nach Stunden Training „Fehler“ bzw. „abgebrochen“, und „Fortsetzen“ lehnte der Server ab)."""
    if inference_entry() is None:
        _update_run(run_id, note=t("Probebilder übersprungen: Qwen-Image-2512 fehlt (unter „Modelle“).",
                                   "Test images skipped: Qwen-Image-2512 is missing (under “Models”)."))
        jobs.publish({"type": "lora.changed", "run_id": run_id})
        return
    try:
        await _test_run(run, ctx, run.get("test_prompts") or None, 0.92, 0.08)
    except asyncio.CancelledError:
        with contextlib.suppress(Exception):
            _update_run(run_id, note=t("Probebilder abgebrochen; das Training ist fertig.",
                                       "Test images cancelled; the training is finished."))
        jobs.publish({"type": "lora.changed", "run_id": run_id})
        raise
    except Exception as exc:
        with contextlib.suppress(Exception):
            _update_run(run_id, note=t(f"Probebilder gescheitert: {exc}", f"Test images failed: {exc}"))
        jobs.publish({"type": "lora.changed", "run_id": run_id})
        raise


async def request_pause(run_id: str, mode: str) -> dict[str, Any]:
    """Anhalten: „epoch“ nach der laufenden Epoche (nichts geht verloren), „now“ sofort (die angefangene Epoche
    fehlt). Ein wartender oder vorgemerkter Auftrag wird nur zurückgestellt."""
    run = load_run(run_id)
    mode = "now" if mode == "now" else "epoch"
    if run.get("status") == "scheduled":
        return _update_run(run_id, status="paused", start_at=None, note=t("Vormerkung aufgehoben.",
                                                                          "Schedule removed."))
    if run.get("status") == "queued":
        if run.get("job_id"):
            with contextlib.suppress(Exception):
                await jobs.cancel_job(run["job_id"])
        return _update_run(run_id, status="paused", note=t("Zurückgestellt, bevor es anfing.",
                                                           "Held back before it started."))
    if run.get("status") != "running":
        raise LoraTrainError(t("Dieses Training läuft nicht.", "This training is not running."))
    _PAUSE[run_id] = mode
    run = _update_run(run_id, pause=mode)
    jobs.publish({"type": "lora.changed", "run_id": run_id})
    return run


def _need_dataset(run: dict[str, Any]) -> None:
    """Läufe von Hand (ohne run.json, etwa die ersten Somi-LoRAs) haben keinen Datensatz in NVAI-open: Fortsetzen und
    Korrigieren verständlich ablehnen (vorher ein KeyError, den die Route als 404 „dataset_id“ meldete)."""
    if not run.get("dataset_id"):
        raise LoraTrainError(t("Dieses Training wurde außerhalb von NVAI-open angelegt und hat keinen Datensatz hier: "
                               "Fortsetzen und Korrigieren gehen nur mit einem Datensatz. Übernehmen und Probebilder "
                               "gehen.",
                               "This training was made outside NVAI-open and has no dataset here: resume and correct "
                               "need a dataset. Adopt and test images work."))


async def resume_training(run_id: str, epochs: int | None = None, test: bool = True,
                          start_at: float | None = None) -> dict[str, Any]:
    """Fortsetzen ab dem gespeicherten Zustand (mit dem Datensatz, wie er jetzt ist) oder, mit mehr Epochen, ein
    fertiges Training verlängern. Ohne Zustand beginnt es von vorn (die Zwischenspeicher bleiben)."""
    run = load_run(run_id)
    if run.get("status") in ("running", "queued"):
        raise LoraTrainError(t("Das Training läuft schon.", "The training is already running."))
    if not status()["ready"]:
        raise LoraTrainError(t("Zum Training fehlt noch etwas: oben unter „Einrichten“.",
                               "Something is still missing for training: see “Set up” above."))
    _need_dataset(run)
    load_dataset(run["dataset_id"])
    st = run.get("state") or {}
    done = int(st.get("epoch") or 0) if st else int(run.get("epoch_base") or 0)
    old_total = int(run["settings"]["epochs"])
    total = int(epochs or old_total)
    if total <= done:
        raise LoraTrainError(t(f"Schon {done} Epochen trainiert: für mehr die Zahl der Epochen erhöhen.",
                               f"{done} epochs are already trained: raise the number of epochs for more."))
    if total > 200:
        raise LoraTrainError(t("Höchstens 200 Epochen.", "At most 200 epochs."))
    fin = OUTPUT / run_id / f"{run['trigger']}.safetensors"
    with _run_lock:
        run = load_run(run_id)
        if fin.exists() and total != old_total:
            # der bisherige Endstand bleibt als Zwischenstand seiner Epoche erhalten
            new_name = f"{run['trigger']}-{old_total:06d}.safetensors"
            os.replace(fin, OUTPUT / run_id / new_name)
            for a in run.get("adopted") or []:
                if a.get("checkpoint") == fin.name:
                    a["checkpoint"] = new_name
        run["settings"] = {**run["settings"], "epochs": total}
        run.update({"test_after": bool(test), "error": None, "note": None, "lang": i18n.lang()})
        if start_at and start_at > time.time() + 60:
            run.update({"status": "scheduled", "start_at": float(start_at), "resume_pending": bool(st)})
            _save_run(run)
            jobs.publish({"type": "lora.changed", "run_id": run_id})
            return {**run, "scheduled": True}
        run.update({"status": "queued", "queued": time.time(), "start_at": None})
        _save_run(run)
    job = await jobs.submit("lora_train", {"run_id": run_id, "dataset_id": run["dataset_id"], "test": bool(test),
                                           "resume": bool(st)})
    return _update_run(run_id, job_id=job.id)


async def branch_training(run_id: str, checkpoint: str, extra_epochs: int, lr: str, save_every: int | None = None,
                          test: bool = True, prompts: list[str] | None = None,
                          start_at: float | None = None) -> dict[str, Any]:
    """Korrigieren: ein neues Training ab einem Zwischenstand (dessen Gewichte als Anfang, neuer Optimierer), mit
    anderer Lernrate und dem Datensatz, wie er jetzt ist. Rang und Alpha bleiben die des Zwischenstands."""
    run = load_run(run_id)
    ck = next((c for c in run["checkpoints"] if c["file"] == checkpoint), None)
    if ck is None:
        raise LookupError(t(f"Unbekannter Zwischenstand: {checkpoint}", f"Unknown checkpoint: {checkpoint}"))
    try:
        float(lr)
    except ValueError:
        raise LoraTrainError(t(f"Lernrate unlesbar: {lr}", f"Learning rate unreadable: {lr}")) from None
    if not status()["ready"]:
        raise LoraTrainError(t("Zum Training fehlt noch etwas: oben unter „Einrichten“.",
                               "Something is still missing for training: see “Set up” above."))
    _need_dataset(run)
    ds = load_dataset(run["dataset_id"])
    extra = max(1, min(int(extra_epochs), 100))
    new_id = _free_run_id(run["trigger"])
    (OUTPUT / new_id).mkdir(parents=True)
    init = OUTPUT / new_id / "anfang.safetensors"
    try:
        os.link(OUTPUT / run_id / checkpoint, init)
    except OSError:
        shutil.copyfile(OUTPUT / run_id / checkpoint, init)
    settings = {**run["settings"], "epochs": int(ck["epoch"]) + extra, "lr": lr,
                "save_every": max(1, int(save_every or run["settings"].get("save_every") or 5))}
    new = {"id": new_id, "dataset_id": run["dataset_id"], "name": ds["name"], "trigger": run["trigger"],
           "class_word": ds.get("class_word", ""), "base": run.get("base", "qwenimage"),
           "images": len([im for im in ds["images"] if im.get("status") != "reject"]),
           "settings": settings, "status": "queued", "queued": time.time(),
           "test_prompts": prompts or run.get("test_prompts") or [], "tests": {}, "test_after": bool(test),
           "epoch_base": int(ck["epoch"]), "epochs_done": int(ck["epoch"]), "init_weights": str(init),
           "parent": {"run": run_id, "checkpoint": checkpoint, "epoch": int(ck["epoch"])}, "lang": i18n.lang()}
    if start_at and start_at > time.time() + 60:
        new.update({"status": "scheduled", "start_at": float(start_at)})
        _save_run(new)
        jobs.publish({"type": "lora.changed", "run_id": new_id})
        return {**load_run(new_id), "scheduled": True}
    _save_run(new)
    job = await jobs.submit("lora_train", {"run_id": new_id, "dataset_id": run["dataset_id"], "test": bool(test)})
    return _update_run(new_id, job_id=job.id)


def delete_state(run_id: str) -> dict[str, Any]:
    run = load_run(run_id)
    if run.get("status") in ("running", "queued"):
        raise LoraTrainError(t("Das Training läuft noch.", "The training is still running."))
    for d in (OUTPUT / run_id).glob("*-state"):
        shutil.rmtree(d, ignore_errors=True)
    return _update_run(run_id, state=None)


def log_tail(run_id: str, lines: int = 80) -> dict[str, Any]:
    """Letzte Zeilen des Protokolls, ohne die vielen Fortschrittszeilen dazwischen (nur die jüngste davon)."""
    run = load_run(run_id)
    path = Path(run.get("log") or "")
    if not run.get("log") or not path.is_file():
        return {"path": run.get("log"), "lines": []}
    with path.open("rb") as fh:
        fh.seek(0, os.SEEK_END)
        size = fh.tell()
        start = max(0, size - 262144)
        fh.seek(start)
        text = fh.read().decode("utf-8", errors="replace")
    out: list[str] = []
    for line in text.splitlines()[1 if start else 0:]:
        if not line.strip():
            continue
        progress = bool(_TQDM.search(line)) or "it/s]" in line or "s/it]" in line
        if progress and out and out[-1].startswith("\u23f5 "):
            out[-1] = "\u23f5 " + line.strip()
        else:
            out.append(("\u23f5 " if progress else "") + line.rstrip())
    return {"path": str(path), "lines": out[-max(10, min(lines, 400)):]}


def _prompts_for(run: dict[str, Any], prompts: list[str] | None) -> list[str]:
    head = ", ".join(x for x in (run["trigger"], run.get("class_word") or "") if x)
    chosen = [" ".join(p.split()) for p in (prompts or []) if p and p.strip()] or list(TEST_PROMPTS)
    return [p if p.lower().startswith(run["trigger"]) else f"{head}, {p}" for p in chosen[:4]]


async def _test_run(run: dict[str, Any], ctx: jobs.JobContext, prompts: list[str] | None, base: float = 0.0,
                    span: float = 1.0) -> None:
    """Probebilder: je Prompt ohne LoRA und mit jedem Zwischenstand, gleicher Seed, Stärke 1,0."""
    entry = inference_entry()
    if entry is None:
        raise LoraTrainError(t("Für Probebilder fehlt Qwen-Image-2512 (unter „Modelle“).",
                               "Qwen-Image-2512 is missing for test images (under “Models”)."))
    ckpts = run["checkpoints"]
    if not ckpts:
        raise LoraTrainError(t("Dieses Training hat noch keine Zwischenstände.", "This training has no checkpoints yet."))
    full = _prompts_for(run, prompts)
    await jobs._ensure_backend(ctx)
    link_dir = registry.lora_dir() / "_lora_training" / run["id"]
    link_dir.mkdir(parents=True, exist_ok=True)
    out = OUTPUT / run["id"] / "test"
    out.mkdir(exist_ok=True)
    stamp = uuid.uuid4().hex[:6]
    cells: list[tuple[int, dict[str, Any] | None]] = [(k, c) for k in range(len(full)) for c in [None, *ckpts]]
    images: dict[str, list[str]] = {}
    try:
        for c in ckpts:
            target = link_dir / c["file"]
            if not target.exists():
                try:
                    os.link(OUTPUT / run["id"] / c["file"], target)  # harter Link statt 590 MB Kopie
                except OSError:
                    shutil.copyfile(OUTPUT / run["id"] / c["file"], target)
        comfy.set_loaded_model(registry.display_name(entry))
        for n, (k, c) in enumerate(cells):
            label = c["file"] if c else t("ohne LoRA", "without LoRA")
            ctx.progress(base + span * n / len(cells),
                         t(f"Probebild {n + 1} von {len(cells)}: {label}", f"test image {n + 1} of {len(cells)}: {label}"))
            graph, _ = workflows.build(entry, {"prompt": full[k], "width": 896, "height": 1152, "seed": 777 + k,
                                               "batch_size": 1})
            if c:
                # ComfyUI nennt Dateien in Unterordnern mit dem Trenner des Systems (unter Windows Backslash) und prüft
                # lora_name gegen diese Liste
                loras.apply(graph, [{"file": os.path.join("_lora_training", run["id"], c["file"]), "strength": 1.0}])

            def on_progress(frac: float, stage: str, n: int = n) -> None:
                ctx.progress(base + span * (n + frac) / len(cells), stage)

            paths = await comfy.run_workflow(graph, on_progress=on_progress, timeout=900)
            if not paths:
                raise RuntimeError(t("ComfyUI lieferte kein Bild.", "ComfyUI returned no image."))
            key = c["file"] if c else "_ohne"
            name = f"{Path(key).stem}__{k}_{stamp}.png"
            shutil.move(str(paths[0]), out / name)
            for extra in paths[1:]:
                extra.unlink(missing_ok=True)
            images.setdefault(key, []).append(name)
            if len(images.get(key, [])) == len(full):
                jobs.publish({"type": "lora.changed", "run_id": run["id"]})
    finally:
        shutil.rmtree(link_dir, ignore_errors=True)
    with _run_lock:  # wie _update_run: ein gleichzeitiges Übernehmen oder Statuswechsel geht nicht verloren
        run = load_run(run["id"])
        old = run.get("tests") or {}
        for names in (old.get("images") or {}).values():
            for name in names:
                (out / name).unlink(missing_ok=True)
        run["tests"] = {"prompts": full, "images": images, "time": time.time(), "model_id": entry["id"],
                        "size": [896, 1152], "seeds": [777 + k for k in range(len(full))]}
        _save_run(run)
    jobs.publish({"type": "lora.changed", "run_id": run["id"]})


async def _quick_test(run: dict[str, Any], ctx: jobs.JobContext, checkpoint: str, prompt: str,
                      strengths: list[float], seed: int) -> None:
    """Schnelltest: ein Prompt mit einem Zwischenstand in einer oder mehreren Stärken, gleicher Seed."""
    entry = inference_entry()
    if entry is None:
        raise LoraTrainError(t("Für Probebilder fehlt Qwen-Image-2512 (unter „Modelle“).",
                               "Qwen-Image-2512 is missing for test images (under “Models”)."))
    ck = next((c for c in run["checkpoints"] if c["file"] == checkpoint), None)
    if ck is None:
        raise LookupError(t(f"Unbekannter Zwischenstand: {checkpoint}", f"Unknown checkpoint: {checkpoint}"))
    full = _prompts_for(run, [prompt])[0]
    await jobs._ensure_backend(ctx)
    link_dir = registry.lora_dir() / "_lora_training" / run["id"]
    link_dir.mkdir(parents=True, exist_ok=True)
    out = OUTPUT / run["id"] / "test"
    out.mkdir(exist_ok=True)
    target = link_dir / checkpoint
    made: list[dict[str, Any]] = []
    try:
        if not target.exists():
            try:
                os.link(OUTPUT / run["id"] / checkpoint, target)
            except OSError:
                shutil.copyfile(OUTPUT / run["id"] / checkpoint, target)
        comfy.set_loaded_model(registry.display_name(entry))
        for n, strength in enumerate(strengths):
            ctx.progress(n / len(strengths), t(f"Schnelltest {n + 1} von {len(strengths)}: Stärke {strength:g}",
                                               f"quick test {n + 1} of {len(strengths)}: strength {strength:g}"))
            graph, _ = workflows.build(entry, {"prompt": full, "width": 896, "height": 1152, "seed": seed,
                                               "batch_size": 1})
            if strength > 0:
                loras.apply(graph, [{"file": os.path.join("_lora_training", run["id"], checkpoint),
                                     "strength": float(strength)}])

            def on_progress(frac: float, stage: str, n: int = n) -> None:
                ctx.progress((n + frac) / len(strengths), stage)

            paths = await comfy.run_workflow(graph, on_progress=on_progress, timeout=900)
            if not paths:
                raise RuntimeError(t("ComfyUI lieferte kein Bild.", "ComfyUI returned no image."))
            name = f"quick_{uuid.uuid4().hex[:8]}.png"
            shutil.move(str(paths[0]), out / name)
            for extra in paths[1:]:
                extra.unlink(missing_ok=True)
            made.append({"file": name, "checkpoint": checkpoint, "epoch": ck["epoch"], "strength": strength,
                         "prompt": full, "seed": seed, "time": time.time()})
            with _run_lock:
                cur = load_run(run["id"])
                quick = made[::-1] + [q for q in (cur.get("quick") or []) if q["file"] not in {m["file"] for m in made}]
                for old in quick[QUICK_MAX:]:
                    (out / old["file"]).unlink(missing_ok=True)
                cur["quick"] = quick[:QUICK_MAX]
                _save_run(cur)
            jobs.publish({"type": "lora.changed", "run_id": run["id"]})
    finally:
        shutil.rmtree(link_dir, ignore_errors=True)


async def _test(job: Job, ctx: jobs.JobContext) -> list[str]:
    run = load_run(job.params["run_id"])
    if job.params.get("mode") == "quick":
        await _quick_test(run, ctx, job.params["checkpoint"], job.params.get("prompt") or "",
                          [float(x) for x in job.params.get("strengths") or [1.0]], int(job.params.get("seed") or 777))
        return []
    await _test_run(run, ctx, job.params.get("prompts"))
    return []


def adopt(run_id: str, checkpoint: str, name: str = "") -> dict[str, Any]:
    """Einen Zwischenstand als LoRA in den Katalog übernehmen (harter Link, sonst Kopie), Auslösewort als Trigger."""
    run = load_run(run_id)
    ck = next((c for c in run["checkpoints"] if c["file"] == checkpoint), None)
    if ck is None:
        raise LookupError(t(f"Unbekannter Zwischenstand: {checkpoint}", f"Unknown checkpoint: {checkpoint}"))
    src = OUTPUT / run_id / checkpoint
    header = loras.verify_file(src)
    check = registry.inspect_lora(header, checkpoint)
    family = check["family"] or run.get("base") or "qwenimage"
    if not registry.lora_models(family):
        raise LoraTrainError(registry.no_model_for(family))
    folder = registry.lora_dir()
    folder.mkdir(parents=True, exist_ok=True)
    part = folder / f".{db.new_id('upl')}.part"
    try:
        os.link(src, part)
    except OSError:
        shutil.copyfile(src, part)
    digest = hashlib.sha256()
    with src.open("rb") as fh:
        for block in iter(lambda: fh.read(1 << 22), b""):
            digest.update(block)
    epoch = f"e{ck['epoch']:02d}" if ck["epoch"] else "final"
    file_name = loras.file_name(f"{run['trigger']}-{epoch}.safetensors")
    label = (name or "").strip() or f"{run.get('name') or run['trigger']} ({t('Epoche', 'epoch')} {ck['epoch']})"
    try:
        entry, _existing = registry.add_upload(part, file_name, family, label, run["trigger"], "",
                                               src.stat().st_size, digest.hexdigest())
    finally:
        part.unlink(missing_ok=True)
    registry.annotate_lora(entry["id"], {"trained": {"run_id": run_id, "checkpoint": checkpoint,
                                                     "epoch": ck["epoch"], "images": run.get("images"),
                                                     "dataset": run.get("name"), "settings": run.get("settings")}})
    entry = registry.get_entry(entry["id"]) or entry  # mit den eben ergänzten Trainingsangaben
    with _run_lock:  # frisch laden: Prüfsumme und Kopie dauern, inzwischen können Probebilder oder Status dazukommen
        cur = load_run(run_id)
        cur.setdefault("adopted", []).append({"checkpoint": checkpoint, "model_id": entry["id"], "time": time.time()})
        _save_run(cur)
    jobs.publish({"type": "models.changed"})
    jobs.publish({"type": "lora.changed", "run_id": run_id})
    return entry


jobs.register("lora_train")(_train)
jobs.register("lora_test")(_test)
jobs.register("lora_dataset")(_dataset_from_template)
jobs.register("lora_setup")(_setup)
jobs.IO_KINDS.add("lora_setup")


# ---------------------------------------------------------------------------------------------------- REST

router = APIRouter(prefix="/api/lora-train")


class DatasetCreate(BaseModel):
    name: str = Field("", max_length=80)
    trigger: str = Field(..., max_length=40)
    class_word: str = Field("", max_length=80)
    notes: str = Field("", max_length=1000)


class DatasetUpdate(BaseModel):
    name: str | None = Field(None, max_length=80)
    trigger: str | None = Field(None, max_length=40)
    class_word: str | None = Field(None, max_length=80)
    notes: str | None = Field(None, max_length=1000)


class AssetsAdd(BaseModel):
    asset_ids: list[str] = Field(..., max_length=200)
    caption: str = Field("", max_length=600)


class FolderAdd(BaseModel):
    path: str = Field(..., max_length=1000)


class TemplateSet(BaseModel):
    asset_id: str


class TemplateGenerate(BaseModel):
    count: int = Field(24, ge=1, le=48)
    notes: str | None = Field(None, max_length=1000)
    replace: list[str] = Field(default_factory=list, max_length=48)
    sources: list[str] = Field(default_factory=list, max_length=48)
    seed: int | None = None


class DraftsRequest(BaseModel):
    count: int = Field(4, ge=1, le=12)
    notes: str | None = Field(None, max_length=1000)
    seed: int | None = None


class SketchSet(BaseModel):
    asset_id: str


class TemplatePick(BaseModel):
    file: str = Field(..., max_length=120)


class ImageUpdate(BaseModel):
    caption: str | None = Field(None, max_length=600)
    status: str | None = None


class TrainRequest(BaseModel):
    epochs: int = Field(DEFAULTS["epochs"], ge=1, le=100)
    lr: str = Field(DEFAULTS["lr"], max_length=12)
    rank: int = Field(DEFAULTS["rank"], ge=4, le=128)
    alpha: float | None = Field(None, ge=0.5, le=256, description="network_alpha; leer = Rang")
    save_every: int = Field(DEFAULTS["save_every"], ge=1, le=100)
    test: bool = True
    prompts: list[str] = Field(default_factory=list, max_length=4)
    start_at: float | None = Field(None, description="Startzeit (Unix-Sekunden); leer = sofort")


class TestRequest(BaseModel):
    prompts: list[str] = Field(default_factory=list, max_length=4)


class QuickTest(BaseModel):
    checkpoint: str = Field(..., max_length=120)
    prompt: str = Field(..., max_length=600)
    strengths: list[float] = Field(default_factory=lambda: [1.0], min_length=1, max_length=4)
    seed: int = 777


class PauseRequest(BaseModel):
    mode: str = Field("epoch", description="epoch: nach der laufenden Epoche, now: sofort")


class ResumeRequest(BaseModel):
    epochs: int | None = Field(None, ge=1, le=200, description="Epochen gesamt; mehr als bisher verlängert")
    test: bool = True
    start_at: float | None = None


class BranchRequest(BaseModel):
    checkpoint: str = Field(..., max_length=120)
    epochs: int = Field(10, ge=1, le=100, description="weitere Epochen ab dem Zwischenstand")
    lr: str = Field(DEFAULTS["lr"], max_length=12)
    save_every: int | None = Field(None, ge=1, le=100)
    test: bool = True
    prompts: list[str] = Field(default_factory=list, max_length=4)
    start_at: float | None = None


class AdoptRequest(BaseModel):
    checkpoint: str
    name: str = Field("", max_length=80)


class SetupRequest(BaseModel):
    parts: list[str] = Field(default_factory=lambda: ["tool", "weights"])


def _http(fn: Any, *args: Any, **kwargs: Any) -> Any:
    try:
        return fn(*args, **kwargs)
    except LookupError as e:
        raise HTTPException(404, str(e).strip("'\"")) from e
    except (LoraTrainError, ValueError) as e:
        raise HTTPException(400, str(e)) from e


@router.get("/status")
async def api_status() -> dict[str, Any]:
    return await asyncio.to_thread(status)


@router.post("/setup", response_model=Job)
async def api_setup(req: SetupRequest) -> Job:
    if gpu.vendor() != "nvidia" and "tool" in req.parts:
        raise HTTPException(400, t("Das Training läuft nur auf NVIDIA-Karten.", "Training runs on NVIDIA cards only."))
    parts = [p for p in req.parts if p in ("tool", "weights", "edit")]
    return await jobs.submit("lora_setup", {"parts": parts})


@router.post("/datasets")
async def api_create(req: DatasetCreate) -> dict[str, Any]:
    return _http(create_dataset, req.name, req.trigger, req.class_word, req.notes)


@router.get("/datasets/{ds_id}")
async def api_dataset(ds_id: str) -> dict[str, Any]:
    return _http(load_dataset, ds_id)


@router.put("/datasets/{ds_id}")
async def api_update(ds_id: str, req: DatasetUpdate) -> dict[str, Any]:
    return _http(update_dataset, ds_id, **req.model_dump())


@router.delete("/datasets/{ds_id}")
async def api_delete(ds_id: str) -> dict[str, Any]:
    _http(delete_dataset, ds_id)
    return {"ok": True}


@router.post("/datasets/{ds_id}/assets")
async def api_add_assets(ds_id: str, req: AssetsAdd) -> dict[str, Any]:
    return _http(add_assets, ds_id, req.asset_ids, req.caption)


@router.post("/datasets/{ds_id}/folder")
async def api_add_folder(ds_id: str, req: FolderAdd) -> dict[str, Any]:
    return await asyncio.to_thread(_http, add_folder, ds_id, req.path)


@router.post("/datasets/{ds_id}/template")
async def api_template(ds_id: str, req: TemplateSet) -> dict[str, Any]:
    return _http(set_template, ds_id, req.asset_id)


@router.post("/datasets/{ds_id}/sketch")
async def api_sketch(ds_id: str, req: SketchSet) -> dict[str, Any]:
    return _http(set_sketch, ds_id, req.asset_id)


@router.post("/datasets/{ds_id}/drafts", response_model=Job)
async def api_drafts(ds_id: str, req: DraftsRequest) -> Job:
    ds = _http(load_dataset, ds_id)
    if not ds.get("sketch") and not (req.notes if req.notes is not None else ds.get("notes")):
        raise HTTPException(400, t("Für Entwürfe braucht es eine Skizze oder eine Beschreibung der Figur.",
                                   "Drafts need a sketch or a description of the character."))
    if not status()["template_ready"]:
        raise HTTPException(400, t("Für Entwürfe fehlen Dateien: oben unter „Einrichten“.",
                                   "Files for drafts are missing: see “Set up” above."))
    return await jobs.submit("lora_dataset", {"dataset_id": ds_id, "mode": "drafts", "count": req.count,
                                              "notes": req.notes, "seed": req.seed})


@router.delete("/datasets/{ds_id}/drafts")
async def api_drafts_clear(ds_id: str, keep: str | None = None) -> dict[str, Any]:
    return _http(clear_drafts, ds_id, keep)


@router.post("/datasets/{ds_id}/template/pick")
async def api_template_pick(ds_id: str, req: TemplatePick) -> dict[str, Any]:
    return _http(pick_template, ds_id, req.file)


@router.post("/datasets/{ds_id}/generate", response_model=Job)
async def api_generate(ds_id: str, req: TemplateGenerate) -> Job:
    ds = _http(load_dataset, ds_id)
    if not ds.get("template") and not req.sources:
        raise HTTPException(400, t("Erst eine Vorlage wählen.", "Choose a template first."))
    if not status()["template_ready"]:
        raise HTTPException(400, t("Für Bilder aus der Vorlage fehlen Dateien: oben unter „Einrichten“.",
                                   "Files for images from the template are missing: see “Set up” above."))
    return await jobs.submit("lora_dataset", {"dataset_id": ds_id, "count": req.count, "notes": req.notes,
                                              "replace": req.replace, "sources": req.sources, "seed": req.seed})


@router.put("/datasets/{ds_id}/images/{file}")
async def api_image(ds_id: str, file: str, req: ImageUpdate) -> dict[str, Any]:
    return _http(update_image, ds_id, file, req.caption, req.status)


@router.delete("/datasets/{ds_id}/images/{file}")
async def api_image_delete(ds_id: str, file: str) -> dict[str, Any]:
    return _http(remove_image, ds_id, file)


@router.post("/datasets/{ds_id}/train")
async def api_train(ds_id: str, req: TrainRequest) -> Any:
    """Sofort: der Auftrag (Job). Mit start_at: der vorgemerkte Lauf mit scheduled=true."""
    try:
        return await submit_training(ds_id, req.epochs, req.lr, req.rank, req.save_every, req.test, req.prompts,
                                     req.alpha, req.start_at)
    except LookupError as e:
        raise HTTPException(404, str(e).strip("'\"")) from e
    except LoraTrainError as e:
        raise HTTPException(400, str(e)) from e


@router.get("/runs/{run_id}")
async def api_run(run_id: str) -> dict[str, Any]:
    return _http(load_run, run_id)


@router.post("/runs/{run_id}/test", response_model=Job)
async def api_test(run_id: str, req: TestRequest) -> Job:
    run = _http(load_run, run_id)
    if not run["checkpoints"]:
        raise HTTPException(400, t("Dieses Training hat noch keine Zwischenstände.",
                                   "This training has no checkpoints yet."))
    if inference_entry() is None:
        raise HTTPException(400, t("Für Probebilder fehlt Qwen-Image-2512 (unter „Modelle“).",
                                   "Qwen-Image-2512 is missing for test images (under “Models”)."))
    return await jobs.submit("lora_test", {"run_id": run_id, "prompts": req.prompts})


@router.post("/runs/{run_id}/quicktest", response_model=Job)
async def api_quicktest(run_id: str, req: QuickTest) -> Job:
    run = _http(load_run, run_id)
    if not any(c["file"] == req.checkpoint for c in run["checkpoints"]):
        raise HTTPException(404, t("Unbekannter Zwischenstand.", "Unknown checkpoint."))
    if inference_entry() is None:
        raise HTTPException(400, t("Für Probebilder fehlt Qwen-Image-2512 (unter „Modelle“).",
                                   "Qwen-Image-2512 is missing for test images (under “Models”)."))
    strengths = [max(0.0, min(3.0, float(x))) for x in req.strengths]
    return await jobs.submit("lora_test", {"run_id": run_id, "mode": "quick", "checkpoint": req.checkpoint,
                                           "prompt": req.prompt, "strengths": strengths, "seed": req.seed})


@router.post("/runs/{run_id}/pause")
async def api_pause(run_id: str, req: PauseRequest) -> dict[str, Any]:
    try:
        return await request_pause(run_id, req.mode)
    except LookupError as e:
        raise HTTPException(404, str(e).strip("'\"")) from e
    except LoraTrainError as e:
        raise HTTPException(400, str(e)) from e


@router.post("/runs/{run_id}/resume")
async def api_resume(run_id: str, req: ResumeRequest) -> dict[str, Any]:
    try:
        return await resume_training(run_id, req.epochs, req.test, req.start_at)
    except LookupError as e:
        raise HTTPException(404, str(e).strip("'\"")) from e
    except LoraTrainError as e:
        raise HTTPException(400, str(e)) from e


@router.post("/runs/{run_id}/branch")
async def api_branch(run_id: str, req: BranchRequest) -> dict[str, Any]:
    try:
        return await branch_training(run_id, req.checkpoint, req.epochs, req.lr, req.save_every, req.test,
                                     req.prompts, req.start_at)
    except LookupError as e:
        raise HTTPException(404, str(e).strip("'\"")) from e
    except LoraTrainError as e:
        raise HTTPException(400, str(e)) from e


@router.delete("/runs/{run_id}/state")
async def api_state_delete(run_id: str) -> dict[str, Any]:
    return await asyncio.to_thread(_http, delete_state, run_id)


@router.get("/runs/{run_id}/log")
async def api_log(run_id: str, lines: int = 80) -> dict[str, Any]:
    return await asyncio.to_thread(_http, log_tail, run_id, lines)


@router.post("/runs/{run_id}/adopt")
async def api_adopt(run_id: str, req: AdoptRequest) -> dict[str, Any]:
    entry = await asyncio.to_thread(_http, adopt, run_id, req.checkpoint, req.name)
    return {"model": (await asyncio.to_thread(registry.to_info, entry)).model_dump()}


@router.delete("/runs/{run_id}")
async def api_run_delete(run_id: str) -> dict[str, Any]:
    await asyncio.to_thread(_http, delete_run, run_id)
    return {"ok": True}


@router.get("/files/{area}/{item}/{name:path}")
async def api_file(area: str, item: str, name: str) -> FileResponse:
    """Bilder eines Datensatzes (datasets/<id>/<datei>) oder Probebilder eines Trainings (runs/<id>/test/<datei>)."""
    if area == "datasets":
        folder = DATASETS / item
        ok = bool(_DS_ID.match(item)) and bool(_FILE.match(name))
    elif area == "runs":
        folder = OUTPUT / item / "test"
        ok = bool(_RUN_ID.match(item)) and name.startswith("test/") and bool(_FILE.match(name[5:]))
        name = name[5:]
    else:
        ok = False
    path = folder / name if ok else None
    if path is None or path.suffix.lower() not in IMAGE_SUFFIXES or not path.is_file():
        raise HTTPException(404, t("Datei nicht gefunden.", "File not found."))
    return FileResponse(path, headers={"Cache-Control": "no-cache"})
