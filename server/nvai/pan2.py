"""PAN 2 (seit 0.5.35): das Weltmodell von MBZUAI/IFM (Apache-2.0), nativ in ComfyUI seit 0.46.0 (comfy/ldm/pan2).

Es simuliert, wie sich eine Szene nach einer beschriebenen Handlung veraendert: aus Text oder aus einem Startbild, 704 x
1248 mit 24 fps, 10 bis 20 s, ohne Ton. Trainiert ist es auf strukturierte Zustandsbeschreibungen (JSON mit video_style,
lighting, perspective_view, subjects_lifecycle, events …); freier Text geht auch, trifft aber weniger genau. Die Dateien
kommen von Comfy-Org (INT8-ConvRot, Text-Encoder Qwen3.5-9B INT8, Wan-2.2-VAE). Einstellungen wie in der Modellkarte:
50 Schritte, Flow-Shift 9, CFG 2,5; der Negativprompt ist der allgemeine aus dem PAN-2-Repo
(inference/pan-prompt-rewriter/assets/generic_negative.txt, Apache-2.0), wie ihn die Autoren mitgeben.

Nutzer 22.11.2026: „super baue neue modelle ein“. Auf 16 GB laeuft es nur mit Auslagern (Modell 26,7 GB): langsam.
"""
from __future__ import annotations

from pathlib import Path
from typing import Any

REPO = "Comfy-Org/PAN2"
MODEL_ID = "pan2-int8"
WORKFLOW = "pan2"
FAMILY = "pan2"
FPS = 24
STEPS = 50
CFG = 2.5
SHIFT = 9.0
DEFAULT_FRAMES = 49   # 2 s: auf 16 GB lange Laufzeiten; PAN 2 kann bis 481 Bilder (20 s)
MIN_FRAMES = 9
MAX_FRAMES = 481
NEGATIVE = Path(__file__).with_name("pan2_negative.txt").read_text(encoding="utf-8").strip()

SIZES = [
    {"label": "1248 × 704 — trainiertes Format (16:9)", "w": 1248, "h": 704},
    {"label": "704 × 1248 — hochkant", "w": 704, "h": 1248},
    {"label": "832 × 480 — schneller, nicht trainiert", "w": 832, "h": 480},
]
SIZE_LABELS = {
    SIZES[0]["label"]: "1248 × 704 — training size (16:9)",
    SIZES[1]["label"]: "704 × 1248 — portrait",
    SIZES[2]["label"]: "832 × 480 — faster, not trained",
}
PROMPT_HINT = (
    "Beschreibt den Zustand der Szene und was passiert. Am genauesten als JSON wie in der Modellkarte (video_style, "
    "lighting, perspective_view, subjects_lifecycle, events); freier Text geht, trifft aber weniger genau. Ohne Ton.")
PROMPT_HINT_EN = (
    "Describes the state of the scene and what happens. Most precise as JSON as on the model card (video_style, "
    "lighting, perspective_view, subjects_lifecycle, events); free text works but is less precise. No sound.")
PLACEHOLDER = ("A first-person view of a kitchen counter: a hand picks up a glass of water and pours it into a pot on "
               "the stove, the water splashes, steam rises.")

FEATURES: dict[str, Any] = {
    "start_image": "optional",
    "fps": FPS,
    "default_frames": DEFAULT_FRAMES, "min_frames": MIN_FRAMES, "max_frames": MAX_FRAMES,
    "frame_step": 4, "frame_rule": "4n+1",
    "negative_prompt": True,
    "sizes": SIZES,
    "recommended": {"size": [1248, 704]},
    "prompt_hint": PROMPT_HINT,
    "placeholder": PLACEHOLDER,
}
# <messreihe> RTX 5060 Ti 16 GB; die Zeilen schreibt die Messung in notizen/video.md fort
TESTED: dict[str, str] = {MODEL_ID: "Gemessen (1 s in 1248 × 704, 50 Schritte): 280 s"}
TESTED_EN: dict[str, str] = {MODEL_ID: "Measured (1 s at 1248 × 704, 50 steps): 280 s"}

MODELS: list[dict[str, Any]] = [{
    "id": MODEL_ID,
    "name": "PAN 2 (INT8, Weltmodell)",
    "kind": "video",
    "family": FAMILY,
    "workflow": WORKFLOW,
    "files": [
        {"repo": REPO, "file": "diffusion_models/pan2_int8_convrot.safetensors", "target": "diffusion_models"},
        {"repo": REPO, "file": "text_encoders/qwen3.5_9b_int8_convrot.safetensors", "target": "text_encoders"},
        {"repo": REPO, "file": "vae/wan2.2_vae.safetensors", "target": "vae"},
    ],
    "size_gb": 37.84,
    "vram_gb": 27,
    "license": "Apache-2.0",
    "commercial_ok": True,
    "best_for": "Was nach einer Handlung passiert: Abläufe, Physik und Ich-Perspektive genau, bis 20 s",
    "description": (
        "Weltmodell von MBZUAI (November 2026): Es simuliert, wie sich eine Szene nach einer beschriebenen Handlung "
        "verändert, aus Text oder aus einem Startbild, in 704 × 1248 mit 24 fps, bis 20 s, ohne Ton. Laut Modellkarte "
        "folgt es Handlungen und mehrstufigen Abläufen genauer als andere offene Videomodelle. Trainiert auf "
        "strukturierte Zustandsbeschreibungen; freier Text geht, trifft aber weniger genau. 29 Milliarden Parameter, "
        "50 Schritte: auf 16 GB nur mit Auslagern und langsam."),
    "pros": ["Apache-2.0, auch kommerziell frei", "Laut Modellkarte genaue Handlungen und Physik, bis 20 s am Stück",
             "Startbild optional"],
    "cons": ["Kein Ton", "29 Milliarden Parameter, 50 Schritte: auf 16 GB nur mit Auslagern, langsam",
             "Am besten mit strukturierter Zustandsbeschreibung als Prompt"],
    "features": {**FEATURES, "tested": TESTED.get(MODEL_ID, "")},
}]

EN: dict[str, dict[str, Any]] = {
    MODEL_ID: {
        "name": "PAN 2 (INT8, world model)",
        "best_for": "What happens after an action: processes, physics and first-person views exactly, up to 20 s",
        "description": (
            "World model by MBZUAI (November 2026): it simulates how a scene changes after a described action, from "
            "text or from a start image, at 704 × 1248 with 24 fps, up to 20 s, without sound. According to the model "
            "card it follows actions and multi-step processes more closely than other open video models. Trained on "
            "structured world-state captions; free text works but is less precise. 29 billion parameters, 50 steps: "
            "on 16 GB only with offloading, and slow."),
        "pros": ["Apache-2.0, free for commercial use as well",
                 "According to the model card exact actions and physics, up to 20 s in one go",
                 "Start image optional"],
        "cons": ["No sound", "29 billion parameters, 50 steps: on 16 GB only with offloading, slow",
                 "Best with a structured world-state caption as the prompt"],
        "features": {"prompt_hint": PROMPT_HINT_EN, "tested": TESTED_EN.get(MODEL_ID, "")},
    },
}


def build(entry: dict[str, Any], p: dict[str, Any]) -> tuple[dict[str, Any], int]:
    """Graph wie die anderen Wan-2.2-Latent-Modelle: Startbild ueber Wan22ImageToVideoLatent (das erste Latent-Bild
    bleibt, PAN2.concat_cond liest es aus der Rauschmaske), KSampler mit CFG, Speichern als MP4 mit CRF. Die
    verlustfreie Kopie haengt workflows.build an.

    Kein ModelSamplingSD3 wie bei Wan: Shift 9 ist in ComfyUIs PAN2-Konfiguration eingebaut, und der Knoten rechnet die
    Zeitschritte mal 1000, PAN 2 erwartet sie zwischen 0 und 1 (multiplier 1.0). Mit dem Knoten kam reines Rauschen."""
    from . import workflows as wfm  # erst hier: workflows importiert dieses Modul

    seed = wfm._seed(p)
    w = max(256, min(1920, int(p.get("width") or 1248)) // 16 * 16)
    h = max(256, min(1920, int(p.get("height") or 704)) // 16 * 16)
    frames = min(MAX_FRAMES, max(MIN_FRAMES, wfm.normalize_frames(int(p.get("frames") or DEFAULT_FRAMES), WORKFLOW)))
    g: dict[str, Any] = {
        "1": {"class_type": "UNETLoader", "inputs": {
            "unet_name": wfm._file_by_target(entry, "diffusion_models"), "weight_dtype": "default"}},
        "2": {"class_type": "CLIPLoader", "inputs": {
            "clip_name": wfm._file_by_target(entry, "text_encoders"), "type": "pan2"}},
        "3": {"class_type": "VAELoader", "inputs": {"vae_name": wfm._file_by_target(entry, "vae")}},
        "4": {"class_type": "CLIPTextEncode", "inputs": {"text": p["prompt"], "clip": ["2", 0]}},
        "5": {"class_type": "CLIPTextEncode", "inputs": {"text": p.get("negative_prompt") or NEGATIVE, "clip": ["2", 0]}},
    }
    latent: dict[str, Any] = {"vae": ["3", 0], "width": w, "height": h, "length": frames, "batch_size": 1}
    if p.get("start_image"):
        g["11"] = {"class_type": "LoadImage", "inputs": {"image": p["start_image"]}}
        latent["start_image"] = ["11", 0]
    g["7"] = {"class_type": "Wan22ImageToVideoLatent", "inputs": latent}
    g["8"] = {"class_type": "KSampler", "inputs": {
        "seed": seed, "steps": int(p.get("steps") or STEPS), "cfg": float(p.get("cfg") or CFG),
        "sampler_name": p.get("sampler") or "euler", "scheduler": p.get("scheduler") or "simple",
        "model": ["1", 0], "positive": ["4", 0], "negative": ["5", 0], "latent_image": ["7", 0], "denoise": 1.0}}
    g["9"] = {"class_type": "VAEDecode", "inputs": {"samples": ["8", 0], "vae": ["3", 0]}}
    g["10"] = {"class_type": "CreateVideo", "inputs": {"images": ["9", 0], "fps": float(FPS)}}
    crf = p.get("crf")
    g["12"] = {"class_type": "SaveVideo", "inputs": {
        "video": ["10", 0], "filename_prefix": "nvai_video", "format": "mp4", "format.codec": "h264",
        "format.codec.encoding": "re-encode",
        "format.codec.encoding.crf": float(wfm.VIDEO_CRF if crf is None else crf)}}
    return g, seed


FRAME_GRID = {WORKFLOW: (4, 1)}
BUILDERS = {WORKFLOW: build}
