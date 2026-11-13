"""Kandinsky 6 (Kandinsky Lab / Sber, MIT, seit 6.10.2026): Video und Ton in einem Durchgang, 5 s in 864 x 480 bei
24 fps. Eingebaut sind die destillierten Fassungen Lite (3B) und Pro (29B) als INT8 ConvRot von t8star
(t8star/Kandinsky-Comfy, MIT) mit dem Knotenpaket Comfyui-Kandinsky-T8 (T8mars, MIT, 0.1.4), das das Setup in ComfyUIs
custom_nodes legt; ComfyUI selbst kann Kandinsky 6 noch nicht (PR 16825 offen). Nutzer 12.11.2026: „füge kandinsky 6
in die Modelliste“, „und die pro variante“. catalog.py, catalog_en.py und workflows.py holen Eintraege, Texte und den
Builder von hier, wie bei minimax.py.

Graph nach den Beispiel-Workflows des Knotenpakets („K6 INT8 PiFlow Text/Image to Video+Audio“): Qwen2.5-VL 7B und
CLIP-L ueber DualCLIPLoader (Typ kandinsky5, das fp8 von Qwen-Image), HunyuanVideo-VAE, Ton-VAE von MMAudio mit
BigVGAN, Kandinsky6Sampler mit PiFlow (10 Schritte, CFG 1; der Negativprompt wirkt dabei nicht). Bild und Ton bekommen
getrennte Beschreibungen: der Prompt ist die Bildbeschreibung (Gesprochenes als <S>…<E> an der Stelle, an der es
gesagt wird), audio_prompt beschreibt den Klang (der Knoten haengt ihn als <AUDCAP>…<ENDAUDCAP> an).
"""
from __future__ import annotations

from typing import Any

from .i18n import t

REPO = "t8star/Kandinsky-Comfy"
WORKFLOW = "kandinsky6"
FAMILY = "kandinsky6"
MODEL_LITE = "kandinsky6-lite-distill-int8"
MODEL_PRO = "kandinsky6-pro-distill-int8"
# Trainiert auf 5 s bei 24 fps (121 Bilder); der Knoten verlangt 4n+1 Bilder und Kantenlaengen in Vielfachen von 16.
FPS = 24
FRAME_STEP, FRAME_REST = 4, 1
DEFAULT_FRAMES, MIN_FRAMES, MAX_FRAMES = 121, 49, 121
# PiFlow der destillierten Fassungen: fest 10 Schritte, CFG 1 (Knotenpaket und Modellkarte)
STEPS, CFG = 10, 1.0
# Ton-VAE: Skalierung der Pretrain- und Distill-Fassungen (Kandinsky6AudioVAELoader, model_variant)
AUDIO_VARIANT = "pretrain / distill"
NEGATIVE = "Static, cartoon, worst quality, low quality, deformed"  # wie in den Beispielen; wirkt mit CFG 1 nicht

# Text-Encoder, CLIP-L und HunyuanVideo-VAE wie bei Kandinsky 5 (catalog.KANDINSKY5_SHARED, hier wiederholt, damit das
# Modul ohne catalog importierbar bleibt; gleiche Dateien, also nur einmal geladen), dazu die Ton-Teile aus dem Repo
# von t8star in models/audio_vae, wo der Knoten sie sucht.
SHARED: list[dict[str, Any]] = [
    {"repo": "Comfy-Org/Qwen-Image_ComfyUI",
     "file": "split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors", "target": "text_encoders"},
    {"repo": "comfyanonymous/flux_text_encoders", "file": "clip_l.safetensors", "target": "text_encoders"},
    {"repo": "Kijai/HunyuanVideo_comfy", "file": "hunyuan_video_vae_bf16.safetensors", "target": "vae"},
    {"repo": REPO, "file": "audio_vae/v1-44.pth", "target": "audio_vae"},
    {"repo": REPO, "file": "audio_vae/bigvgan_vocoder/bigvgan_generator.pt", "target": "audio_vae/bigvgan_vocoder"},
    {"repo": REPO, "file": "audio_vae/bigvgan_vocoder/config.json", "target": "audio_vae/bigvgan_vocoder"},
]
SHARED_GB = 9.38 + 0.25 + 0.49 + 1.22 + 0.49

LICENSE = "MIT (Video-VAE: Tencent Hunyuan Community License; Ton-VAE: CC BY-NC 4.0)"
LICENSE_EN = "MIT (video VAE: Tencent Hunyuan Community License; audio VAE: CC BY-NC 4.0)"
WARNING = (
    "Das Modell steht unter MIT. Die Video-VAE stammt von HunyuanVideo (Tencent Hunyuan Community License, gilt laut "
    "Tencent nicht in der EU, in Großbritannien und Südkorea), die Ton-VAE (MMAudio) steht unter CC BY-NC 4.0: Der Ton "
    "ist nicht kommerziell nutzbar. Vor jeder Veröffentlichung prüfen.")
WARNING_EN = (
    "The model is MIT. The video VAE comes from HunyuanVideo (Tencent Hunyuan Community License, which according to "
    "Tencent does not apply in the EU, the UK and South Korea), the audio VAE (MMAudio) is CC BY-NC 4.0: the sound "
    "may not be used commercially. Check before publishing anything.")

SIZES = [
    {"label": "864 × 480 — 16:9, Trainingsformat", "w": 864, "h": 480},
    {"label": "480 × 864 — 9:16, hochkant (nicht gemessen)", "w": 480, "h": 864},
]
SIZE_LABELS = {
    SIZES[0]["label"]: "864 × 480 — 16:9, training size",
    SIZES[1]["label"]: "480 × 864 — 9:16, portrait (not measured)",
}

# <messreihe> RTX 5060 Ti 16 GB, 864 x 480, 5 s mit Ton; die Zeilen schreibt die Messung in notizen/video.md fort
TESTED: dict[str, str] = {
    MODEL_PRO: "Gemessen (5 s in 864 × 480 mit Ton): mit Startbild 996 s, aus Text 1106 s samt erstem Laden",
    MODEL_LITE: "Gemessen (5 s in 864 × 480 mit Ton): aus Text 294 s samt erstem Laden, mit Startbild 365 s",
}
TESTED_EN: dict[str, str] = {
    MODEL_PRO: "Measured (5 s at 864 × 480 with sound): from a start image 996 s, from text 1106 s including the "
               "first load",
    MODEL_LITE: "Measured (5 s at 864 × 480 with sound): from text 294 s including the first load, from a start "
                "image 365 s",
}
# </messreihe>

PROMPT_HINT = (
    "Bildbeschreibung in ganzen englischen Sätzen: Einstellung, Ort und Licht, Handlung, Kamera. Gesprochenes in "
    "<S>…<E> an der Stelle, an der es gesagt wird. Was zu hören ist, gehört ins Feld „Ton“: laute Quellen ausdrücklich "
    "nennen (leise beschriebene kamen leise). Mit Startbild beschreiben, was ab dem Bild geschieht; das Startbild im "
    "Videoformat anlegen. Pro setzte ohne Startbild schwarze Balken oben und unten (2 von 2 Clips, mit und ohne "
    "„cinematic“), mit Startbild nicht.")
PROMPT_HINT_EN = (
    "Describe the picture in whole English sentences: shot, place and light, action, camera. Spoken words in "
    "<S>…<E> at the moment they are said. What can be heard goes into the “Sound” field: name loud sources "
    "explicitly (quietly described ones came out quiet). With a start image, describe what happens from the image on; "
    "make the start image in the video's format. Without a start image Pro put black bars at the top and bottom (2 of "
    "2 clips, with and without “cinematic”), with a start image it did not.")
PLACEHOLDER = (
    "A medium shot of an old blacksmith with a grey beard in a dim forge at noon. He lifts a glowing iron bar with "
    "tongs, lays it on the anvil and strikes it hard with a hammer; sparks fly. He looks into the camera and says "
    "<S>This blade will outlast us all.<E> The camera stays still.")
AUDIO_PLACEHOLDER = "Loud ringing hammer blows on the anvil, the roar of the forge fire, a deep calm male voice."

FEATURES: dict[str, Any] = {
    "start_image": "optional",
    "fps": FPS, "max_seconds": 5,
    "default_frames": DEFAULT_FRAMES, "min_frames": MIN_FRAMES, "max_frames": MAX_FRAMES,
    "frame_step": FRAME_STEP, "frame_rule": "4n+1",
    "distilled": {"steps": STEPS, "fixed": True},
    "negative_prompt": False,
    # Getrennte Tonbeschreibung (GenerateVideoRequest.audio_prompt); die Generieren-Seite zeigt dafür ein Feld
    "audio_prompt": True,
    "audio_placeholder": AUDIO_PLACEHOLDER,
    "sizes": SIZES,
    "prompt_hint": PROMPT_HINT,
    "placeholder": PLACEHOLDER,
}


def _entry(model_id: str, name: str, dit: str, dit_gb: float, best_for: str, description: str,
           pros: list[str], cons: list[str]) -> dict[str, Any]:
    return {
        "id": model_id,
        "name": name,
        "kind": "video",
        "family": FAMILY,
        "workflow": WORKFLOW,
        "files": [{"repo": REPO, "file": f"diffusion_models/{dit}", "target": "diffusion_models"}, *SHARED],
        "size_gb": round(dit_gb + SHARED_GB, 2),
        "model_gb": dit_gb,
        "vram_gb": 14,
        "license": LICENSE,
        "commercial_ok": False,
        "warning": WARNING,
        "best_for": best_for,
        "description": description,
        "pros": pros,
        "cons": cons,
        "features": {**FEATURES, "tested": TESTED.get(model_id, "")},
    }


MODELS: list[dict[str, Any]] = [
    _entry(
        MODEL_PRO, "Kandinsky 6 Pro, destilliert (INT8, mit Ton)", "k6_pro_distill_int8_convrot.safetensors", 34.97,
        "Video mit Ton und Sprache, 5 s: hält Handlung und Gesicht, für Fälle, in denen LTX-2.5 nicht trifft",
        "Kandinsky Lab (Sber), 29 Mrd. Parameter, MIT. Bild und Ton (44 kHz, lippensynchron) in einem Durchgang, "
        "5 s in 864 × 480 bei 24 fps, aus Text oder einem Startbild. Eingebaut ist die destillierte Fassung (PiFlow, "
        "10 Schritte, CFG 1) als INT8 von t8star, gerechnet mit dessen ComfyUI-Knoten.\n\n"
        "Getestet am 27.10.2026 (RTX 5060 Ti 16 GB): Ein Schmied mit Zange, Funkenregen beim ersten Schlag und Sprache "
        "in die Kamera; beim Angeln mit Startbild holte er die Schnur ein und legte den Fang in den Eimer, das Gesicht "
        "blieb durchgehend derselbe Mann. Am 12.11. gemessen 17 bis 18 min für 5 s; ohne Startbild setzte Pro schwarze Balken oben und unten, mit Startbild nicht. Braucht 64 GB Arbeitsspeicher (das Modell allein hat "
        "35 GB).",
        ["Handlung und Gesicht im Test treu, auch mit Startbild", "Ton und Sprache in einem Durchgang",
         "Modell unter MIT", "Text-Encoder mit Qwen-Image geteilt"],
        ["Langsam: rund 17 min für 5 s", "Höchstens 5 s in 864 × 480", "35 GB Download, braucht 64 GB RAM",
         "Ton nicht kommerziell (Ton-VAE CC BY-NC), Video-VAE nicht in der EU lizenziert", "Ton eher leise"],
    ),
    _entry(
        MODEL_LITE, "Kandinsky 6 Lite, destilliert (INT8, mit Ton)", "k6_lite_distill_int8_convrot.safetensors", 3.77,
        "Schnelle Entwürfe mit Ton, 5 s in 864 × 480",
        "Die kleine Fassung von Kandinsky 6 (3 Mrd. Parameter, MIT): Bild und Ton in einem Durchgang, 5 s in "
        "864 × 480 bei 24 fps, aus Text oder einem Startbild. Destilliert (PiFlow, 10 Schritte, CFG 1), INT8 von "
        "t8star.\n\n"
        "Getestet am 27.10. und 12.11.2026 (RTX 5060 Ti 16 GB): rund 5 min für 5 s. Im Test Artefakte: Die Angel zerfiel, der "
        "Schmied hielt das glühende Eisen mit bloßer Hand, beim Angeln legte er die Rute ohne Fisch weg. Für Entwürfe; "
        "für das Ergebnis die Pro-Fassung.",
        ["Rund 5 min für 5 s mit Ton", "Nur 3,8 GB Modell", "Modell unter MIT"],
        ["Artefakte im Test (zerfallende Gegenstände, falsche Handgriffe)", "Höchstens 5 s in 864 × 480",
         "Ton nicht kommerziell (Ton-VAE CC BY-NC), Video-VAE nicht in der EU lizenziert", "Ton eher leise"],
    ),
]

EN: dict[str, dict[str, Any]] = {
    MODEL_PRO: {
        "name": "Kandinsky 6 Pro, distilled (INT8, with sound)",
        "best_for": "Video with sound and speech, 5 s: keeps action and face, for cases LTX-2.5 does not get right",
        "description": (
            "Kandinsky Lab (Sber), 29B parameters, MIT. Picture and sound (44 kHz, lip-synced) in one pass, 5 s at "
            "864 × 480 and 24 fps, from text or a start image. Built in is the distilled version (PiFlow, 10 steps, "
            "CFG 1) as INT8 by t8star, run with t8star's ComfyUI nodes.\n\n"
            "Tested on 27 October 2026 (RTX 5060 Ti 16 GB): a blacksmith with tongs, a shower of sparks at the first "
            "blow and speech into the camera; fishing from a start image, he reeled in the line and put the catch in "
            "the bucket, the face stayed the same man throughout. Measured on 12 November: 17 to 18 min for 5 s; without a "
            "start image Pro put black bars at the top and bottom, with one it did not. Needs 64 GB of RAM (the model "
            "alone is 35 GB)."),
        "pros": ["Action and face true in the test, also with a start image", "Sound and speech in one pass",
                 "Model under MIT", "Text encoder shared with Qwen-Image"],
        "cons": ["Slow: about 17 min for 5 s", "At most 5 s at 864 × 480", "35 GB download, needs 64 GB of RAM",
                 "Sound not for commercial use (audio VAE CC BY-NC), video VAE not licensed in the EU",
                 "Sound rather quiet"],
        "license": LICENSE_EN,
        "warning": WARNING_EN,
    },
    MODEL_LITE: {
        "name": "Kandinsky 6 Lite, distilled (INT8, with sound)",
        "best_for": "Fast drafts with sound, 5 s at 864 × 480",
        "description": (
            "The small version of Kandinsky 6 (3B parameters, MIT): picture and sound in one pass, 5 s at 864 × 480 "
            "and 24 fps, from text or a start image. Distilled (PiFlow, 10 steps, CFG 1), INT8 by t8star.\n\n"
            "Tested on 27 October and 12 November 2026 (RTX 5060 Ti 16 GB): about 5 min for 5 s. Artifacts in the test: the fishing "
            "rod fell apart, the blacksmith held the glowing iron with his bare hand, when fishing he put the rod "
            "down without a fish. For drafts; use Pro for the result."),
        "pros": ["About 5 min for 5 s with sound", "Only a 3.8 GB model", "Model under MIT"],
        "cons": ["Artifacts in the test (objects falling apart, wrong grips)", "At most 5 s at 864 × 480",
                 "Sound not for commercial use (audio VAE CC BY-NC), video VAE not licensed in the EU",
                 "Sound rather quiet"],
        "license": LICENSE_EN,
        "warning": WARNING_EN,
    },
}
for _mid in EN:
    EN[_mid]["features"] = {"prompt_hint": PROMPT_HINT_EN, "tested": TESTED_EN.get(_mid, "")}


def build(entry: dict[str, Any], p: dict[str, Any]) -> tuple[dict[str, Any], int]:
    """Graph wie die Beispiele des Knotenpakets; Ton durch den Begrenzer, Speichern wie bei LTX-2.5 (H.264 mit CRF).
    Die verlustfreie Kopie haengt workflows.build an (add_master)."""
    from . import workflows as wfm  # erst hier: workflows importiert dieses Modul

    seed = wfm._seed(p)
    w = max(256, min(2048, int(p.get("width") or 864)) // 16 * 16)
    h = max(256, min(2048, int(p.get("height") or 480)) // 16 * 16)
    frames = min(MAX_FRAMES, max(MIN_FRAMES, wfm.normalize_frames(int(p.get("frames") or DEFAULT_FRAMES), WORKFLOW)))
    g: dict[str, Any] = {
        "1": {"class_type": "UNETLoader", "inputs": {
            "unet_name": wfm._file_by_target(entry, "diffusion_models"), "weight_dtype": "default"}},
        "2": {"class_type": "DualCLIPLoader", "inputs": {
            "clip_name1": wfm._file_by_target(entry, "text_encoders", "qwen"),
            "clip_name2": wfm._file_by_target(entry, "text_encoders", "clip_l"),
            "type": "kandinsky5", "device": "default"}},
        "3": {"class_type": "VAELoader", "inputs": {"vae_name": wfm._file_by_target(entry, "vae")}},
        "4": {"class_type": "Kandinsky6AudioVAELoader", "inputs": {
            "tod_vae": "v1-44.pth", "bigvgan_dir": "bigvgan_vocoder", "mode": "44k",
            "scaling_factor": 0.417, "model_variant": AUDIO_VARIANT}},
        "5": {"class_type": "Kandinsky6TextEncode", "inputs": {
            "clip": ["2", 0], "video_caption": p["prompt"], "audio_caption": (p.get("audio_prompt") or "").strip()}},
        "6": {"class_type": "Kandinsky6TextEncode", "inputs": {
            "clip": ["2", 0], "video_caption": NEGATIVE, "audio_caption": ""}},
        "7": {"class_type": "Kandinsky6EmptyLatent", "inputs": {
            "width": w, "height": h, "length": frames, "fps": float(FPS), "batch_size": 1}},
    }
    pos, neg, latent = ["5", 0], ["6", 0], ["7", 0]
    start = p.get("start_image")
    if start:
        g["8"] = {"class_type": "LoadImage", "inputs": {"image": start}}
        g["9"] = {"class_type": "ImageScale", "inputs": {
            "image": ["8", 0], "upscale_method": "lanczos", "width": w, "height": h, "crop": "center"}}
        g["10"] = {"class_type": "VAEEncode", "inputs": {"pixels": ["9", 0], "vae": ["3", 0]}}
        g["11"] = {"class_type": "Kandinsky6ImageToVideoAudio", "inputs": {
            "positive": pos, "negative": neg, "empty_latent": latent, "reference_latent": ["10", 0]}}
        pos, neg, latent = ["11", 0], ["11", 1], ["11", 2]
    g["12"] = {"class_type": "Kandinsky6Sampler", "inputs": {
        "model": ["1", 0], "seed": seed, "steps": STEPS, "cfg": CFG, "sampler_name": "euler", "scheduler": "simple",
        "positive": pos, "negative": neg, "latent_image": latent, "denoise": 1.0}}
    joint: list[Any] = ["12", 0]
    if start:
        g["13"] = {"class_type": "Kandinsky6RemoveReferenceLatent", "inputs": {"joint_latent": joint}}
        joint = ["13", 0]
    g["14"] = {"class_type": "VAEDecode", "inputs": {"samples": joint, "vae": ["3", 0]}}
    g["15"] = {"class_type": "Kandinsky6AudioVAEDecode", "inputs": {"audio_vae": ["4", 0], "joint_latent": joint}}
    g["16"] = {"class_type": "NVAIAudioLimiter", "inputs": {
        "audio": ["15", 0], "ceiling_db": wfm.VIDEO_AUDIO_CEILING_DB, "lookahead_ms": 5.0, "release_ms": 80.0}}
    g["17"] = {"class_type": "CreateVideo", "inputs": {"images": ["14", 0], "fps": float(FPS), "audio": ["16", 0]}}
    crf = p.get("crf")
    g["18"] = {"class_type": "SaveVideo", "inputs": {
        "video": ["17", 0], "filename_prefix": "nvai_video", "format": "mp4", "format.codec": "h264",
        "format.codec.encoding": "re-encode",
        "format.codec.encoding.crf": float(wfm.VIDEO_CRF if crf is None else crf)}}
    return g, seed


def prepare(p: dict[str, Any]) -> None:
    """Vor dem Lauf (jobs._txt2video): feste Bildrate, Laenge im trainierten Bereich, Hinweis bei fremden Schaltern."""
    from . import workflows as wfm

    p["fps"] = FPS
    p["frames"] = min(MAX_FRAMES, max(MIN_FRAMES, wfm.normalize_frames(int(p.get("frames") or DEFAULT_FRAMES),
                                                                         WORKFLOW)))
    if p.get("steps") not in (None, STEPS) or p.get("cfg") not in (None, CFG):
        raise RuntimeError(t(
            f"Kandinsky 6 (destilliert) rechnet fest mit {STEPS} Schritten und CFG 1.",
            f"Kandinsky 6 (distilled) runs with a fixed {STEPS} steps and CFG 1."))


FRAME_GRID = {WORKFLOW: (FRAME_STEP, FRAME_REST)}
BUILDERS = {WORKFLOW: build}
