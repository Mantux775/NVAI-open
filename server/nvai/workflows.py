"""Workflow-Builder: uebersetzt einfache Parameter in ComfyUI-API-Graphen.

Alle verwendeten Nodes wurden gegen /object_info der lokalen ComfyUI-Installation
geprueft. Ein Builder pro `workflow`-Schluessel aus catalog.py.
"""
from __future__ import annotations

import random
import re
from pathlib import Path
from typing import Any

from .i18n import t

Graph = dict[str, Any]

# Defaults je Workflow-Typ. Werden von expliziten Nutzerangaben ueberschrieben.
DEFAULTS: dict[str, dict[str, Any]] = {
    "sdxl":       {"steps": 28, "cfg": 6.5, "sampler": "dpmpp_2m", "scheduler": "karras"},
    "flux":       {"steps": 4,  "cfg": 1.0, "sampler": "euler",    "scheduler": "simple"},
    "flux-dev":   {"steps": 22, "cfg": 3.5, "sampler": "euler",    "scheduler": "simple"},
    "sd3":        {"steps": 28, "cfg": 4.5, "sampler": "euler",    "scheduler": "simple"},
    "chroma":     {"steps": 26, "cfg": 4.0, "sampler": "euler",    "scheduler": "beta"},
    # Werte aus ComfyUIs LongCat-Template; guidance ist zusaetzlich (FluxGuidance).
    "longcat":    {"steps": 20, "cfg": 4.0, "sampler": "euler",    "scheduler": "simple",
                   "guidance": 4.0},
    # Z-Image: Werte aus dem Template image_z_image.json (Note dort: 30-50 Schritte, cfg 3-5).
    "zimage":     {"steps": 25, "cfg": 4.0, "sampler": "res_multistep", "scheduler": "simple",
                   "shift": 3.0},
    # Qwen-Image 2512: Werte aus dem Template image_qwen_Image_2512.json. Die Lightning-
    # LoRA destilliert auf 8 Schritte bei cfg 1 -- der negative Prompt wirkt dort nicht.
    "qwen_image": {"steps": 50, "cfg": 4.0, "sampler": "euler",    "scheduler": "simple",
                   "shift": 3.1},
    "qwen_image_lightning": {"steps": 8, "cfg": 1.0, "sampler": "euler", "scheduler": "simple",
                             "shift": 3.1},
    # Qwen-Image 2.1: Werte aus ComfyUIs Vorlagen image_qwen_image_2_1_{t2i,image_edit}.json
    # (Qwens Diffusers-Pipeline: 40 Schritte, true_cfg 1). Shift steckt im Modell.
    "qwen_image21": {"steps": 25, "cfg": 1.0, "sampler": "euler", "scheduler": "simple"},
    # FLUX 3 Image Klein: Werte aus den Vorlagen image_flux3_klein_*.json und der
    # Modellkarte. Die destillierte Fassung ist eine Flow-Map ohne Guidance (cfg 1,
    # negativer Prompt wirkungslos), die Base-Fassung braucht CFG 3.5 -- BFLs
    # Referenzcode nimmt 4.0. Shift steckt in den Modell-Metadaten, kein eigener Node.
    "flux3_klein": {"steps": 16, "cfg": 1.0, "sampler": "euler", "scheduler": "simple"},
    "flux3_klein_base": {"steps": 50, "cfg": 3.5, "sampler": "euler", "scheduler": "simple"},
    # Krea 2 Turbo: Werte aus ComfyUIs Vorlage image_krea2_turbo_t2i.json (destilliert, cfg 1,
    # negativer Prompt als ConditioningZeroOut, kein Shift-Knoten).
    "krea2_turbo": {"steps": 8, "cfg": 1.0, "sampler": "euler", "scheduler": "simple"},
    # MOSS-Image (OpenMOSS, 16.10.2026): Einstellung von OpenMOSS (50 Schritte, cfg 3, euler). ComfyUIs Vorlage
    # image_moss_image_t2i.json nimmt kijais schnelle Einstellung aus PR #17095 (25 Schritte, cfg 2,5, er_sde).
    # Gemessen 25.10.2026, gleiche Prompts und Seeds: Kistenseile durch Bohrungen 3 von 3 statt 2 von 3, Schrift
    # beide Male buchstabengenau; 51 statt 28 s je Bild mit 1 MP. Shift 5 steckt im Modell.
    "moss_image": {"steps": 50, "cfg": 3.0, "sampler": "euler", "scheduler": "simple"},
    # Boogu-Image 0.1: Werte aus ComfyUIs Vorlagen image_boogu_image_0_1_{turbo_t2i,edit}.json.
    # Turbo ist destilliert (4 Schritte, cfg 1, Negativ ausgenullt); Base und Edit rechnen
    # 25 Schritte mit cfg 3,5 und shift 3,16 (nur fuer die Sigmas, wie in der Vorlage).
    "boogu_turbo": {"steps": 4, "cfg": 1.0, "sampler": "lcm", "scheduler": "sgm_uniform"},
    "boogu":      {"steps": 25, "cfg": 3.5, "sampler": "dpmpp_2m", "scheduler": "simple", "shift": 3.16},
    # HiDream-O1: Werte aus image_hidream_o1{,_dev}.json. Pixelraum-Modell, Text-Encoder und
    # VAE stecken im Checkpoint; trainiert um 4 Megapixel (darunter deutlich schlechter).
    "hidream_o1_dev": {"steps": 28, "cfg": 1.0, "sampler": "lcm", "scheduler": "normal",
                       "noise_scale": 7.6},
    # Sampler: Die Vorlage nimmt dpmpp_2m_sde_gpu; mit der fp8-Datei zerfiel der Hintergrund
    # dabei in 32-px-Bloecke (gemessen 2026-10-21, 1728 x 2304, Seed 7). euler: sauber, 142 s.
    "hidream_o1": {"steps": 40, "cfg": 5.0, "sampler": "euler", "scheduler": "normal",
                   "noise_scale": 8.0},
    "stable_audio": {"steps": 50, "cfg": 5.0, "sampler": "dpmpp_3m_sde_gpu", "scheduler": "exponential"},
    # Wie ComfyUIs Vorlage audio_stable_audio_3_medium: destilliert, 8 Schritte, CFG 1, lcm.
    "stable_audio_3": {"steps": 8, "cfg": 1.0, "sampler": "lcm", "scheduler": "simple"},
    "wan_t2v":    {"steps": 30, "cfg": 6.0, "sampler": "uni_pc",   "scheduler": "simple", "shift": 8.0},
    "wan22_ti2v": {"steps": 30, "cfg": 5.0, "sampler": "uni_pc",   "scheduler": "simple", "shift": 8.0},
    "wan_i2v":    {"steps": 30, "cfg": 6.0, "sampler": "uni_pc",   "scheduler": "simple", "shift": 8.0},
    # Wan 2.2 A14B: zwei Experten teilen sich die Schritte an "boundary".
    "wan22_i2v":  {"steps": 20, "cfg": 3.5, "sampler": "euler",    "scheduler": "simple",
                   "shift": 8.0, "boundary": 0.5},
    # HunyuanVideo 1.5 bringt shift 7.0 selbst mit -- kein ModelSamplingSD3 noetig.
    # Beide Katalogeintraege sind CFG-destilliert: cfg 1.0, negativer Prompt wirkungslos.
    "hunyuan15_t2v": {"steps": 30, "cfg": 1.0, "sampler": "euler", "scheduler": "simple"},
    "hunyuan15_i2v": {"steps": 30, "cfg": 1.0, "sampler": "euler", "scheduler": "simple"},
    "ltxv_t2v":   {"steps": 30, "cfg": 3.0, "sampler": "euler",    "scheduler": "simple"},
    # LTX-2.5 (destilliert): Werte aus video_ltx2_5_{t2v,i2v}.json. Zwei Stufen mit festen
    # Sigmas statt Schritten, cfg 1 fuer Bild und Ton, euler_ancestral.
    "ltx25":      {"steps": 8, "cfg": 1.0, "sampler": "euler_ancestral", "scheduler": "simple"},
    # LTX-2.3: Vorlagen video_ltx2_3_{t2v,i2v}.json -- dev-Checkpoint plus destillierte LoRA
    # (Staerke 0,5), dieselben zwei Stufen mit festen Sigmas wie LTX-2.5, aber euler.
    "ltx23":      {"steps": 8, "cfg": 1.0, "sampler": "euler", "scheduler": "simple"},
    # Kandinsky 5.0 Lite: Vorlagen video_kandinsky5_{t2v,i2v}.json (50 Schritte, cfg 5,
    # shift 5). Die destillierte Fassung laut Modellkarte 16 Schritte, CFG-destilliert.
    "kandinsky5_t2v": {"steps": 50, "cfg": 5.0, "sampler": "euler_ancestral", "scheduler": "beta",
                       "shift": 5.0},
    "kandinsky5_t2v_distilled": {"steps": 16, "cfg": 1.0, "sampler": "euler_ancestral",
                                 "scheduler": "beta", "shift": 5.0},
    "kandinsky5_i2v": {"steps": 50, "cfg": 5.0, "sampler": "euler_ancestral", "scheduler": "beta",
                       "shift": 5.0},
    # Mochi 1 preview: Werte aus ComfyUIs Mochi-Beispiel (30 Schritte, cfg 4.5).
    "mochi":      {"steps": 30, "cfg": 4.5, "sampler": "euler", "scheduler": "simple"},
}

# Workflows, die zwingend ein Startbild brauchen.
I2V_WORKFLOWS = {"wan_i2v", "wan22_i2v", "hunyuan15_i2v", "kandinsky5_i2v"}
# Workflows, die ein Startbild nehmen koennen, aber nicht muessen.
OPTIONAL_START_WORKFLOWS = {"wan22_ti2v", "ltx25", "ltx23"}

DEFAULT_VIDEO_NEGATIVE = (
    "blurry, low quality, static, jpeg artifacts, watermark, text, distorted, "
    "deformed, ugly, oversaturated, jittery motion"
)

# Negativprompt aus Qwens Modellkarte zu Qwen-Image-2512 (Beispielcode, woertlich).
# Greift, wenn der Nutzer keinen eigenen angibt -- wie DEFAULT_VIDEO_NEGATIVE beim Video.
# Inhalt: niedrige Aufloesung und Qualitaet, deformierte Glieder und Finger, uebersaettigt,
# wachsern, Gesichter ohne Detail, zu glatt, KI-Look, wirre Komposition, verzerrte Schrift.
QWEN_IMAGE_NEGATIVE = (
    "低分辨率，低画质，肢体畸形，手指畸形，画面过饱和，蜡像感，人脸无细节，过度光滑，"
    "画面具有AI感。构图混乱。文字模糊，扭曲。"
)

# Negativprompt aus ComfyUIs Vorlage image_moss_image_t2i.json, dort als Empfehlung von OpenMOSS.
MOSS_IMAGE_NEGATIVE = "nsfw, worst quality, bad anatomy, watermark, jpeg artifact"

# Negativprompts, die ein Workflow einsetzt, wenn keiner angegeben ist. Fuer
# registry.features_for, damit Frontend und Claude es sehen.
DEFAULT_NEGATIVES = {"qwen_image": QWEN_IMAGE_NEGATIVE, "moss_image": MOSS_IMAGE_NEGATIVE}

# Prompt-Ausbau von MOSS-Image: Systemprompt aus ComfyUIs Vorlage image_moss_image_t2i.json, dort nach dem
# „MOSS-Image Prompt Enhancer“-Skill von OpenMOSS geschrieben. MOSS-Image ist auf Bildbeschreibungen
# trainiert; der Ausbau laeuft auf seinem eigenen Text-Encoder (jobs._moss_caption).
MOSS_ENHANCER_SYSTEM = (
    "You turn a user's image idea into one detailed caption for a text-to-image model. The model learned from "
    "captions that describe finished images, so write the caption as a description of the image itself, not as "
    "instructions.\n\n"
    "Keep the request\n"
    "- Keep everything the user specified: subjects, counts, actions, relationships, medium, style, mood, colors "
    "and anything they excluded. Never contradict or drop it.\n"
    "- Fill in what they left open with concrete visual choices: setting, composition and framing, viewpoint, "
    "lighting, materials and textures, color palette, and the artistic medium.\n"
    "- Describe only what can be seen. Leave out sounds, smells, backstory and intentions.\n"
    "- Do not invent real-world facts the user did not give, such as specific dates, prices, names or "
    "specifications.\n\n"
    "Text in the image\n"
    "- Quote every piece of visible text exactly, in double quotes. Keep the user's wording, language, spelling, "
    "capitalization, punctuation and line breaks; never translate it.\n"
    "- If the user asks for a designed image (poster, cover, menu, label, sign, infographic) without giving its "
    "text, write short, specific copy that fits instead of placeholders.\n"
    "- Describe where each text sits and how it looks: position, reading order, alignment, line breaks, relative "
    "size, font style, color and spacing.\n"
    "- Do not mention watermarks or artist signatures.\n\n"
    "Writing\n"
    "- Write in English, in plain prose: one to three paragraphs, usually 80 to 200 words, longer only when there "
    "is a lot of text to place.\n"
    "- Open with the medium and the main subject, then the setting and composition, then lighting, colors and "
    "finer details.\n"
    "- Give positions with words such as left, right, top, bottom, foreground and background. No coordinates, "
    "lists, headings, JSON or Markdown.\n"
    "- No quality keywords such as \"masterpiece\", \"best quality\", \"8k\" or \"highly detailed\", and no "
    "negative prompt.\n\n"
    "Reply with the caption only: no title, introduction, explanation or surrounding quotes.")


def defaults_for(workflow: str) -> dict[str, Any]:
    return DEFAULTS.get(workflow, DEFAULTS["sdxl"])


def _seed(p: dict[str, Any]) -> int:
    s = p.get("seed")
    return random.randint(0, 2**63 - 1) if s is None else int(s)


def _pick(p: dict[str, Any], d: dict[str, Any], key: str) -> Any:
    """Nutzerwert, falls gesetzt -- sonst der Default des Workflows."""
    v = p.get(key)
    return d[key] if v is None else v


def _fname(f: dict[str, Any]) -> str:
    """Dateiname, wie ComfyUI ihn in models/<target>/ sieht."""
    return f.get("as") or Path(f["file"]).name


# Fuer jobs.py, das den ControlNet-Dateinamen selbst aufloesen muss.
file_name = _fname


def _ckpt(entry: dict[str, Any]) -> str:
    return _fname(entry["files"][0])


def _file_by_target(entry: dict[str, Any], target: str, contains: str = "") -> str:
    """Erste Datei fuer diesen Zielordner. `contains` trennt mehrere Dateien im
    selben Ordner -- Wan 2.2 A14B legt z. B. beide Experten in diffusion_models."""
    for f in entry["files"]:
        if f["target"] == target and (not contains or contains in f["file"]):
            return _fname(f)
    where = f"'{target}'" + (
        t(f" mit '{contains}' im Namen", f" with '{contains}' in its name") if contains else "")
    raise ValueError(t(f"Modell {entry['id']} hat keine Datei fuer {where}",
                       f"Model {entry['id']} has no file for {where}"))


# ---------------------------------------------------------------- BILD

class _Ids:
    """Vergibt freie Node-IDs. Die Grundgeruste nutzen 1-9, Zusaetze fangen bei 20 an."""

    def __init__(self, start: int = 20) -> None:
        self._n = start

    def __call__(self) -> str:
        self._n += 1
        return str(self._n)


Ref = list[Any]  # Verweis auf einen Node-Ausgang, z. B. ["4", 0]


def _apply_slg(graph: Graph, p: dict[str, Any], wf: str, model: Ref, ids: _Ids) -> Ref:
    """SkipLayerGuidanceSD3 zwischen Modell und Sampler haengen.

    Stabilitys eigener Eingriff fuer stabilere Anatomie: einzelne Bloecke werden in
    einem schmalen Fenster am Anfang uebersprungen. Er patcht ("dit","double_block",i)
    -- den Schluessel liest nur MMDiT, deshalb bleibt er bei SDXL wirkungslos und
    wird dort gar nicht erst eingehaengt.
    """
    if not p.get("slg") or wf not in ("sd3",):
        return model
    nid = ids()
    graph[nid] = {"class_type": "SkipLayerGuidanceSD3", "inputs": {
        "model": model,
        "layers": p.get("slg_layers") or "7, 8, 9",
        "scale": float(p.get("slg_scale", 3.0)),
        "start_percent": float(p.get("slg_start", 0.01)),
        "end_percent": float(p.get("slg_end", 0.15)),
    }}
    return [nid, 0]


def _apply_controlnet(graph: Graph, p: dict[str, Any], pos: Ref, neg: Ref,
                      vae: Ref, ids: _Ids) -> tuple[Ref, Ref]:
    """Referenzbild ins Conditioning legen, damit die Form nicht frei erfunden wird.

    Der `vae`-Eingang ist laut Signatur optional, in Wahrheit aber Pflicht: SD3-
    ControlNets rechnen im 16-Kanal-Latentraum. Fehlt die VAE, bricht ComfyUI nicht
    ab, sondern loggt nur eine Warnung und liefert Matsch. Deshalb wird sie hier
    immer verdrahtet.

    jobs.py legt vorher `controlnet_file` (Dateiname im controlnet-Ordner) und
    `controlnet_image` (Dateiname in ComfyUIs input/) ab.
    """
    cn_file = p.get("controlnet_file")
    cn_image = p.get("controlnet_image")
    if not cn_file or not cn_image:
        return pos, neg

    loader, load_img = ids(), ids()
    graph[loader] = {"class_type": "ControlNetLoader", "inputs": {"control_net_name": cn_file}}
    graph[load_img] = {"class_type": "LoadImage", "inputs": {"image": cn_image}}
    hint: Ref = [load_img, 0]

    if p.get("controlnet_preprocess") == "canny":
        nid = ids()
        graph[nid] = {"class_type": "Canny", "inputs": {
            "image": hint,
            "low_threshold": float(p.get("controlnet_canny_low", 0.4)),
            "high_threshold": float(p.get("controlnet_canny_high", 0.8)),
        }}
        hint = [nid, 0]

    # Auf die Zielgroesse bringen -- ein abweichend grosses Referenzbild verzerrt
    # sonst die Vorgabe gegenueber dem Latent.
    scale = ids()
    graph[scale] = {"class_type": "ImageScale", "inputs": {
        "image": hint, "upscale_method": "lanczos",
        "width": int(p.get("width", 1024)), "height": int(p.get("height", 1024)),
        "crop": "center",
    }}

    apply = ids()
    graph[apply] = {"class_type": "ControlNetApplyAdvanced", "inputs": {
        "positive": pos, "negative": neg,
        "control_net": [loader, 0], "image": [scale, 0], "vae": vae,
        "strength": float(p.get("controlnet_strength", 0.7)),
        "start_percent": float(p.get("controlnet_start", 0.0)),
        "end_percent": float(p.get("controlnet_end", 0.8)),
    }}
    return [apply, 0], [apply, 1]


# Wie weit die Outpainting-Maske weich ins vorhandene Bild hineinlaeuft (Pixel).
OUTPAINT_FEATHER = 48


def _image_tail(graph: Graph, p: dict[str, Any], d: dict[str, Any], seed: int, wf: str,
                *, model: Ref, pos: Ref, neg: Ref, vae: Ref, latent_node: str,
                ids: _Ids) -> None:
    """Latent, Sampler, optionaler zweiter Durchgang, Decode, Speichern.

    Gemeinsam fuer alle Bildmodelle -- der Unterschied zwischen ihnen steckt nur im
    Kopf des Graphen (wie Modell, CLIP und VAE geladen werden).
    """
    width, height = int(p.get("width", 1024)), int(p.get("height", 1024))
    batch = int(p.get("batch_size", 1))
    steps = int(_pick(p, d, "steps"))
    sampler_common = {
        "seed": seed,
        "cfg": _pick(p, d, "cfg"),
        "sampler_name": p.get("sampler") or d["sampler"],
        "scheduler": p.get("scheduler") or d["scheduler"],
        "model": model, "positive": pos, "negative": neg,
    }

    # --- Ausgangslatent: leer oder aus einem vorhandenen Bild ---
    start_image = p.get("start_image")
    if start_image:
        load, enc = ids(), ids()
        graph[load] = {"class_type": "LoadImage", "inputs": {"image": start_image}}
        source: Ref = [load, 0]
        # Outpainting: grauen Rand anlegen; die Maske dazu ist im Rand weiss und laeuft
        # ueber `feathering` Pixel weich ins Bild hinein, damit keine Naht bleibt.
        outpaint = p.get("outpaint")
        pad_mask: Ref | None = None
        if outpaint:
            pad = ids()
            left, top, right, bottom = (int(v) for v in outpaint)
            graph[pad] = {"class_type": "ImagePadForOutpaint", "inputs": {
                "image": source, "left": left, "top": top, "right": right, "bottom": bottom,
                "feathering": OUTPAINT_FEATHER}}
            source, pad_mask = [pad, 0], [pad, 1]
        # Auf die angeforderte Groesse bringen; sonst bestimmt das Quellbild das Format.
        # Beim Outpainting ist das Format schon fast richtig (Rundung auf 16) -- dort
        # nicht beschneiden, sonst fiele ein Teil des neuen Randes weg.
        scale = ids()
        graph[scale] = {"class_type": "ImageScale", "inputs": {
            "image": source, "upscale_method": "lanczos",
            "width": width, "height": height, "crop": "disabled" if outpaint else "center"}}
        graph[enc] = {"class_type": "VAEEncode", "inputs": {"pixels": [scale, 0], "vae": vae}}
        latent: Ref = [enc, 0]
        if batch > 1:
            rep = ids()
            graph[rep] = {"class_type": "RepeatLatentBatch",
                          "inputs": {"samples": latent, "amount": batch}}
            latent = [rep, 0]

        # --- Maske: nur der weisse Bereich wird neu gerechnet (Inpainting) ---
        mask_image = p.get("mask_image")
        mask: Ref | None = pad_mask
        if mask_image:
            mload, mscale, mconv = ids(), ids(), ids()
            graph[mload] = {"class_type": "LoadImage", "inputs": {"image": mask_image}}
            graph[mscale] = {"class_type": "ImageScale", "inputs": {
                "image": [mload, 0], "upscale_method": "bilinear",
                "width": width, "height": height, "crop": "center"}}
            graph[mconv] = {"class_type": "ImageToMask",
                            "inputs": {"image": [mscale, 0], "channel": "red"}}
            mask = [mconv, 0]
        if mask is not None:
            noise, diff = ids(), ids()
            graph[noise] = {"class_type": "SetLatentNoiseMask",
                            "inputs": {"samples": latent, "mask": mask}}
            latent = [noise, 0]
            # Graustufen der Maske wirken erst mit Differential Diffusion stufenlos: Ein
            # weicher Rand wird anteilig neu gerechnet, statt hart umzuschalten -- sonst
            # bleibt an der Maskenkante eine sichtbare Naht. Der zweite Durchgang erbt die
            # Maske, weil KSampler und LatentUpscaleBy noise_mask im Latent weiterreichen.
            graph[diff] = {"class_type": "DifferentialDiffusion",
                           "inputs": {"model": sampler_common["model"]}}
            sampler_common["model"] = [diff, 0]
        denoise = float(p.get("denoise", 1.0))
    else:
        lat = ids()
        graph[lat] = {"class_type": latent_node, "inputs": {
            "width": width, "height": height, "batch_size": batch}}
        latent = [lat, 0]
        denoise = 1.0

    first = ids()
    graph[first] = {"class_type": "KSampler", "inputs": {
        **sampler_common, "steps": steps, "denoise": denoise, "latent_image": latent}}
    samples: Ref = [first, 0]

    # --- Zweiter Durchgang auf vergroessertem Latent ---
    # Haende, Gesichter und Fahrzeugdetails messen im ersten Durchgang oft nur 60-100 px.
    # Der zweite rechnet sie bei hoeherer Aufloesung neu, ohne die Komposition zu kippen.
    if p.get("hires"):
        up, second = ids(), ids()
        graph[up] = {"class_type": "LatentUpscaleBy", "inputs": {
            "samples": samples, "upscale_method": "bicubic",
            "scale_by": float(p.get("hires_scale", 1.25))}}
        hs = p.get("hires_steps")
        graph[second] = {"class_type": "KSampler", "inputs": {
            **sampler_common,
            "steps": int(hs) if hs else max(8, steps // 2),
            "denoise": float(p.get("hires_denoise", 0.45)),
            "latent_image": [up, 0]}}
        samples = [second, 0]

    dec, save = ids(), ids()
    graph[dec] = {"class_type": "VAEDecode", "inputs": {"samples": samples, "vae": vae}}
    graph[save] = {"class_type": "SaveImage",
                   "inputs": {"filename_prefix": "nvai", "images": [dec, 0]}}


def build_chroma(entry: dict[str, Any], p: dict[str, Any]) -> tuple[Graph, int]:
    """Chroma laedt Modell, Text-Encoder und VAE getrennt.

    Der Checkpoint enthaelt nur das Diffusion-Model -- mit CheckpointLoaderSimple
    gaebe es "clip input is invalid: None".
    """
    d = defaults_for("chroma")
    seed = _seed(p)
    ids = _Ids()

    graph: Graph = {
        "1": {"class_type": "UNETLoader", "inputs": {
            "unet_name": _file_by_target(entry, "diffusion_models"), "weight_dtype": "default"}},
        "2": {"class_type": "CLIPLoader", "inputs": {
            "clip_name": _file_by_target(entry, "text_encoders"), "type": "chroma"}},
        "3": {"class_type": "VAELoader", "inputs": {"vae_name": _file_by_target(entry, "vae")}},
        "4": {"class_type": "CLIPTextEncode", "inputs": {"text": p["prompt"], "clip": ["2", 0]}},
        "5": {"class_type": "CLIPTextEncode",
              "inputs": {"text": p.get("negative_prompt", ""), "clip": ["2", 0]}},
    }
    # Chroma bringt in seinen sampling_settings nur multiplier=1.0 mit, keinen shift --
    # ohne diesen Node greift der Flux-Default und das Sampling-Budget liegt zu weit im
    # hohen Rauschen, was bei Flow-Modellen die Grobkomposition trifft. Sowohl ComfyUIs
    # Stock-Template als auch der Workflow des Modellautors setzen shift ausdruecklich
    # auf 1.0.
    graph["6"] = {"class_type": "ModelSamplingAuraFlow",
                  "inputs": {"model": ["1", 0], "shift": 1.0}}

    pos, neg = _apply_controlnet(graph, p, ["4", 0], ["5", 0], ["3", 0], ids)
    _image_tail(graph, p, d, seed, "chroma", model=["6", 0], pos=pos, neg=neg, vae=["3", 0],
                latent_node="EmptySD3LatentImage", ids=ids)
    return graph, seed


def build_longcat(entry: dict[str, Any], p: dict[str, Any]) -> tuple[Graph, int]:
    """LongCat-Image: Flux-Architektur mit Qwen2.5-VL als Text-Encoder.

    Nachgebaut nach ComfyUIs ausgeliefertem Template image_longcat_text_to_image.json.
    Zwei Eigenheiten, die man nicht erraten kann:
    - FluxGuidance liegt auf BEIDEN Conditionings, positiv wie negativ (je 4.0).
    - CFGNorm daempft die kombinierte Vorhersage nach der Guidance.
    Das Modell ist nicht CFG-destilliert -- der negative Prompt wirkt also wirklich.
    """
    d = defaults_for("longcat")
    seed = _seed(p)
    ids = _Ids()
    guidance = float(p.get("guidance", d.get("guidance", 4.0)))

    graph: Graph = {
        "1": {"class_type": "UNETLoader", "inputs": {
            "unet_name": _file_by_target(entry, "diffusion_models"), "weight_dtype": "default"}},
        "2": {"class_type": "CLIPLoader", "inputs": {
            "clip_name": _file_by_target(entry, "text_encoders"), "type": "longcat_image"}},
        "3": {"class_type": "VAELoader", "inputs": {"vae_name": _file_by_target(entry, "vae")}},
        "4": {"class_type": "CLIPTextEncode", "inputs": {"text": p["prompt"], "clip": ["2", 0]}},
        "5": {"class_type": "CLIPTextEncode",
              "inputs": {"text": p.get("negative_prompt", ""), "clip": ["2", 0]}},
        "6": {"class_type": "FluxGuidance",
              "inputs": {"conditioning": ["4", 0], "guidance": guidance}},
        "7": {"class_type": "FluxGuidance",
              "inputs": {"conditioning": ["5", 0], "guidance": guidance}},
        "8": {"class_type": "CFGNorm",
              "inputs": {"model": ["1", 0], "strength": 1.0, "pre_cfg": False}},
    }
    _image_tail(graph, p, d, seed, "longcat", model=["8", 0], pos=["6", 0], neg=["7", 0],
                vae=["3", 0], latent_node="EmptySD3LatentImage", ids=ids)
    return graph, seed


def build_zimage(entry: dict[str, Any], p: dict[str, Any]) -> tuple[Graph, int]:
    """Z-Image: Lumina2-Architektur mit Qwen3-4B als Text-Encoder.

    Nachgebaut nach ComfyUIs Template image_z_image.json. Die Falle steckt im
    CLIPLoader: der Typ heisst **lumina2**, nicht "zimage". ComfyUI erkennt den
    Qwen3-Encoder am State-Dict und waehlt den richtigen Tokenizer selbst -- mit
    einem anderen Typ baut es stillschweigend den falschen und liefert Unsinn.
    """
    d = defaults_for("zimage")
    seed = _seed(p)
    ids = _Ids()

    graph: Graph = {
        "1": {"class_type": "UNETLoader", "inputs": {
            "unet_name": _file_by_target(entry, "diffusion_models"), "weight_dtype": "default"}},
        "2": {"class_type": "CLIPLoader", "inputs": {
            "clip_name": _file_by_target(entry, "text_encoders"), "type": "lumina2"}},
        "3": {"class_type": "VAELoader", "inputs": {"vae_name": _file_by_target(entry, "vae")}},
        "4": {"class_type": "CLIPTextEncode", "inputs": {"text": p["prompt"], "clip": ["2", 0]}},
        "5": {"class_type": "CLIPTextEncode",
              "inputs": {"text": p.get("negative_prompt", ""), "clip": ["2", 0]}},
        "6": {"class_type": "ModelSamplingAuraFlow",
              "inputs": {"model": ["1", 0], "shift": d.get("shift", 3.0)}},
    }
    pos, neg = _apply_controlnet(graph, p, ["4", 0], ["5", 0], ["3", 0], ids)
    _image_tail(graph, p, d, seed, "zimage", model=["6", 0], pos=pos, neg=neg, vae=["3", 0],
                latent_node="EmptySD3LatentImage", ids=ids)
    return graph, seed


def build_krea2(entry: dict[str, Any], p: dict[str, Any]) -> tuple[Graph, int]:
    """Krea 2 (Krea.ai, Juni 2026): Single-Stream-DiT mit 12 Mrd. Parametern, Qwen3-VL-4B als
    Text-Encoder (CLIPLoader-Typ "krea2") und dem VAE von Qwen-Image.

    Nachgebaut nach ComfyUIs Vorlage image_krea2_turbo_t2i.json: 8 Schritte, cfg 1, euler/simple,
    als Negativ ConditioningZeroOut des positiven Textes. Den Prompt-Ausbau der Vorlage
    (TextGenerate) uebernimmt hier "Prompt ausbauen".

    Mit Referenzbildern (Stil-Referenz, seit 0.5.10) nach der Vorlage
    image_krea2_turbo_int8_image_style_reference.json: die Stil-LoRA von ostris (1,0) hinter dem
    Modell, ModelSamplingFlux (1,15 / 0,5), die Bilder ueber TextEncodeQwenImageEditPlus (der
    Qwen3-VL-Encoder hat den Bildteil) und FluxKontextMultiReferenceLatentMethod
    ("index_timestep_zero"), CFGGuider mit cfg 1, euler/simple. Ohne die optionale LoRA-Datei
    meldet registry.features_for keine Referenzen, jobs lehnt sie dann mit Hinweis ab.
    """
    d = defaults_for(entry["workflow"])
    seed = _seed(p)
    ids = _Ids()

    graph: Graph = {
        "1": {"class_type": "UNETLoader", "inputs": {
            "unet_name": _file_by_target(entry, "diffusion_models"), "weight_dtype": "default"}},
        "2": {"class_type": "CLIPLoader", "inputs": {
            "clip_name": _file_by_target(entry, "text_encoders"), "type": "krea2", "device": "default"}},
        "3": {"class_type": "VAELoader", "inputs": {"vae_name": _file_by_target(entry, "vae")}},
    }
    refs = p.get("reference_images") or []
    if refs:
        width, height = int(p.get("width", 1024)), int(p.get("height", 1024))
        lora, shift, enc, method, neg = ids(), ids(), ids(), ids(), ids()
        graph[lora] = {"class_type": "LoraLoaderModelOnly", "inputs": {
            "model": ["1", 0], "lora_name": _file_by_target(entry, "loras"), "strength_model": 1.0}}
        graph[shift] = {"class_type": "ModelSamplingFlux", "inputs": {
            "model": [lora, 0], "max_shift": 1.15, "base_shift": 0.5, "width": width, "height": height}}
        images: dict[str, Ref] = {}
        for i, name in enumerate(refs[:3]):
            load = ids()
            graph[load] = {"class_type": "LoadImage", "inputs": {"image": name}}
            images[f"image{i + 1}"] = [load, 0]
        graph[enc] = {"class_type": "TextEncodeQwenImageEditPlus", "inputs": {
            "clip": ["2", 0], "prompt": p["prompt"], "vae": ["3", 0], **images}}
        graph[method] = {"class_type": "FluxKontextMultiReferenceLatentMethod", "inputs": {
            "conditioning": [enc, 0], "reference_latents_method": "index_timestep_zero"}}
        graph[neg] = {"class_type": "ConditioningZeroOut", "inputs": {"conditioning": [method, 0]}}
        guider, sel, sched, noise, latent, samp, dec, save = (ids() for _ in range(8))
        graph[guider] = {"class_type": "CFGGuider", "inputs": {
            "model": [shift, 0], "positive": [method, 0], "negative": [neg, 0], "cfg": _pick(p, d, "cfg")}}
        graph[sel] = {"class_type": "KSamplerSelect", "inputs": {"sampler_name": p.get("sampler") or d["sampler"]}}
        graph[sched] = {"class_type": "BasicScheduler", "inputs": {
            "model": [shift, 0], "scheduler": p.get("scheduler") or d["scheduler"],
            "steps": int(_pick(p, d, "steps")), "denoise": 1.0}}
        graph[noise] = {"class_type": "RandomNoise", "inputs": {"noise_seed": seed}}
        graph[latent] = {"class_type": "EmptyLatentImage", "inputs": {
            "width": width, "height": height, "batch_size": int(p.get("batch_size", 1))}}
        graph[samp] = {"class_type": "SamplerCustomAdvanced", "inputs": {
            "noise": [noise, 0], "guider": [guider, 0], "sampler": [sel, 0], "sigmas": [sched, 0],
            "latent_image": [latent, 0]}}
        graph[dec] = {"class_type": "VAEDecode", "inputs": {"samples": [samp, 0], "vae": ["3", 0]}}
        graph[save] = {"class_type": "SaveImage", "inputs": {"images": [dec, 0], "filename_prefix": "nvai"}}
        return graph, seed

    graph["4"] = {"class_type": "CLIPTextEncode", "inputs": {"text": p["prompt"], "clip": ["2", 0]}}
    graph["5"] = {"class_type": "ConditioningZeroOut", "inputs": {"conditioning": ["4", 0]}}
    pos, neg = _apply_controlnet(graph, p, ["4", 0], ["5", 0], ["3", 0], ids)
    _image_tail(graph, p, d, seed, entry["workflow"], model=["1", 0], pos=pos, neg=neg, vae=["3", 0],
                latent_node="EmptyLatentImage", ids=ids)
    return graph, seed


def build_qwen_image(entry: dict[str, Any], p: dict[str, Any]) -> tuple[Graph, int]:
    """Qwen-Image 2512: MMDiT mit Qwen2.5-VL-7B als Text-Encoder.

    Nachgebaut nach ComfyUIs Template image_qwen_Image_2512.json; der CLIPLoader-Typ
    heisst "qwen_image". Liegt im Katalogeintrag eine Datei fuer loras, wird sie wie
    die Lightning-LoRA im Template zwischen Modell und Sampling-Shift gehaengt.
    """
    wf = entry["workflow"]
    d = defaults_for(wf)
    seed = _seed(p)
    ids = _Ids()
    # Nur die volle Fassung rechnet mit CFG -- bei Lightning (cfg 1) bliebe der
    # Negativprompt ohnehin ungenutzt.
    negative = p.get("negative_prompt") or (QWEN_IMAGE_NEGATIVE if wf == "qwen_image" else "")

    graph: Graph = {
        "1": {"class_type": "UNETLoader", "inputs": {
            "unet_name": _file_by_target(entry, "diffusion_models"), "weight_dtype": "default"}},
        "2": {"class_type": "CLIPLoader", "inputs": {
            "clip_name": _file_by_target(entry, "text_encoders"), "type": "qwen_image"}},
        "3": {"class_type": "VAELoader", "inputs": {"vae_name": _file_by_target(entry, "vae")}},
        "4": {"class_type": "CLIPTextEncode", "inputs": {"text": p["prompt"], "clip": ["2", 0]}},
        "5": {"class_type": "CLIPTextEncode", "inputs": {"text": negative, "clip": ["2", 0]}},
    }
    model: Ref = ["1", 0]
    if any(f["target"] == "loras" for f in entry["files"]):
        graph["7"] = {"class_type": "LoraLoaderModelOnly", "inputs": {
            "model": model, "lora_name": _file_by_target(entry, "loras"), "strength_model": 1.0}}
        model = ["7", 0]
    graph["6"] = {"class_type": "ModelSamplingAuraFlow",
                  "inputs": {"model": model, "shift": d.get("shift", 3.1)}}
    _image_tail(graph, p, d, seed, wf, model=["6", 0], pos=["4", 0], neg=["5", 0],
                vae=["3", 0], latent_node="EmptySD3LatentImage", ids=ids)
    return graph, seed


def build_qwen_image21(entry: dict[str, Any], p: dict[str, Any]) -> tuple[Graph, int]:
    """Qwen-Image 2.1: 7-Mrd.-DiT mit Qwen3-VL-8B als Text-Encoder, 64-Kanal-Latent.

    Nachgebaut nach ComfyUIs Vorlagen image_qwen_image_2_1_t2i.json und *_image_edit.json.
    TextEncodeQwenImage21 kodiert Prompt und Negativprompt und nimmt die Referenzbilder
    (im Prompt <image1>, <image2> ...; so setzt sie der Tokenizer). Mit Referenzen kommt das Latent aus dem Encoder,
    in der Groesse der ersten Referenz -- laut ComfyUI verschiebt jede andere Groesse die
    Bearbeitung. Ohne Referenzen ein leeres Latent im gewaehlten Format; EmptyLatentImage
    passt ComfyUI beim Sampeln selbst auf 64 Kanaele und Faktor 16 an.
    """
    wf = entry["workflow"]
    d = defaults_for(wf)
    seed = _seed(p)
    ids = _Ids()
    width, height = int(p.get("width", 1024)), int(p.get("height", 1024))

    graph: Graph = {
        "1": {"class_type": "UNETLoader", "inputs": {
            "unet_name": _file_by_target(entry, "diffusion_models"), "weight_dtype": "default"}},
        "2": {"class_type": "CLIPLoader", "inputs": {
            "clip_name": _file_by_target(entry, "text_encoders"), "type": "qwen_image"}},
        "3": {"class_type": "VAELoader", "inputs": {"vae_name": _file_by_target(entry, "vae")}},
    }
    # Referenzen auf etwa die gewaehlte Flaeche bringen, auf Vielfache von 32.
    resolution = max(256, round((width * height) ** 0.5 / 32) * 32)
    enc: dict[str, Any] = {"clip": ["2", 0], "vae": ["3", 0], "prompt": p["prompt"],
                           "negative_prompt": p.get("negative_prompt", ""),
                           "resolution": resolution}
    refs = p.get("reference_images") or []
    for i, name in enumerate(refs):
        load = ids()
        graph[load] = {"class_type": "LoadImage", "inputs": {"image": name}}
        enc[f"images.image_{i + 1}"] = [load, 0]
    graph["4"] = {"class_type": "TextEncodeQwenImage21", "inputs": enc}

    if refs:
        latent: Ref = ["4", 2]
        batch = int(p.get("batch_size", 1))
        if batch > 1:
            rep = ids()
            graph[rep] = {"class_type": "RepeatLatentBatch", "inputs": {"samples": latent, "amount": batch}}
            latent = [rep, 0]
    else:
        graph["5"] = {"class_type": "EmptyLatentImage", "inputs": {
            "width": width, "height": height, "batch_size": int(p.get("batch_size", 1))}}
        latent = ["5", 0]
    graph["6"] = {"class_type": "KSampler", "inputs": {
        "seed": seed, "steps": int(_pick(p, d, "steps")), "cfg": _pick(p, d, "cfg"),
        "sampler_name": p.get("sampler") or d["sampler"],
        "scheduler": p.get("scheduler") or d["scheduler"], "denoise": 1.0,
        "model": ["1", 0], "positive": ["4", 0], "negative": ["4", 1], "latent_image": latent}}
    graph["7"] = {"class_type": "VAEDecode", "inputs": {"samples": ["6", 0], "vae": ["3", 0]}}
    graph["8"] = {"class_type": "SaveImage", "inputs": {"images": ["7", 0], "filename_prefix": "nvai"}}
    return graph, seed


def build_flux3(entry: dict[str, Any], p: dict[str, Any]) -> tuple[Graph, int]:
    """FLUX 3 Image Klein: 5,6-Mrd.-DiT mit Qwen3-VL-4B als Text-Encoder.

    Nachgebaut nach ComfyUIs Vorlagen image_flux3_klein_{distilled_,}t2i.json und
    *_image_edit.json. Der Prompt kommt fertig ausgebaut an: jobs.py laesst vorher den
    Upsampler laufen und legt das Ergebnis unter "caption" ab (flux3_prompt.py).

    Referenzbilder haengt ReferenceMultiLatent an beide Conditionings -- das ist der
    Bearbeitungsweg dieses Modells. Die Groesse bestimmt trotzdem das Leerlatent, damit
    das gewaehlte Format gilt; die Vorlage nimmt sonst die Groesse der ersten Referenz.
    """
    wf = entry["workflow"]
    d = defaults_for(wf)
    seed = _seed(p)
    ids = _Ids()

    graph: Graph = {
        "1": {"class_type": "UNETLoader", "inputs": {
            "unet_name": _file_by_target(entry, "diffusion_models"), "weight_dtype": "default"}},
        # Der Upsampler liegt ebenfalls in text_encoders -- "qwen3vl" trennt die beiden.
        "2": {"class_type": "CLIPLoader", "inputs": {
            "clip_name": _file_by_target(entry, "text_encoders", "qwen3vl"), "type": "flux3"}},
        "3": {"class_type": "VAELoader", "inputs": {"vae_name": _file_by_target(entry, "vae")}},
        "4": {"class_type": "CLIPTextEncode",
              "inputs": {"text": p.get("caption") or p["prompt"], "clip": ["2", 0]}},
        "5": {"class_type": "CLIPTextEncode",
              "inputs": {"text": p.get("negative_prompt", ""), "clip": ["2", 0]}},
    }
    pos: Ref = ["4", 0]
    neg: Ref = ["5", 0]

    refs = p.get("reference_images") or []
    if refs:
        ref = ids()
        # Referenzen rechnet die Vorlage mit 1 MP. Beim Restaurieren groesser (jobs.RESTORE_PIXELS),
        # sonst sieht das Modell vom Original weniger Detail, als es ausgeben soll.
        inputs: dict[str, Any] = {"positive": pos, "negative": neg, "vae": ["3", 0], "resolution": "resize",
                                  "resolution.megapixels": float(p.get("reference_megapixels") or 1.0)}
        for i, name in enumerate(refs):
            load = ids()
            graph[load] = {"class_type": "LoadImage", "inputs": {"image": name}}
            inputs[f"images.image{i}"] = [load, 0]
        graph[ref] = {"class_type": "ReferenceMultiLatent", "inputs": inputs}
        pos, neg = [ref, 0], [ref, 1]

    _image_tail(graph, p, d, seed, wf, model=["1", 0], pos=pos, neg=neg, vae=["3", 0],
                latent_node="EmptyFlux2LatentImage", ids=ids)
    return graph, seed


def _load_refs(graph: Graph, p: dict[str, Any], ids: _Ids, key: str) -> dict[str, Ref]:
    """Referenzbilder laden; Eingangsnamen wie images.image_1 (Autogrow-Eingaenge)."""
    out: dict[str, Ref] = {}
    for i, name in enumerate(p.get("reference_images") or []):
        load = ids()
        graph[load] = {"class_type": "LoadImage", "inputs": {"image": name}}
        out[f"{key}.image_{i + 1}"] = [load, 0]
    return out


def _sample_custom(graph: Graph, p: dict[str, Any], d: dict[str, Any], seed: int, ids: _Ids, *,
                   model: Ref, sigma_model: Ref, pos: Ref, neg: Ref, latent: Ref, sampler: Ref) -> Ref:
    """SamplerCustom mit BasicScheduler -- so rechnen die Vorlagen von Boogu und HiDream-O1."""
    sched, samp = ids(), ids()
    graph[sched] = {"class_type": "BasicScheduler", "inputs": {
        "model": sigma_model, "scheduler": p.get("scheduler") or d["scheduler"],
        "steps": int(_pick(p, d, "steps")), "denoise": 1.0}}
    graph[samp] = {"class_type": "SamplerCustom", "inputs": {
        "model": model, "add_noise": True, "noise_seed": seed, "cfg": _pick(p, d, "cfg"),
        "positive": pos, "negative": neg, "sampler": sampler, "sigmas": [sched, 0],
        "latent_image": latent}}
    return [samp, 0]


def build_boogu(entry: dict[str, Any], p: dict[str, Any]) -> tuple[Graph, int]:
    """Boogu-Image 0.1: 10-Mrd.-DiT mit Qwen3-VL-8B als Text-Encoder (CLIPLoader-Typ "boogu").

    Nachgebaut nach ComfyUIs Vorlagen image_boogu_image_0_1_turbo_t2i.json und *_edit.json.
    Turbo: KSampler mit lcm/sgm_uniform, cfg 1, Negativ ausgenullt. Base und Edit: SamplerCustom,
    die Sigmas kommen vom Modell mit ModelSamplingAuraFlow (shift 3,16), gerechnet wird mit dem
    unveraenderten Modell -- genau so in der Vorlage. Edit nimmt die Referenz ueber
    TextEncodeBooguEdit (Bildverstaendnis im Positiv, Referenzlatent in beiden).
    """
    wf = entry["workflow"]
    d = defaults_for(wf)
    seed = _seed(p)
    ids = _Ids()
    width, height = int(p.get("width", 1024)), int(p.get("height", 1024))
    batch = int(p.get("batch_size", 1))

    graph: Graph = {
        "1": {"class_type": "UNETLoader", "inputs": {
            "unet_name": _file_by_target(entry, "diffusion_models"), "weight_dtype": "default"}},
        "2": {"class_type": "CLIPLoader", "inputs": {
            "clip_name": _file_by_target(entry, "text_encoders"), "type": "boogu"}},
        "3": {"class_type": "VAELoader", "inputs": {"vae_name": _file_by_target(entry, "vae")}},
        "5": {"class_type": "EmptyLatentImage", "inputs": {
            "width": width, "height": height, "batch_size": batch}},
    }
    refs = _load_refs(graph, p, ids, "images")
    if refs:
        graph["4"] = {"class_type": "TextEncodeBooguEdit", "inputs": {
            "clip": ["2", 0], "vae": ["3", 0], "prompt": p["prompt"],
            "negative_prompt": p.get("negative_prompt", ""), **refs}}
        pos, neg = ["4", 0], ["4", 1]
    else:
        graph["4"] = {"class_type": "CLIPTextEncode", "inputs": {"text": p["prompt"], "clip": ["2", 0]}}
        pos = ["4", 0]
        if wf == "boogu_turbo":
            graph["6"] = {"class_type": "ConditioningZeroOut", "inputs": {"conditioning": pos}}
        else:
            graph["6"] = {"class_type": "CLIPTextEncode",
                          "inputs": {"text": p.get("negative_prompt", ""), "clip": ["2", 0]}}
        neg = ["6", 0]

    if wf == "boogu_turbo" and not refs:
        graph["7"] = {"class_type": "KSampler", "inputs": {
            "seed": seed, "steps": int(_pick(p, d, "steps")), "cfg": _pick(p, d, "cfg"),
            "sampler_name": p.get("sampler") or d["sampler"],
            "scheduler": p.get("scheduler") or d["scheduler"], "denoise": 1.0,
            "model": ["1", 0], "positive": pos, "negative": neg, "latent_image": ["5", 0]}}
        samples: Ref = ["7", 0]
    else:
        shift, sel = ids(), ids()
        graph[shift] = {"class_type": "ModelSamplingAuraFlow",
                        "inputs": {"model": ["1", 0], "shift": d.get("shift", 3.16)}}
        graph[sel] = {"class_type": "KSamplerSelect",
                      "inputs": {"sampler_name": p.get("sampler") or d["sampler"]}}
        samples = _sample_custom(graph, p, d, seed, ids, model=["1", 0], sigma_model=[shift, 0],
                                 pos=pos, neg=neg, latent=["5", 0], sampler=[sel, 0])
    graph["8"] = {"class_type": "VAEDecode", "inputs": {"samples": samples, "vae": ["3", 0]}}
    graph["9"] = {"class_type": "SaveImage", "inputs": {"images": ["8", 0], "filename_prefix": "nvai"}}
    return graph, seed


def build_hidream_o1(entry: dict[str, Any], p: dict[str, Any]) -> tuple[Graph, int]:
    """HiDream-O1-Image: 8-Mrd.-Pixelraum-Modell; Text-Encoder und VAE stecken im Checkpoint.

    Nachgebaut nach ComfyUIs Vorlagen image_hidream_o1_dev.json und image_hidream_o1.json:
    ModelNoiseScale (dev 7,6, voll 8,0), BasicScheduler "normal", SamplerCustom. Dev rechnet
    mit SamplerLCM bei cfg 1, die volle Fassung mit dpmpp_2m_sde_gpu bei cfg 5 und glaettet
    Patch-Naehte. Referenzbilder haengt HiDreamO1ReferenceImages an beide Conditionings.
    Den Prompt-Ausbau der Vorlage (Gemma 4) laesst NVAI-open weg -- dafuer gibt es "Prompt ausbauen".
    """
    wf = entry["workflow"]
    d = defaults_for(wf)
    seed = _seed(p)
    ids = _Ids()
    width, height = int(p.get("width", 2048)), int(p.get("height", 2048))

    graph: Graph = {
        "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": _ckpt(entry)}},
        "2": {"class_type": "ModelNoiseScale",
              "inputs": {"model": ["1", 0], "noise_scale": d.get("noise_scale", 8.0)}},
        "3": {"class_type": "CLIPTextEncode", "inputs": {"text": p["prompt"], "clip": ["1", 1]}},
        "4": {"class_type": "CLIPTextEncode",
              "inputs": {"text": p.get("negative_prompt", ""), "clip": ["1", 1]}},
        "5": {"class_type": "EmptyHiDreamO1LatentImage", "inputs": {
            "width": max(64, width // 32 * 32), "height": max(64, height // 32 * 32),
            "batch_size": int(p.get("batch_size", 1))}},
    }
    pos, neg = ["3", 0], ["4", 0]
    refs = _load_refs(graph, p, ids, "images")
    if refs:
        ref = ids()
        graph[ref] = {"class_type": "HiDreamO1ReferenceImages",
                      "inputs": {"positive": pos, "negative": neg, **refs}}
        pos, neg = [ref, 0], [ref, 1]

    model: Ref = ["2", 0]
    sel = ids()
    if wf == "hidream_o1_dev":
        graph[sel] = {"class_type": "SamplerLCM",
                      "inputs": {"s_noise": 1.0, "s_noise_end": 1.0, "noise_clip_std": 2.5}}
    else:
        smooth = ids()
        graph[smooth] = {"class_type": "HiDreamO1PatchSeamSmoothing", "inputs": {
            "model": model, "start_percent": 0.8, "end_percent": 1.0, "pattern": "single_shift",
            "passes": "ramp_2_4", "blend": "median", "strength": 1.0}}
        model = [smooth, 0]
        graph[sel] = {"class_type": "KSamplerSelect",
                      "inputs": {"sampler_name": p.get("sampler") or d["sampler"]}}
    samples = _sample_custom(graph, p, d, seed, ids, model=model, sigma_model=["2", 0],
                             pos=pos, neg=neg, latent=["5", 0], sampler=[sel, 0])
    graph["8"] = {"class_type": "VAEDecode", "inputs": {"samples": samples, "vae": ["1", 2]}}
    graph["9"] = {"class_type": "SaveImage", "inputs": {"images": ["8", 0], "filename_prefix": "nvai"}}
    return graph, seed


def outpaint_pad_graph(image: str, outpaint: list[int]) -> Graph:
    """Vorlauf fuer Bearbeitungsmodelle: das Bild mit grauem Rand als eigene Datei."""
    left, top, right, bottom = (int(v) for v in outpaint)
    return {
        "1": {"class_type": "LoadImage", "inputs": {"image": image}},
        "2": {"class_type": "ImagePadForOutpaint", "inputs": {
            "image": ["1", 0], "left": left, "top": top, "right": right, "bottom": bottom,
            "feathering": 0}},
        "3": {"class_type": "SaveImage", "inputs": {"filename_prefix": "nvai_pad", "images": ["2", 0]}},
    }


def build_moss_image(entry: dict[str, Any], p: dict[str, Any]) -> tuple[Graph, int]:
    """MOSS-Image (OpenMOSS, 16.10.2026): Single-Stream-DiT mit 5 Mrd. Parametern im Latentraum von FLUX.2,
    Qwen3.5-9B als Text-Encoder (CLIPLoader-Typ "moss_image"), die kleine FLUX.2-VAE (Apache-2.0).

    Nachgebaut nach ComfyUIs Vorlage image_moss_image_t2i.json: CLIPTextEncode positiv und negativ,
    EmptyFlux2LatentImage, KSampler (25 Schritte, cfg 2,5, er_sde/simple). Den Prompt-Ausbau der Vorlage
    (TextGenerate auf demselben Text-Encoder) erledigt jobs._moss_caption vorher, damit die Beschreibung im
    Asset steht. Skip-Layer-Guidance (Schicht 22, erste Haelfte) ist dort aus; `slg` schaltet sie ein.
    """
    d = defaults_for(entry["workflow"])
    seed = _seed(p)
    ids = _Ids()
    graph: Graph = {
        "1": {"class_type": "UNETLoader", "inputs": {
            "unet_name": _file_by_target(entry, "diffusion_models"), "weight_dtype": "default"}},
        "2": {"class_type": "CLIPLoader", "inputs": {
            "clip_name": _file_by_target(entry, "text_encoders"), "type": "moss_image", "device": "default"}},
        "3": {"class_type": "VAELoader", "inputs": {"vae_name": _file_by_target(entry, "vae")}},
        "4": {"class_type": "CLIPTextEncode",
              "inputs": {"text": p.get("caption") or p["prompt"], "clip": ["2", 0]}},
        "5": {"class_type": "CLIPTextEncode",
              "inputs": {"text": p.get("negative_prompt") or MOSS_IMAGE_NEGATIVE, "clip": ["2", 0]}},
    }
    model: Ref = ["1", 0]
    if p.get("slg"):
        slg = ids()
        graph[slg] = {"class_type": "SkipLayerGuidanceDiTSimple", "inputs": {
            "model": model, "double_layers": "", "single_layers": "22", "start_percent": 0.0, "end_percent": 0.5}}
        model = [slg, 0]
    _image_tail(graph, p, d, seed, "moss_image", model=model, pos=["4", 0], neg=["5", 0], vae=["3", 0],
                latent_node="EmptyFlux2LatentImage", ids=ids)
    return graph, seed


def moss_caption_graph(text_encoder: str, prompt: str) -> Graph:
    """Prompt-Ausbau von MOSS-Image wie in ComfyUIs Vorlage: TextGenerate auf dem eigenen Text-Encoder mit
    dem Enhancer-Systemprompt von OpenMOSS (MOSS_ENHANCER_SYSTEM); PreviewAny liefert den Text zurueck."""
    return {
        "1": {"class_type": "CLIPLoader", "inputs": {
            "clip_name": text_encoder, "type": "moss_image", "device": "default"}},
        "2": {"class_type": "PrimitiveStringMultiline", "inputs": {"value": MOSS_ENHANCER_SYSTEM}},
        "3": {"class_type": "TextGenerate", "inputs": {
            "clip": ["1", 0], "prompt": prompt, "max_length": 4096, "sampling_mode": "on",
            "sampling_mode.temperature": 0.7, "sampling_mode.top_k": 64, "sampling_mode.top_p": 0.95,
            "sampling_mode.min_p": 0.05, "sampling_mode.repetition_penalty": 1.0, "sampling_mode.seed": 0,
            "sampling_mode.presence_penalty": 0.0, "thinking": False, "use_default_template": True,
            "mtp": "auto", "system_prompt": ["2", 0]}},
        "4": {"class_type": "PreviewAny", "inputs": {"source": ["3", 0]}},
    }


def build_image(entry: dict[str, Any], p: dict[str, Any]) -> tuple[Graph, int]:
    wf = entry["workflow"]
    if wf == "moss_image":
        return build_moss_image(entry, p)
    if wf in BOOGU_WORKFLOWS:
        return build_boogu(entry, p)
    if wf in HIDREAM_O1_WORKFLOWS:
        return build_hidream_o1(entry, p)
    if wf == "chroma":
        return build_chroma(entry, p)
    if wf == "longcat":
        return build_longcat(entry, p)
    if wf == "zimage":
        return build_zimage(entry, p)
    if wf == "krea2_turbo":
        return build_krea2(entry, p)
    if wf in ("qwen_image", "qwen_image_lightning"):
        return build_qwen_image(entry, p)
    if wf == "qwen_image21":
        return build_qwen_image21(entry, p)
    if wf in FLUX3_WORKFLOWS:
        return build_flux3(entry, p)
    d = defaults_for(wf)
    seed = _seed(p)
    ids = _Ids()
    # SD3/FLUX arbeiten mit 16-Kanal-Latents und brauchen einen anderen Latent-Node.
    latent_node = "EmptySD3LatentImage" if wf in ("flux", "flux-dev", "sd3") else "EmptyLatentImage"

    graph: Graph = {
        "4": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": _ckpt(entry)}},
        "6": {"class_type": "CLIPTextEncode", "inputs": {"text": p["prompt"], "clip": ["4", 1]}},
        "7": {"class_type": "CLIPTextEncode",
              "inputs": {"text": p.get("negative_prompt", ""), "clip": ["4", 1]}},
    }
    model = _apply_slg(graph, p, wf, ["4", 0], ids)
    pos, neg = _apply_controlnet(graph, p, ["6", 0], ["7", 0], ["4", 2], ids)
    _image_tail(graph, p, d, seed, wf, model=model, pos=pos, neg=neg, vae=["4", 2],
                latent_node=latent_node, ids=ids)
    return graph, seed


# --------------------------------------------------------------- AUDIO

# Spitzenbegrenzer vor jedem Speichern (NVAIAudioLimiter, nvai/comfy_nodes/nvai_audio.py). Gemessen an
# ACE-Step (rohe Spitzen bis +5,7 dBFS): nach -3 dB griff er bei -1 dB nur 4 % der Zeit um mehr als 1 dB
# ein; ohne die Absenkung bei -1,5 dB 30 % (Blaskapelle), das presst hoerbar.
AUDIO_CEILING_DB = -1.0
# Videoton geht als AAC ins MP4, und AAC schwingt bei dichtem, lautem Material weiter ueber die Grenze
# als MP3: Schrei und jubelnde Menge (-7,5 LUFS) lagen mit -1 dB nach dem Dekodieren bei +0,7 dBFS
# (24.10.). Deshalb fuer Video mehr Abstand.
VIDEO_AUDIO_CEILING_DB = -2.5
# H.264-Qualitaet der LTX-Videos (CRF, Preset medium). ComfyUIs SaveVideo nimmt ohne Angabe 18;
# das ergab bei 1080p nur 6 bis 13 Mbit/s (Nutzer, 24.10.: "8 Mbit, das ist zu wenig").
# Per Auftrag ueberschreibbar (GenerateVideoRequest.crf).
VIDEO_CRF = 12.0
_LIMITER_ID = "90"


def build_audio(entry: dict[str, Any], p: dict[str, Any]) -> tuple[Graph, int]:
    """Audio-Graph je Workflow, vor dem Speichern immer durch den Limiter."""
    graph, seed = _audio_graph(entry, p)
    for node in list(graph.values()):
        if node["class_type"] == "SaveAudioMP3":
            graph[_LIMITER_ID] = {"class_type": "NVAIAudioLimiter", "inputs": {
                "audio": node["inputs"]["audio"], "ceiling_db": AUDIO_CEILING_DB,
                "lookahead_ms": 5.0, "release_ms": 80.0}}
            node["inputs"]["audio"] = [_LIMITER_ID, 0]
    return graph, seed


def _audio_graph(entry: dict[str, Any], p: dict[str, Any]) -> tuple[Graph, int]:
    wf = entry["workflow"]
    d = defaults_for(wf)
    seed = _seed(p)
    seconds = float(p.get("seconds", 10.0))
    ckpt = _ckpt(entry)

    common_sampler = {
        "seed": seed,
        "steps": _pick(p, d, "steps"),
        "cfg": _pick(p, d, "cfg"),
        "sampler_name": p.get("sampler") or d["sampler"],
        "scheduler": p.get("scheduler") or d["scheduler"],
        "denoise": 1.0,
    }

    if wf == "stable_audio":
        # Stable Audio konditioniert ueber Start-/Gesamtdauer statt ueber die Latent-Groesse.
        # Der Text-Encoder steckt nicht im Checkpoint und wird separat geladen.
        t5 = _file_by_target(entry, "text_encoders")
        graph: Graph = {
            "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": ckpt}},
            "9": {"class_type": "CLIPLoader", "inputs": {"clip_name": t5, "type": "stable_audio"}},
            "2": {"class_type": "CLIPTextEncode", "inputs": {"text": p["prompt"], "clip": ["9", 0]}},
            "3": {"class_type": "CLIPTextEncode",
                  "inputs": {"text": p.get("negative_prompt", ""), "clip": ["9", 0]}},
            "4": {"class_type": "ConditioningStableAudio", "inputs": {
                "positive": ["2", 0], "negative": ["3", 0],
                "seconds_start": 0.0, "seconds_total": seconds,
            }},
            "5": {"class_type": "EmptyLatentAudio", "inputs": {"seconds": seconds, "batch_size": 1}},
            "6": {"class_type": "KSampler", "inputs": {
                **common_sampler,
                "model": ["1", 0], "positive": ["4", 0], "negative": ["4", 1],
                "latent_image": ["5", 0],
            }},
            "7": {"class_type": "VAEDecodeAudio", "inputs": {"samples": ["6", 0], "vae": ["1", 2]}},
            "8": {"class_type": "SaveAudioMP3",
                  "inputs": {"audio": ["7", 0], "filename_prefix": "nvai_audio", "quality": "V0"}},
        }
        return graph, seed

    if wf == "stable_audio_3":
        # Wie ComfyUIs Vorlage audio_stable_audio_3_medium: Modell und VAE aus dem Checkpoint, der
        # Text-Encoder (T5Gemma) separat; die Laenge steht nur im Latent, ohne
        # ConditioningStableAudio. Den Prompt-Ausbau der Vorlage (Qwen3.5-2B) uebernimmt NVAI-open nicht.
        te = _file_by_target(entry, "text_encoders")
        # Trainiert auf "... BPM: X. Length: Y seconds": die Laenge passend zur Dauer setzen,
        # eine abweichende Angabe im Prompt ersetzen.
        text = re.sub(r"[\s.]*Length:\s*\d+(?:[.,]\d+)?\s*(?:seconds|secs?|s)\b\.?\s*$", "",
                      p["prompt"].strip(), flags=re.I).rstrip(" .")
        text = f"{text}. Length: {round(seconds)} seconds"
        graph = {
            "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": ckpt}},
            "9": {"class_type": "CLIPLoader", "inputs": {"clip_name": te, "type": "stable_audio"}},
            "2": {"class_type": "CLIPTextEncode", "inputs": {"text": text, "clip": ["9", 0]}},
            "3": {"class_type": "CLIPTextEncode",
                  "inputs": {"text": p.get("negative_prompt", ""), "clip": ["9", 0]}},
            "5": {"class_type": "EmptyLatentAudio", "inputs": {"seconds": seconds, "batch_size": 1}},
            "6": {"class_type": "KSampler", "inputs": {
                **common_sampler,
                "model": ["1", 0], "positive": ["2", 0], "negative": ["3", 0],
                "latent_image": ["5", 0],
            }},
            "7": {"class_type": "VAEDecodeAudio", "inputs": {"samples": ["6", 0], "vae": ["1", 2]}},
            "8": {"class_type": "SaveAudioMP3",
                  "inputs": {"audio": ["7", 0], "filename_prefix": "nvai_audio", "quality": "V0"}},
        }
        return graph, seed

    raise ValueError(t(f"Kein Audio-Builder fuer Workflow '{wf}'",
                       f"No audio builder for workflow '{wf}'"))


# --------------------------------------------------------------- VIDEO

# Bilderraster (Schritt, Rest) fuer Workflows, deren Builder nicht in dieser Datei steht (MODULE_BUILDERS).
FRAME_GRID: dict[str, tuple[int, int]] = {}


def normalize_frames(frames: int, workflow: str) -> int:
    """Wan und Kandinsky brauchen 4n+1 Frames, LTX 8n+1, Mochi 6n+1; FRAME_GRID nennt weitere."""
    if workflow in FRAME_GRID:
        grid, rest = FRAME_GRID[workflow]
        return max(0, round((frames - rest) / grid)) * grid + rest
    step = 8 if workflow in ("ltxv_t2v", "ltx25", "ltx23") else 6 if workflow == "mochi" else 4
    n = max(1, round((frames - 1) / step))
    return n * step + 1



# Feste Sigmas der destillierten LTX-2.5-Vorlagen (ComfyUI): Standard (video_ltx2_5_{t2v,i2v}.json)
# rechnet die erste Stufe auf halber Aufloesung und nach dem Hochskalieren eine zweite; DFR
# (video_ltx2_5_dfr_i2v.json) hat eigene Sigmas fuer die Detailstufe und die zeitliche Stufe.
LTX25_SIGMAS_1 = "1.0, 0.99375, 0.9875, 0.98125, 0.975, 0.909375, 0.725, 0.421875, 0.0"
LTX25_SIGMAS_2 = "0.85, 0.7250, 0.4219, 0.0"
LTX25_SIGMAS_DFR2 = "0.909375, 0.725, 0.421875, 0.0"
LTX25_SIGMAS_DFR3 = "0.975, 0.909375, 0.725, 0.421875, 0.0"
# Aus video_ltx2_5_t2v.json. Bei CFG 1 wirkt er nicht; die FLF-Vorlage bringt einen langen mit, der
# sichtbar aus einer anderen Demo stammt ("JUST DO IT", Mikrofon) -- nicht uebernommen.
LTX25_NEGATIVE = "pc game, console game, video game, cartoon, childish, ugly"
LTX25_MAX_SECONDS = 20.0
# Latent-Kette (seit 0.5.17): So viele Bilder des vorigen Clips stehen fest am Anfang des neuen (1 + 3 x 8 = 4
# Latent-Bilder, wie Lightricks' ltx-pipelines verketten). Gemessen 30.10.: Die Naht ragte dann nur 1,4-1,6-fach ueber
# die Nachbarschritte (harter Schnitt 1,9-2,5-fach).
LTX25_CARRY_FRAMES = 25
# Obergrenze der API (schemas.GenerateVideoRequest.frames): 20 s bei 24 fps, 16 s bei 30 fps.
LTX25_MAX_FRAMES = 481
# Detail-Keyframes im DFR-Weg: einer je 24 Frames (eine Sekunde bei 24 fps), wie in der Vorlage.
LTX25_KEYFRAME_INTERVAL = 24


def ltx_frames_for_seconds(seconds: float, fps: float, at_most: bool = False) -> int:
    """Frames fuer `seconds` Sekunden auf dem 8n+1-Raster von LTX, 9 bis LTX25_MAX_FRAMES.

    Der naechste Wert (5 s bei 24 fps = 121 Frames, wie die Weboberflaeche); mit at_most hoechstens
    so lang, fuer einen vorgegebenen Ton, ueber den das Video nicht hinauslaufen soll.
    """
    steps = (seconds * fps - 1) / 8
    n = int(steps) if at_most else int(steps + 0.5)
    return max(9, min(LTX25_MAX_FRAMES, 1 + n * 8))


class _LTX:
    """Graph fuer LTX-2.5 (und LTX-2.3): Bild und Ton in einem Latent, nach ComfyUIs Vorlagen.

    Wege, gewaehlt aus den Parametern (jobs._txt2video legt Bild- und Tondateien in ComfyUIs input/):
      Standard   Zwei Stufen wie video_ltx2_5_{t2v,i2v}.json: halbe Aufloesung (8 feste Sigmas),
                 Latent hochskalieren, nachrechnen (3). Mit Startbild setzt LTXVImgToVideoInplace es
                 in beiden Stufen als ersten Frame ein (Staerke 0,7, dann 1,0).
      Endbild    end_image, mit oder ohne start_image (Schleife: dasselbe Bild an beiden Enden): eine
                 Stufe in voller Aufloesung, die Bilder als Fuehrung an Frame 0 und -1 (LTXVAddGuide,
                 0,7), danach LTXVCropGuides -- wie video_ltx2_5_flf2v.json.
      Voll       quality=full (nur API, Versuch): derselbe einstufige Weg ohne Endbild. Gemessen 24.10.
                 (Che, 1080p, gleicher Seed): nicht durchgehend schaerfer als Standard (Gesicht bei
                 0,5 s +39 %, bei 3 s -30 % Kantenschaerfe), aber 56 % laenger (430 statt 275 s). Der
                 Schaerfegewinn beim Koenig (+37 %) kam vom scharfen Endbild, nicht von der einen Stufe.
      DFR        Drei Stufen wie video_ltx2_5_dfr_i2v.json: halbe Aufloesung mit Detail-Keyframes
                 (einer je Sekunde), doppelte mit dem Detail-IC-LoRA und Stufe 1 als Referenz,
                 auf Wunsch zeitlich verdoppelt (24 -> 48 fps, Ton bleibt der aus Stufe 2).
    Fuer alle Wege: auto_duration (LTXVDurationPredictor waehlt die Laenge aus dem Prompt),
    audio_input (vorgegebener Ton, eingefroren -- das Bild richtet sich danach; ins MP4 kommt das
    Original) und motion_speed (Zeitlupe: das Modell sieht fps / speed, abgespielt wird mit fps --
    darauf ist die Slow-Motion-LoRA von Lightricks trainiert).
    """

    def __init__(self, entry: dict[str, Any], p: dict[str, Any], seed: int, width: int, height: int,
                 frames: int, fps: float) -> None:
        self.entry, self.p, self.seed, self.fps = entry, p, seed, float(fps)
        self.is23 = entry["workflow"] == "ltx23"
        # Die erste Stufe rechnet auf halber Groesse, und die muss auf dem 32er-Raster liegen.
        self.w = max(256, int(width) // 64 * 64)
        self.h = max(256, int(height) // 64 * 64)
        self.frames = frames
        speed = float(p.get("motion_speed") or 1.0)
        self.cond_fps = self.fps / min(max(speed, 0.02), 1.0)
        self.g: Graph = {}
        self.ids = _Ids(start=40)
        self.audio_in: Ref | None = None
        self.frozen_audio: Ref | None = None
        self._images: dict[str, Ref] = {}

    def add(self, cls: str, **inputs: Any) -> str:
        nid = self.ids()
        self.g[nid] = {"class_type": cls, "inputs": inputs}
        return nid

    # -- Lader, Text, Laenge, Ton, Bilder ----------------------------------------------------
    def _common(self) -> None:
        e = self.entry
        self.upscaler = self.add("LatentUpscaleModelLoader",
                                 model_name=_file_by_target(e, "latent_upscale_models", "spatial"))
        if self.is23:
            # LTX-2.3 (Vorlage video_ltx2_3_*): dev-Checkpoint mit Bild- und Ton-VAE; die destillierte
            # LoRA mit 0,5 macht daraus die schnelle Fassung, Gemma 3 laedt seine Projektion aus
            # demselben Checkpoint.
            ckpt = _file_by_target(e, "checkpoints")
            loader = self.add("CheckpointLoaderSimple", ckpt_name=ckpt)
            self.model: Ref = [self.add("LoraLoaderModelOnly", model=[loader, 0],
                                        lora_name=_file_by_target(e, "loras"), strength_model=0.5), 0]
            self.clip: Ref = [self.add("LTXAVTextEncoderLoader",
                                       text_encoder=_file_by_target(e, "text_encoders"),
                                       ckpt_name=ckpt, device="default"), 0]
            self.audio_vae: Ref = [self.add("LTXVAudioVAELoader", ckpt_name=ckpt), 0]
            self.vae: Ref = [loader, 2]
        else:
            self.model = [self.add("UNETLoader", unet_name=_file_by_target(e, "diffusion_models"),
                                   weight_dtype="default"), 0]
            self.clip = [self.add("CLIPLoader", clip_name=_file_by_target(e, "text_encoders"),
                                  type="ltxv"), 0]
            self.vae = [self.add("VAELoader", vae_name=_file_by_target(e, "vae", "video")), 0]
            self.audio_vae = [self.add("VAELoader", vae_name=_file_by_target(e, "vae", "audio")), 0]
        self.pos_text = self.add("CLIPTextEncode", text=self.p["prompt"], clip=self.clip)
        self.neg_text = self.add("CLIPTextEncode", text=self.p.get("negative_prompt") or LTX25_NEGATIVE,
                                 clip=self.clip)
        name = self.p.get("audio_input")
        if name:
            # Ton vorgegeben: auf die Videolaenge kuerzen (LTXVEmptyLatentAudio rechnet mit
            # frames / fps), kodieren und einfrieren -- er wird nicht entrauscht, das Bild folgt ihm.
            load = self.add("LoadAudio", audio=name)
            trim = self.add("TrimAudioDuration", audio=[load, 0], start_index=0.0,
                            duration=round(self.frames / self.fps, 3))
            enc = self.add("LTXVAudioVAEEncode", audio=[trim, 0], audio_vae=self.audio_vae)
            self.frozen_audio = [self.add("LTXVFreezeLatent", latent=[enc, 0]), 0]
            self.audio_in = [trim, 0]

    def length(self) -> Ref | int:
        """Frames als Zahl oder, mit auto_duration, vom Laengenkopf aus dem Prompt (8n+1)."""
        if not self.p.get("auto_duration") or self.audio_in is not None:
            return self.frames
        head = self.add("ModelPatchLoader", name=_file_by_target(self.entry, "model_patches"))
        pred = self.add("LTXVDurationPredictor", model=self.model, positive=[self.pos_text, 0],
                        duration_head=[head, 0], frame_rate=self.fps, min_seconds=1.0,
                        max_seconds=min(LTX25_MAX_SECONDS, (LTX25_MAX_FRAMES - 1) / self.fps))
        return [pred, 0]

    def audio_latent(self, length: Ref | int) -> Ref:
        if self.frozen_audio is not None:
            return self.frozen_audio
        return [self.add("LTXVEmptyLatentAudio", frames_number=length, frame_rate=int(round(self.fps)),
                         batch_size=1, audio_vae=self.audio_vae), 0]

    def image(self, name: str) -> Ref:
        """Bild auf Zielgroesse, mit der Kompression, auf die LTX trainiert ist (LTXVPreprocess)."""
        if name not in self._images:
            load = self.add("LoadImage", image=name)
            scale = self.add("ImageScale", image=[load, 0], upscale_method="lanczos",
                             width=self.w, height=self.h, crop="center")
            self._images[name] = [self.add("LTXVPreprocess", image=[scale, 0], img_compression=18), 0]
        return self._images[name]

    def carry(self) -> Ref | None:
        """Latent-Kette (seit 0.5.17): die letzten Bilder des vorigen Clips als Stapel (LoadVideo), auf Zielgroesse.
        LTXVImgToVideoInplace kodiert einen Stapel als Video und schreibt die ersten Latent-Bilder fest (25 Bilder =
        4 Latent-Bilder); so setzt der Clip die Bewegung fort statt bei einem Standbild neu anzufangen. Ohne
        LTXVPreprocess: Das sind schon Videobilder, die Kompression fuer Einzelbilder braeuchten sie nicht."""
        name = self.p.get("carry_video")
        if not name:
            return None
        if "carry" not in self._images:
            load = self.add("LoadVideo", file=name)
            parts = self.add("GetVideoComponents", video=[load, 0])
            self._images["carry"] = [self.add("ImageScale", image=[parts, 0], upscale_method="bicubic",
                                              width=self.w, height=self.h, crop="center"), 0]
        return self._images["carry"]

    def conditioning(self) -> str:
        return self.add("LTXVConditioning", positive=[self.pos_text, 0], negative=[self.neg_text, 0],
                        frame_rate=self.cond_fps)

    def sample(self, av: Ref, sigmas: str, guider: str, sampler: str, seed: int) -> str:
        noise = self.add("RandomNoise", noise_seed=seed)
        sig = self.add("ManualSigmas", sigmas=sigmas)
        samp = self.add("SamplerCustomAdvanced", noise=[noise, 0], guider=[guider, 0],
                        sampler=[sampler, 0], sigmas=[sig, 0], latent_image=av)
        return self.add("LTXVSeparateAVLatent", av_latent=[samp, 0])

    def finish(self, video: Ref, audio_latent: Ref, fps_out: float, temporal_overlap: int) -> Graph:
        dec = self.add("VAEDecodeTiled", samples=video, vae=self.vae, tile_size=512, overlap=64,
                       temporal_size=64, temporal_overlap=temporal_overlap)
        if self.audio_in is not None:
            audio = self.audio_in  # vorgegebener Ton: unveraendert ins MP4
        else:
            # Wie jede Audioausgabe durch den Limiter: Der Ton von LTX-2.5 erreichte gemessen
            # bis +1,7 dBTP (24.10., Schmiede-Prompt), das AAC im MP4 uebersteuert dann.
            raw = self.add("LTXVAudioVAEDecode", samples=audio_latent, audio_vae=self.audio_vae)
            audio = [self.add("NVAIAudioLimiter", audio=[raw, 0], ceiling_db=VIDEO_AUDIO_CEILING_DB,
                              lookahead_ms=5.0, release_ms=80.0), 0]
        vid = self.add("CreateVideo", images=[dec, 0], fps=fps_out, audio=audio)
        crf = self.p.get("crf")
        self.add("SaveVideo", video=[vid, 0], filename_prefix="nvai_video", format="mp4",
                 **{"format.codec": "h264", "format.codec.encoding": "re-encode",
                    "format.codec.encoding.crf": float(VIDEO_CRF if crf is None else crf)})
        return self.g

    # -- die drei Wege -------------------------------------------------------------------------
    def standard(self, start_image: str | None) -> Graph:
        self._common()
        length = self.length()
        cond = self.conditioning()
        video: Ref = [self.add("EmptyLTXVLatentVideo", width=self.w // 2, height=self.h // 2,
                               length=length, batch_size=1), 0]
        carry = self.carry()
        image = carry if carry is not None else (self.image(start_image) if start_image else None)
        if image is not None:
            # Ein Startbild fuehrt in Stufe 1 mit 0,7 (Bewegung kommt in Gang), der Uebertrag einer Latent-Kette mit
            # 1,0: Er ist schon Bewegung und soll Bild fuer Bild bleiben (so verkettet Lightricks selbst).
            video = [self.add("LTXVImgToVideoInplace", vae=self.vae, image=image, latent=video,
                              strength=1.0 if carry is not None else 0.7, bypass=False), 0]
        if self.is23:
            sampler = self.add("KSamplerSelect", sampler_name="euler")
            guider = self.add("CFGGuider", model=self.model, positive=[cond, 0], negative=[cond, 1], cfg=1.0)
        else:
            sampler = self.add("KSamplerSelect", sampler_name="euler_ancestral")
            guider = self.add("LTXVDualCFGGuider", model=self.model, positive=[cond, 0], negative=[cond, 1],
                              video_cfg=1.0, audio_cfg=1.0)
        av1 = self.add("LTXVConcatAVLatent", video_latent=video, audio_latent=self.audio_latent(length))
        sep1 = self.sample([av1, 0], LTX25_SIGMAS_1, guider, sampler, self.seed)
        up = self.add("LTXVLatentUpsampler", samples=[sep1, 0], upscale_model=[self.upscaler, 0], vae=self.vae)
        video2: Ref = [up, 0]
        if image is not None:
            video2 = [self.add("LTXVImgToVideoInplace", vae=self.vae, image=image, latent=video2,
                               strength=1.0, bypass=False), 0]
        av2 = self.add("LTXVConcatAVLatent", video_latent=video2,
                       audio_latent=self.frozen_audio or [sep1, 1])
        sep2 = self.sample([av2, 0], LTX25_SIGMAS_2, guider, sampler, self.seed + 1)
        return self.finish([sep2, 0], [sep2, 1], self.fps, temporal_overlap=16)

    def keyframes(self, start_image: str | None, end_image: str) -> Graph:
        self._common()
        length = self.length()
        cond = self.conditioning()
        latent = self.add("EmptyLTXVLatentVideo", width=self.w, height=self.h, length=length, batch_size=1)
        pos, neg, lat = [cond, 0], [cond, 1], [latent, 0]
        for name, idx in ((start_image, 0), (end_image, -1)):
            if not name:
                continue
            guide = self.add("LTXVAddGuide", positive=pos, negative=neg, vae=self.vae, latent=lat,
                             image=self.image(name), frame_idx=idx, strength=0.7)
            pos, neg, lat = [guide, 0], [guide, 1], [guide, 2]
        av = self.add("LTXVConcatAVLatent", video_latent=lat, audio_latent=self.audio_latent(length))
        guider = self.add("LTXVDualCFGGuider", model=self.model, positive=pos, negative=neg,
                          video_cfg=1.0, audio_cfg=1.0)
        # Wie in der Vorlage: Euler Ancestral ohne Rauschen (eta 0) -- im Ergebnis ein Euler-Schritt.
        sampler = self.add("SamplerEulerAncestral", eta=0.0, s_noise=1.0)
        sep = self.sample([av, 0], LTX25_SIGMAS_1, guider, sampler, self.seed)
        crop = self.add("LTXVCropGuides", positive=pos, negative=neg, latent=[sep, 0])
        return self.finish([crop, 2], [sep, 1], self.fps, temporal_overlap=16)

    def dfr(self, start_image: str | None) -> Graph:
        self._common()
        e = self.entry
        length = self.length()
        cond = self.conditioning()
        detail = self.add("LoraLoaderModelOnly", model=self.model,
                          lora_name=_file_by_target(e, "loras", "ic-lora"), strength_model=1.0)
        euler = self.add("KSamplerSelect", sampler_name="euler")
        # Startbild: Stufe 1 vorverarbeitet wie im Standardweg, Stufe 2 und 3 unverarbeitet in
        # voller Aufloesung. Anders als ComfyUIs Vorlage, die in allen Stufen ein Viertel des
        # Bildes ("area") nimmt: LTXVImgToVideoInplace zieht ein kleineres Bild bilinear auf die
        # Latentgroesse und setzt es als festen ersten Frame ein. Bei 1080p wurde so aus 480 x 272
        # ein unscharfer Anker, und das ganze Video wurde weich (gemessen 24.10., Koenig, gleicher
        # Seed: Gesichtsschaerfe im ersten Frame 14 statt 554 im Standardweg).
        small: Ref | None = None
        pre: Ref | None = None
        carry = self.carry()
        if carry is not None:  # Latent-Kette: der Bildstapel in allen Stufen, ohne Einzelbild-Vorverarbeitung
            small = pre = carry
        elif start_image:
            load = self.add("LoadImage", image=start_image)
            small = [self.add("ImageScale", image=[load, 0], upscale_method="lanczos",
                              width=self.w, height=self.h, crop="center"), 0]
            pre = [self.add("LTXVPreprocess", image=small, img_compression=18), 0]

        # Stufe 1: halbe Aufloesung; leere Detail-Keyframes werden mit dem Video entrauscht.
        lat: Ref = [self.add("EmptyLTXVLatentVideo", width=self.w // 2, height=self.h // 2,
                             length=length, batch_size=1), 0]
        if pre is not None:
            lat = [self.add("LTXVImgToVideoInplace", vae=self.vae, image=pre, latent=lat,
                            strength=1.0, bypass=False), 0]
        kf1 = self.add("LTXVAddGeneratedKeyframes", positive=[cond, 0], negative=[cond, 1], vae=self.vae,
                       latent=lat, interval_frames=LTX25_KEYFRAME_INTERVAL, frame_indices="")
        av1 = self.add("LTXVConcatAVLatent", video_latent=[kf1, 2], audio_latent=self.audio_latent(length))
        g1 = self.add("CFGGuider", model=self.model, positive=[kf1, 0], negative=[kf1, 1], cfg=1.0)
        s1 = self.sample([av1, 0], LTX25_SIGMAS_1, g1, euler, self.seed)

        # Stufe 2: Video und Keyframes getrennt hochskalieren, Keyframes an denselben Stellen
        # weiterfuehren, die halbe Aufloesung als Referenz fuer das Detail-IC-LoRA.
        sk1 = self.add("LTXVSeparateGeneratedKeyframes", positive=[kf1, 0], negative=[kf1, 1],
                       latent=[s1, 0], keyframes_to_batch=False)
        up = self.add("LTXVLatentUpsampler", samples=[sk1, 2], upscale_model=[self.upscaler, 0], vae=self.vae)
        lat2: Ref = [up, 0]
        if small is not None:
            lat2 = [self.add("LTXVImgToVideoInplace", vae=self.vae, image=small, latent=lat2,
                             strength=1.0, bypass=False), 0]
        upk = self.add("LTXVLatentUpsampler", samples=[sk1, 3], upscale_model=[self.upscaler, 0], vae=self.vae)
        kf2 = self.add("LTXVAddGeneratedKeyframes", positive=[sk1, 0], negative=[sk1, 1], vae=self.vae,
                       latent=lat2, interval_frames=LTX25_KEYFRAME_INTERVAL, keyframes=[upk, 0],
                       frame_indices="")
        ref = self.add("LTXVAddLatentGuide", positive=[kf2, 0], negative=[kf2, 1], vae=self.vae,
                       latent=[kf2, 2], guiding_latent=[sk1, 2], latent_idx=0, strength=1.0)
        av2 = self.add("LTXVConcatAVLatent", video_latent=[ref, 2],
                       audio_latent=self.frozen_audio or [s1, 1])
        g2 = self.add("CFGGuider", model=[detail, 0], positive=[ref, 0], negative=[ref, 1], cfg=1.0)
        s2 = self.sample([av2, 0], LTX25_SIGMAS_DFR2, g2, euler, self.seed)
        sk2 = self.add("LTXVSeparateGeneratedKeyframes", positive=[ref, 0], negative=[ref, 1],
                       latent=[s2, 0], keyframes_to_batch=False)
        crop2 = self.add("LTXVCropGuides", positive=[sk2, 0], negative=[sk2, 1], latent=[sk2, 2])
        video: Ref = [crop2, 2]
        fps_out = self.fps

        if self.p.get("temporal_upscale"):
            # Stufe 3: doppelte Bildrate bei gleicher Dauer. Die Keyframes aus Stufe 2 kommen als
            # Fuehrung (0,95) an dieselben Momente, neue fuellen die Luecken; der Ton dient nur der
            # Kreuzaufmerksamkeit, ins Video geht der aus Stufe 2.
            tloader = self.add("LatentUpscaleModelLoader",
                               model_name=_file_by_target(e, "latent_upscale_models", "temporal"))
            tup = self.add("LTXVLatentUpsampler", samples=[crop2, 2], upscale_model=[tloader, 0], vae=self.vae)
            lat3: Ref = [tup, 0]
            if small is not None:
                lat3 = [self.add("LTXVImgToVideoInplace", vae=self.vae, image=small, latent=lat3,
                                 strength=1.0, bypass=False), 0]
            kfg = self.add("LTXVGeneratedKeyframesToGuides", positive=[crop2, 0], negative=[crop2, 1],
                           vae=self.vae, latent=lat3, keyframes=[sk2, 3], strength=0.95,
                           override_frame_indices="")
            kf3 = self.add("LTXVAddGeneratedKeyframes", positive=[kfg, 0], negative=[kfg, 1], vae=self.vae,
                           latent=[kfg, 2], interval_frames=LTX25_KEYFRAME_INTERVAL, keyframes=lat3,
                           frame_indices="")
            cond3 = self.add("LTXVConditioning", positive=[kf3, 0], negative=[kf3, 1],
                             frame_rate=2 * self.cond_fps)
            frozen = self.add("LTXVFreezeLatent", latent=[s2, 1])
            av3 = self.add("LTXVConcatAVLatent", video_latent=[kf3, 2], audio_latent=[frozen, 0])
            g3 = self.add("CFGGuider", model=[detail, 0], positive=[cond3, 0], negative=[cond3, 1], cfg=1.0)
            s3 = self.sample([av3, 0], LTX25_SIGMAS_DFR3, g3, euler, self.seed)
            sk3 = self.add("LTXVSeparateGeneratedKeyframes", positive=[kf3, 0], negative=[kf3, 1],
                           latent=[s3, 0], keyframes_to_batch=False)
            crop3 = self.add("LTXVCropGuides", positive=[sk3, 0], negative=[sk3, 1], latent=[sk3, 2])
            video = [crop3, 2]
            fps_out = 2 * self.fps
        return self.finish(video, [s2, 1], fps_out, temporal_overlap=8)


def _build_ltx2(entry, p, seed, width, height, frames, fps, start_image) -> tuple[Graph, int]:
    """LTX-2.5 (alle Wege, siehe _LTX) und LTX-2.3 (Standardweg). Ausgabe: MP4 mit Ton."""
    b = _LTX(entry, p, seed, width, height, frames, fps)
    if entry["workflow"] == "ltx25" and p.get("end_image"):
        return b.keyframes(start_image, p["end_image"]), seed
    if entry["workflow"] == "ltx25" and p.get("quality") == "full":
        # Derselbe einstufige Weg wie mit Endbild, nur mit dem Startbild als Fuehrung (oder ohne).
        return b.keyframes(start_image, None), seed
    if entry["workflow"] == "ltx25" and p.get("quality") == "dfr":
        return b.dfr(start_image), seed
    return b.standard(start_image), seed


def _build_kandinsky5(entry, p, d, sampler, width, height, frames, fps, negative,
                      start_image) -> tuple[Graph, int]:
    """Kandinsky 5.0 Video Lite (2B, MIT), nachgebaut nach ComfyUIs Vorlagen
    video_kandinsky5_t2v.json und *_i2v.json: Qwen2.5-VL 7B und CLIP-L als Text-Encoder,
    HunyuanVideo-VAE, Ausgabe MP4 mit 24 fps. Beim Bild-zu-Video setzt
    ReplaceVideoLatentFrames das Startbild wieder als ersten Frame ein, und
    NormalizeVideoLatentStart gleicht die Helligkeit der ersten Frames an.
    """
    w = max(256, int(width) // 16 * 16)
    h = max(256, int(height) // 16 * 16)
    graph: Graph = {
        "1": {"class_type": "UNETLoader", "inputs": {
            "unet_name": _file_by_target(entry, "diffusion_models"), "weight_dtype": "default"}},
        "2": {"class_type": "DualCLIPLoader", "inputs": {
            "clip_name1": _file_by_target(entry, "text_encoders", "qwen"),
            "clip_name2": _file_by_target(entry, "text_encoders", "clip_l"),
            "type": "kandinsky5", "device": "default"}},
        "3": {"class_type": "VAELoader", "inputs": {"vae_name": _file_by_target(entry, "vae")}},
        "4": {"class_type": "CLIPTextEncode", "inputs": {"text": p["prompt"], "clip": ["2", 0]}},
        # Die Vorlagen lassen den Negativprompt leer; NVAI-open nimmt nur einen eigenen.
        "5": {"class_type": "CLIPTextEncode", "inputs": {
            "text": p.get("negative_prompt") or "", "clip": ["2", 0]}},
        "6": {"class_type": "ModelSamplingSD3", "inputs": {"model": ["1", 0], "shift": d.get("shift", 5.0)}},
    }
    latent: dict[str, Any] = {"positive": ["4", 0], "negative": ["5", 0], "vae": ["3", 0],
                              "width": w, "height": h, "length": frames, "batch_size": 1}
    if start_image:
        graph["7"] = {"class_type": "LoadImage", "inputs": {"image": start_image}}
        graph["8"] = {"class_type": "ImageScale", "inputs": {
            "image": ["7", 0], "upscale_method": "lanczos", "width": w, "height": h, "crop": "center"}}
        latent["start_image"] = ["8", 0]
    graph["9"] = {"class_type": "Kandinsky5ImageToVideo", "inputs": latent}
    graph["10"] = {"class_type": "KSampler", "inputs": {
        **sampler, "model": ["6", 0], "positive": ["9", 0], "negative": ["9", 1],
        "latent_image": ["9", 2]}}
    samples: Ref = ["10", 0]
    if start_image:
        graph["11"] = {"class_type": "ReplaceVideoLatentFrames", "inputs": {
            "destination": ["10", 0], "source": ["9", 3], "index": 0}}
        graph["12"] = {"class_type": "NormalizeVideoLatentStart", "inputs": {
            "latent": ["11", 0], "start_frame_count": 4, "reference_frame_count": 5}}
        samples = ["12", 0]
    # Ungekachelt stuerzte ComfyUI beim HunyuanVideo-VAE ab (768 x 512 x 121, 16 GB:
    # "Fatal Python error: Aborted" in der 3D-Faltung). Gekachelt wie bei Mochi.
    graph["13"] = {"class_type": "VAEDecodeTiled", "inputs": {
        "samples": samples, "vae": ["3", 0], "tile_size": 256, "overlap": 64,
        "temporal_size": 64, "temporal_overlap": 8}}
    graph["14"] = {"class_type": "CreateVideo", "inputs": {"images": ["13", 0], "fps": fps}}
    graph["15"] = {"class_type": "SaveVideo", "inputs": {
        "video": ["14", 0], "filename_prefix": "nvai_video", "format": "mp4", "format.codec": "h264"}}
    return graph, sampler["seed"]


def _build_mochi(entry, p, sampler, width, height, frames, fps, negative) -> tuple[Graph, int]:
    """Mochi 1 preview (Genmo, 10B, Apache-2.0) nach ComfyUIs Mochi-Beispiel: T5-XXL als
    Text-Encoder, fp8-Modell, eigener VAE. Der VAE-Decoder braucht viel Speicher, deshalb
    gekachelt."""
    w = max(256, int(width) // 16 * 16)
    h = max(256, int(height) // 16 * 16)
    graph: Graph = {
        "1": {"class_type": "UNETLoader", "inputs": {
            "unet_name": _file_by_target(entry, "diffusion_models"), "weight_dtype": "default"}},
        "2": {"class_type": "CLIPLoader", "inputs": {
            "clip_name": _file_by_target(entry, "text_encoders"), "type": "mochi"}},
        "3": {"class_type": "VAELoader", "inputs": {"vae_name": _file_by_target(entry, "vae")}},
        "4": {"class_type": "CLIPTextEncode", "inputs": {"text": p["prompt"], "clip": ["2", 0]}},
        "5": {"class_type": "CLIPTextEncode", "inputs": {"text": negative, "clip": ["2", 0]}},
        "6": {"class_type": "EmptyMochiLatentVideo", "inputs": {
            "width": w, "height": h, "length": frames, "batch_size": 1}},
        "7": {"class_type": "KSampler", "inputs": {
            **sampler, "model": ["1", 0], "positive": ["4", 0], "negative": ["5", 0],
            "latent_image": ["6", 0]}},
        "8": {"class_type": "VAEDecodeTiled", "inputs": {
            "samples": ["7", 0], "vae": ["3", 0], "tile_size": 256, "overlap": 64,
            "temporal_size": 64, "temporal_overlap": 8}},
        "9": {"class_type": "CreateVideo", "inputs": {"images": ["8", 0], "fps": fps}},
        "10": {"class_type": "SaveVideo", "inputs": {
            "video": ["9", 0], "filename_prefix": "nvai_video", "format": "mp4", "format.codec": "h264"}},
    }
    return graph, sampler["seed"]


def build_video(entry: dict[str, Any], p: dict[str, Any]) -> tuple[Graph, int]:
    wf = entry["workflow"]
    d = defaults_for(wf)
    seed = _seed(p)
    width, height = p.get("width", 832), p.get("height", 480)
    frames = normalize_frames(int(p.get("frames", 49)), wf)
    fps = float(p.get("fps", 16))
    negative = p.get("negative_prompt") or DEFAULT_VIDEO_NEGATIVE

    sampler = {
        "seed": seed,
        "steps": _pick(p, d, "steps"),
        "cfg": _pick(p, d, "cfg"),
        "sampler_name": p.get("sampler") or d["sampler"],
        "scheduler": p.get("scheduler") or d["scheduler"],
        "denoise": 1.0,
    }

    # Von jobs.py gesetzt: Dateiname des Startbilds in ComfyUIs input/-Ordner.
    start_image = p.get("start_image")
    if wf in I2V_WORKFLOWS and not start_image:
        raise ValueError(t(
            f"{entry['name']} ist ein Bild-zu-Video-Modell und braucht ein Startbild.",
            f"{entry['name']} is an image-to-video model and needs a start image.",
        ))

    def save(node_in: str, idx: int = 0) -> Graph:
        return {"class_type": "SaveWEBM", "inputs": {
            "images": [node_in, idx], "filename_prefix": "nvai_video",
            "codec": "vp9", "fps": fps, "crf": 28.0}}

    if wf in ("hunyuan15_t2v", "hunyuan15_i2v"):
        return _build_hunyuan15(entry, p, wf, sampler, seed, width, height,
                                frames, negative, start_image, save)

    if wf == "wan22_i2v":
        return _build_wan22_i2v(entry, p, d, sampler, seed, width, height,
                                frames, negative, start_image, save)

    if wf in ("ltx25", "ltx23"):
        return _build_ltx2(entry, p, seed, width, height, frames, fps, start_image)

    if wf in ("kandinsky5_t2v", "kandinsky5_t2v_distilled", "kandinsky5_i2v"):
        return _build_kandinsky5(entry, p, d, sampler, width, height, frames, fps, negative,
                                 start_image)

    if wf == "mochi":
        return _build_mochi(entry, p, sampler, width, height, frames, fps, negative)

    if wf == "ltxv_t2v":
        # LTX-Video liegt als all-in-one Checkpoint vor und braucht einen eigenen
        # Conditioning-Node, der die Bildrate ins Conditioning schreibt.
        graph: Graph = {
            "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": _ckpt(entry)}},
            "2": {"class_type": "CLIPTextEncode", "inputs": {"text": p["prompt"], "clip": ["1", 1]}},
            "3": {"class_type": "CLIPTextEncode", "inputs": {"text": negative, "clip": ["1", 1]}},
            "4": {"class_type": "LTXVConditioning",
                  "inputs": {"positive": ["2", 0], "negative": ["3", 0], "frame_rate": fps}},
            "5": {"class_type": "EmptyLTXVLatentVideo", "inputs": {
                "width": width, "height": height, "length": frames, "batch_size": 1}},
            "6": {"class_type": "KSampler", "inputs": {
                **sampler, "model": ["1", 0], "positive": ["4", 0], "negative": ["4", 1],
                "latent_image": ["5", 0]}},
            "7": {"class_type": "VAEDecode", "inputs": {"samples": ["6", 0], "vae": ["1", 2]}},
            "8": {"class_type": "SaveWEBM", "inputs": {
                "images": ["7", 0], "filename_prefix": "nvai_video",
                "codec": "vp9", "fps": fps, "crf": 28.0}},
        }
        return graph, seed

    # Wan: Diffusion-Model, Text-Encoder und VAE liegen getrennt vor.
    unet = _file_by_target(entry, "diffusion_models")
    clip = _file_by_target(entry, "text_encoders")
    vae = _file_by_target(entry, "vae")

    graph = {
        "1": {"class_type": "UNETLoader", "inputs": {"unet_name": unet, "weight_dtype": "default"}},
        "2": {"class_type": "CLIPLoader", "inputs": {"clip_name": clip, "type": "wan"}},
        "3": {"class_type": "VAELoader", "inputs": {"vae_name": vae}},
        "4": {"class_type": "CLIPTextEncode", "inputs": {"text": p["prompt"], "clip": ["2", 0]}},
        "5": {"class_type": "CLIPTextEncode", "inputs": {"text": negative, "clip": ["2", 0]}},
        "6": {"class_type": "ModelSamplingSD3",
              "inputs": {"model": ["1", 0], "shift": d.get("shift", 8.0)}},
    }

    if wf == "wan_i2v":
        # Wan 2.1 I2V beschreibt das Startbild zusaetzlich ueber CLIP-Vision.
        # WanImageToVideo liefert Conditioning und passendes Leerlatent in einem.
        graph["7"] = {"class_type": "CLIPVisionLoader",
                      "inputs": {"clip_name": _file_by_target(entry, "clip_vision")}}
        graph["8"] = {"class_type": "LoadImage", "inputs": {"image": start_image}}
        graph["9"] = {"class_type": "CLIPVisionEncode",
                      "inputs": {"clip_vision": ["7", 0], "image": ["8", 0], "crop": "center"}}
        graph["10"] = {"class_type": "WanImageToVideo", "inputs": {
            "positive": ["4", 0], "negative": ["5", 0], "vae": ["3", 0],
            "width": width, "height": height, "length": frames, "batch_size": 1,
            "clip_vision_output": ["9", 0], "start_image": ["8", 0]}}
        graph["11"] = {"class_type": "KSampler", "inputs": {
            **sampler, "model": ["6", 0], "positive": ["10", 0], "negative": ["10", 1],
            "latent_image": ["10", 2]}}
        graph["12"] = {"class_type": "VAEDecode",
                       "inputs": {"samples": ["11", 0], "vae": ["3", 0]}}
        graph["13"] = save("12")
        return graph, seed

    if wf == "wan22_ti2v":
        # Das 5B-Modell hat einen eigenen VAE mit 48 Kanaelen und Faktor 16.
        # EmptyHunyuanLatentVideo (16 Kanaele, Faktor 8) passt dazu nicht -- der
        # Latent-Node muss vom VAE ausgehen. Er deckt beide Richtungen ab:
        # mit start_image wird daraus Bild-zu-Video, ohne bleibt es Text-zu-Video.
        latent: dict[str, Any] = {
            "vae": ["3", 0], "width": width, "height": height,
            "length": frames, "batch_size": 1}
        if start_image:
            graph["11"] = {"class_type": "LoadImage", "inputs": {"image": start_image}}
            latent["start_image"] = ["11", 0]
        graph["7"] = {"class_type": "Wan22ImageToVideoLatent", "inputs": latent}
    else:
        graph["7"] = {"class_type": "EmptyHunyuanLatentVideo", "inputs": {
            "width": width, "height": height, "length": frames, "batch_size": 1}}

    graph["8"] = {"class_type": "KSampler", "inputs": {
        **sampler, "model": ["6", 0], "positive": ["4", 0], "negative": ["5", 0],
        "latent_image": ["7", 0]}}
    graph["9"] = {"class_type": "VAEDecode", "inputs": {"samples": ["8", 0], "vae": ["3", 0]}}
    graph["10"] = save("9")
    return graph, seed


def _build_wan22_i2v(entry, p, d, sampler, seed, width, height,
                     frames, negative, start_image, save) -> tuple[Graph, int]:
    """Wan 2.2 A14B: zwei Experten, ein Lauf.

    Der High-Noise-Experte laeuft von Schritt 0 bis zur Grenze und gibt das Latent
    mit Restrauschen weiter; der Low-Noise-Experte zeichnet den Rest aus. Deshalb
    zwei KSamplerAdvanced statt eines KSampler -- ein normaler KSampler kann ein
    angefangenes Latent nicht fortsetzen.

    Kein CLIP-Vision: anders als bei Wan 2.1 geht das Startbild direkt ins
    Conditioning.
    """
    shift = d.get("shift", 8.0)
    steps = int(sampler["steps"])
    split = max(1, min(steps - 1, round(steps * float(d.get("boundary", 0.5)))))
    common = {
        "steps": steps, "cfg": sampler["cfg"],
        "sampler_name": sampler["sampler_name"], "scheduler": sampler["scheduler"],
        "noise_seed": seed,
    }

    graph: Graph = {
        "1": {"class_type": "UNETLoader", "inputs": {
            "unet_name": _file_by_target(entry, "diffusion_models", "high_noise"),
            "weight_dtype": "default"}},
        "2": {"class_type": "UNETLoader", "inputs": {
            "unet_name": _file_by_target(entry, "diffusion_models", "low_noise"),
            "weight_dtype": "default"}},
        "3": {"class_type": "CLIPLoader", "inputs": {
            "clip_name": _file_by_target(entry, "text_encoders"), "type": "wan"}},
        "4": {"class_type": "VAELoader", "inputs": {"vae_name": _file_by_target(entry, "vae")}},
        "5": {"class_type": "CLIPTextEncode", "inputs": {"text": p["prompt"], "clip": ["3", 0]}},
        "6": {"class_type": "CLIPTextEncode", "inputs": {"text": negative, "clip": ["3", 0]}},
        "7": {"class_type": "ModelSamplingSD3", "inputs": {"model": ["1", 0], "shift": shift}},
        "8": {"class_type": "ModelSamplingSD3", "inputs": {"model": ["2", 0], "shift": shift}},
        "9": {"class_type": "LoadImage", "inputs": {"image": start_image}},
        "10": {"class_type": "WanImageToVideo", "inputs": {
            "positive": ["5", 0], "negative": ["6", 0], "vae": ["4", 0],
            "width": width, "height": height, "length": frames, "batch_size": 1,
            "start_image": ["9", 0]}},
        "11": {"class_type": "KSamplerAdvanced", "inputs": {
            **common, "model": ["7", 0], "positive": ["10", 0], "negative": ["10", 1],
            "latent_image": ["10", 2], "add_noise": "enable",
            "start_at_step": 0, "end_at_step": split,
            "return_with_leftover_noise": "enable"}},
        "12": {"class_type": "KSamplerAdvanced", "inputs": {
            **common, "model": ["8", 0], "positive": ["10", 0], "negative": ["10", 1],
            "latent_image": ["11", 0], "add_noise": "disable",
            "start_at_step": split, "end_at_step": 10000,
            "return_with_leftover_noise": "disable"}},
        "13": {"class_type": "VAEDecode", "inputs": {"samples": ["12", 0], "vae": ["4", 0]}},
        "14": save("13"),
    }
    return graph, seed


def _build_hunyuan15(entry, p, wf, sampler, seed, width, height,
                     frames, negative, start_image, save) -> tuple[Graph, int]:
    """HunyuanVideo 1.5 (Text- und Bild-zu-Video).

    Kein ModelSamplingSD3: shift 7.0 steckt bereits in den Modell-Metadaten.
    Das Leerlatent hat 32 Kanaele bei Faktor 16 -- deshalb der eigene Latent-Node
    statt EmptyHunyuanLatentVideo, das noch mit Faktor 8 rechnet.
    """
    graph: Graph = {
        "1": {"class_type": "UNETLoader", "inputs": {
            "unet_name": _file_by_target(entry, "diffusion_models"),
            "weight_dtype": "default"}},
        # DualCLIPLoader statt CLIPLoader: den Typ hunyuan_video_15 gibt es nur dort,
        # weil das Modell zwei Text-Encoder erwartet (Qwen2.5-VL + ByT5-Glyph).
        "2": {"class_type": "DualCLIPLoader", "inputs": {
            "clip_name1": _file_by_target(entry, "text_encoders", "qwen"),
            "clip_name2": _file_by_target(entry, "text_encoders", "byt5"),
            "type": "hunyuan_video_15"}},
        "3": {"class_type": "VAELoader", "inputs": {"vae_name": _file_by_target(entry, "vae")}},
        "4": {"class_type": "CLIPTextEncode", "inputs": {"text": p["prompt"], "clip": ["2", 0]}},
        "5": {"class_type": "CLIPTextEncode", "inputs": {"text": negative, "clip": ["2", 0]}},
    }

    if wf == "hunyuan15_i2v":
        graph["6"] = {"class_type": "CLIPVisionLoader",
                      "inputs": {"clip_name": _file_by_target(entry, "clip_vision")}}
        graph["7"] = {"class_type": "LoadImage", "inputs": {"image": start_image}}
        graph["8"] = {"class_type": "CLIPVisionEncode",
                      "inputs": {"clip_vision": ["6", 0], "image": ["7", 0], "crop": "center"}}
        graph["9"] = {"class_type": "HunyuanVideo15ImageToVideo", "inputs": {
            "positive": ["4", 0], "negative": ["5", 0], "vae": ["3", 0],
            "width": width, "height": height, "length": frames, "batch_size": 1,
            "start_image": ["7", 0], "clip_vision_output": ["8", 0]}}
        graph["10"] = {"class_type": "KSampler", "inputs": {
            **sampler, "model": ["1", 0], "positive": ["9", 0], "negative": ["9", 1],
            "latent_image": ["9", 2]}}
        graph["11"] = {"class_type": "VAEDecode",
                       "inputs": {"samples": ["10", 0], "vae": ["3", 0]}}
        graph["12"] = save("11")
        return graph, seed

    graph["6"] = {"class_type": "EmptyHunyuanVideo15Latent", "inputs": {
        "width": width, "height": height, "length": frames, "batch_size": 1}}
    graph["7"] = {"class_type": "KSampler", "inputs": {
        **sampler, "model": ["1", 0], "positive": ["4", 0], "negative": ["5", 0],
        "latent_image": ["6", 0]}}
    graph["8"] = {"class_type": "VAEDecode", "inputs": {"samples": ["7", 0], "vae": ["3", 0]}}
    graph["9"] = save("8")
    return graph, seed


# ---------------------------------------------------- SCHAERFEN (SeedVR2)

# Farbabgleich nach dem Schaerfen (SeedVR2PostProcessing): "lab" uebertraegt die Farbe des Eingangsbildes im
# CIELAB-Raum und laesst das neue Detail stehen -- laut Knoten die treueste Wahl; die Vorlage steht auf "none".
SEEDVR2_COLOR = "lab"


def seedvr2_graph(entry: dict[str, Any], image: str, width: int, height: int, seed: int,
                  color_correction: str = SEEDVR2_COLOR) -> Graph:
    """SeedVR2: ein Bild in einem Schritt schaerfen, entrauschen und auf width x height bringen.

    Nachgebaut nach ComfyUIs Vorlage utility_seedvr2_7b_int8_upscale_image.json: erst auf die Zielgroesse
    skalieren (lanczos; die Vorlage nimmt einen Faktor, hier die fertigen Masse), SeedVR2Preprocess polstert
    auf Vielfache von 16, gekachelt kodieren, ein Schritt euler/simple mit cfg 1, gekachelt dekodieren,
    SeedVR2PostProcessing schneidet die Polsterung ab und gleicht die Farbe ab. Je Lauf genau ein Bild:
    SeedVR2 liest einen Bild-Stapel als Video (Frames), Varianten rechnet jobs._restore einzeln.
    """
    return {
        "1": {"class_type": "UNETLoader", "inputs": {
            "unet_name": _file_by_target(entry, "diffusion_models"), "weight_dtype": "default"}},
        "2": {"class_type": "VAELoader", "inputs": {"vae_name": _file_by_target(entry, "vae")}},
        "3": {"class_type": "LoadImage", "inputs": {"image": image}},
        "4": {"class_type": "ImageScale", "inputs": {
            "image": ["3", 0], "upscale_method": "lanczos", "width": int(width), "height": int(height),
            "crop": "disabled"}},
        "5": {"class_type": "SeedVR2Preprocess", "inputs": {"resized_images": ["4", 0]}},
        "6": {"class_type": "VAEEncodeTiled", "inputs": {
            "pixels": ["5", 0], "vae": ["2", 0], "tile_size": 512, "overlap": 128,
            "temporal_size": 4096, "temporal_overlap": 8}},
        "7": {"class_type": "SeedVR2Conditioning", "inputs": {"model": ["1", 0], "vae_conditioning": ["6", 0]}},
        "8": {"class_type": "KSampler", "inputs": {
            "seed": int(seed), "steps": 1, "cfg": 1.0, "sampler_name": "euler", "scheduler": "simple",
            "denoise": 1.0, "model": ["1", 0], "positive": ["7", 0], "negative": ["7", 1],
            "latent_image": ["6", 0]}},
        "9": {"class_type": "VAEDecodeTiled", "inputs": {
            "samples": ["8", 0], "vae": ["2", 0], "tile_size": 512, "overlap": 128,
            "temporal_size": 4096, "temporal_overlap": 8}},
        "10": {"class_type": "SeedVR2PostProcessing", "inputs": {
            "images": ["9", 0], "original_resized_images": ["4", 0],
            "color_correction_method": color_correction}},
        "11": {"class_type": "SaveImage", "inputs": {"images": ["10", 0], "filename_prefix": "nvai_sharp"}},
    }


def seedvr2_video_graph(entry: dict[str, Any], video: str, width: int, height: int, fps: float, seed: int,
                        frames_per_chunk: int = 1, color_correction: str = SEEDVR2_COLOR) -> Graph:
    """SeedVR2 auf ein Videostueck (VHS-Bereich, seit 0.5.16): nach ComfyUIs Vorlage
    utility_seedvr2_3b_int8_upscale_video.json, Ausgabe nur verlustfrei (NVAISaveMaster), vhs_tools.py part kodiert.

    Gemessen 28.10. an 100 Bildern eines kuenstlichen VHS-Clips (768 x 576, 50 Bilder/s): Die Zeit steckt im VAE, das
    Modell selbst rechnet je Stueck gut 1 s. Kacheln 1024/64 statt 512/128 (Vorlage) 247 statt 278 s (3B, 1080p).
    7B 1440 x 1080 1,9 s je Bild, 960 x 720 1,1 s. frames_per_chunk: 1 (Einzelbild) war bei 720p gleich schnell wie 33
    (111 / 105 s), schaerfer und auf ruhiger Wand nicht unruhiger (4,6 gegen 5,5/255; Eingang 6,6). Die automatische
    Stueckwahl nahm 1 Bild, solange der VAE noch Speicher hielt; deshalb fest. Die Konditionierung entsteht je Stueck
    (SeedVR2Conditioning hinter SeedVR2TemporalChunk), sonst passen ihre Masse nicht zum Stueck."""
    chunking = ({"chunking_mode": "manual", "chunking_mode.frames_per_chunk": int(frames_per_chunk)}
                if frames_per_chunk else {"chunking_mode": "auto"})
    return {
        "1": {"class_type": "UNETLoader", "inputs": {
            "unet_name": _file_by_target(entry, "diffusion_models"), "weight_dtype": "default"}},
        "2": {"class_type": "VAELoader", "inputs": {"vae_name": _file_by_target(entry, "vae")}},
        "3": {"class_type": "LoadVideo", "inputs": {"file": video}},
        "4": {"class_type": "GetVideoComponents", "inputs": {"video": ["3", 0]}},
        "5": {"class_type": "ImageScale", "inputs": {
            "image": ["4", 0], "upscale_method": "lanczos", "width": int(width), "height": int(height),
            "crop": "disabled"}},
        "6": {"class_type": "SeedVR2Preprocess", "inputs": {"resized_images": ["5", 0]}},
        "7": {"class_type": "VAEEncodeTiled", "inputs": {
            "pixels": ["6", 0], "vae": ["2", 0], "tile_size": 1024, "overlap": 64,
            "temporal_size": 128, "temporal_overlap": 8}},
        "8": {"class_type": "SeedVR2TemporalChunk", "inputs": {
            "latent": ["7", 0], "temporal_overlap": 0 if int(frames_per_chunk) == 1 else 2, **chunking}},
        "9": {"class_type": "SeedVR2Conditioning", "inputs": {"model": ["1", 0], "vae_conditioning": ["8", 0]}},
        "10": {"class_type": "KSampler", "inputs": {
            "seed": int(seed), "steps": 1, "cfg": 1.0, "sampler_name": "euler", "scheduler": "simple",
            "denoise": 1.0, "model": ["1", 0], "positive": ["9", 0], "negative": ["9", 1],
            "latent_image": ["8", 0]}},
        "11": {"class_type": "SeedVR2TemporalMerge", "inputs": {"latents": ["10", 0], "temporal_overlap": ["8", 1]}},
        "12": {"class_type": "VAEDecodeTiled", "inputs": {
            "samples": ["11", 0], "vae": ["2", 0], "tile_size": 1024, "overlap": 64,
            "temporal_size": 128, "temporal_overlap": 8}},
        "13": {"class_type": "SeedVR2PostProcessing", "inputs": {
            "images": ["12", 0], "original_resized_images": ["5", 0], "color_correction_method": color_correction}},
        "14": {"class_type": "NVAISaveMaster", "inputs": {
            "images": ["13", 0], "fps": float(fps), "filename_prefix": "nvai_vhs"}},
    }


def add_interpolation(graph: Graph, model_file: str) -> Graph:
    """Zwischenbilder vor die verlustfreie Ausgabe haengen (VHS „Takt glaetten“, seit 0.5.16): FrameInterpolate aus
    dem ComfyUI-Kern (RIFE 4.26) mit multiplier 2 rechnet die Mitte zwischen allen Nachbarbildern; welche davon bleiben,
    waehlt vhs_tools.py part. Gemessen 28.10. am echten Band (600 Bilder 960 x 720): gleichmaessige Schritte statt
    40/40/20 ms, keine sichtbaren Fehler in Gesichtern."""
    save = next(k for k, n in graph.items() if n["class_type"] == "NVAISaveMaster")
    graph["90"] = {"class_type": "FrameInterpolationModelLoader", "inputs": {"model_name": model_file}}
    graph["91"] = {"class_type": "FrameInterpolate", "inputs": {
        "interp_model": ["90", 0], "images": graph[save]["inputs"]["images"], "multiplier": 2}}
    graph[save]["inputs"]["images"] = ["91", 0]
    return graph


def interpolate_video_graph(video: str, fps: float, model_file: str) -> Graph:
    """Nur Zwischenbilder (VHS „Takt glaetten“ ohne KI-Aufbessern): Video laden, FrameInterpolate, verlustfrei."""
    return add_interpolation({
        "1": {"class_type": "LoadVideo", "inputs": {"file": video}},
        "2": {"class_type": "GetVideoComponents", "inputs": {"video": ["1", 0]}},
        "3": {"class_type": "NVAISaveMaster", "inputs": {
            "images": ["2", 0], "fps": float(fps), "filename_prefix": "nvai_vhs"}},
    }, model_file)


# ------------------------------------------------------------- Dispatch

FLUX3_WORKFLOWS = {"flux3_klein", "flux3_klein_base"}
BOOGU_WORKFLOWS = {"boogu", "boogu_turbo"}
HIDREAM_O1_WORKFLOWS = {"hidream_o1", "hidream_o1_dev"}
IMAGE_WORKFLOWS = ({"sdxl", "flux", "flux-dev", "sd3", "chroma", "longcat", "zimage",
                    "qwen_image", "qwen_image_lightning", "qwen_image21", "krea2_turbo", "moss_image"}
                   | FLUX3_WORKFLOWS | BOOGU_WORKFLOWS | HIDREAM_O1_WORKFLOWS)
# ACE-Step (v1 und 1.5) am 26.10.2026 entfernt, Nutzer: „es ist einfach immer schlecht“
AUDIO_WORKFLOWS = {"stable_audio", "stable_audio_3"}
VIDEO_WORKFLOWS = {"wan_t2v", "wan22_ti2v", "wan_i2v", "wan22_i2v",
                   "hunyuan15_t2v", "hunyuan15_i2v", "ltxv_t2v", "ltx25", "ltx23",
                   "kandinsky5_t2v", "kandinsky5_t2v_distilled", "kandinsky5_i2v", "mochi"}

# Diese laufen NICHT ueber ComfyUI, sondern in eigenen Worker-Prozessen
# (siehe nvai/mesh_workers.py). Sie haben deshalb hier bewusst keinen Graph-Builder.
EXTERNAL_WORKFLOWS = {"triposg", "trellis2"}
# Schaerfen beim Restaurieren: Graph aus seedvr2_graph, aufgerufen von jobs._restore.
UPSCALE_WORKFLOWS = {"seedvr2"}
# Builder ausserhalb dieser Datei: MiniMax H3 (minimax.py, siehe Dateiende).
MODULE_BUILDERS: dict[str, Any] = {}


# Verlustfreier Master neben jedem gespeicherten Video (NVAISaveMaster, nvai/comfy_nodes/nvai_video.py; Nutzer
# 26.10.2026: "dass die ki erstellten videos unkomprimiert sind"). Abschaltbar je Auftrag mit master=False.
MASTER_NODE = "NVAISaveMaster"
MASTER_PREFIX = "nvai_master"


def add_master(graph: Graph) -> Graph:
    """Haengt an jedes SaveVideo und SaveWEBM einen NVAISaveMaster mit denselben Bildern und derselben Bildrate.
    Der Ton kommt von vor dem Limiter: Float-PCM uebersteuert nicht, der Master behaelt die Modellausgabe."""
    for node_id, node in list(graph.items()):
        inputs = node.get("inputs", {})
        if node.get("class_type") == "SaveVideo":
            create = graph.get(str((inputs.get("video") or [None])[0]))
            if not create or create.get("class_type") != "CreateVideo":
                continue
            master = {"images": create["inputs"]["images"], "fps": create["inputs"]["fps"]}
            audio = create["inputs"].get("audio")
            if audio is not None:
                source = graph.get(str(audio[0]))
                if source and source.get("class_type") == "NVAIAudioLimiter":
                    audio = source["inputs"]["audio"]
                master["audio"] = audio
        elif node.get("class_type") == "SaveWEBM":
            master = {"images": inputs["images"], "fps": inputs["fps"]}
        else:
            continue
        graph[f"master_{node_id}"] = {"class_type": MASTER_NODE, "inputs": {**master, "filename_prefix": MASTER_PREFIX}}
    return graph


def build(entry: dict[str, Any], p: dict[str, Any]) -> tuple[Graph, int]:
    wf = entry.get("workflow")
    if wf in MODULE_BUILDERS:
        graph, seed = MODULE_BUILDERS[wf](entry, p)
        return (add_master(graph) if p.get("master", True) else graph), seed
    if wf in IMAGE_WORKFLOWS:
        return build_image(entry, p)
    if wf in AUDIO_WORKFLOWS:
        return build_audio(entry, p)
    if wf in VIDEO_WORKFLOWS:
        graph, seed = build_video(entry, p)
        return (add_master(graph) if p.get("master", True) else graph), seed
    if wf in EXTERNAL_WORKFLOWS:
        raise ValueError(t(
            f"'{entry['id']}' laeuft in einem eigenen Worker, nicht in ComfyUI "
            f"-- siehe jobs.py, Handler 'img23d'.",
            f"'{entry['id']}' runs in its own worker, not in ComfyUI "
            f"-- see jobs.py, handler 'img23d'.",
        ))
    if wf in UPSCALE_WORKFLOWS:
        raise ValueError(t(
            f"'{entry['id']}' erzeugt keine Bilder, es schaerft sie beim Restaurieren (POST /api/image/restore).",
            f"'{entry['id']}' does not create images, it sharpens them when restoring (POST /api/image/restore).",
        ))
    raise ValueError(t(
        f"Fuer '{entry['id']}' gibt es noch keinen Workflow-Builder (workflow={wf})",
        f"There is no workflow builder for '{entry['id']}' yet (workflow={wf})",
    ))


# MiniMax H3 (minimax.py): Bilderraster 17k+5 und die Builder der drei Fassungen
from . import minimax as _minimax  # noqa: E402
FRAME_GRID.update(_minimax.FRAME_GRID)
MODULE_BUILDERS.update(_minimax.BUILDERS)
