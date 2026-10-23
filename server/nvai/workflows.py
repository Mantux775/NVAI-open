"""Workflow-Builder: uebersetzt einfache Parameter in ComfyUI-API-Graphen.

Alle verwendeten Nodes wurden gegen /object_info der lokalen ComfyUI-Installation
geprueft. Ein Builder pro `workflow`-Schluessel aus catalog.py.
"""
from __future__ import annotations

import random
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
    "ace_step":   {"steps": 50, "cfg": 5.0, "sampler": "euler",    "scheduler": "simple"},
    "ace_step_15": {"steps": 12, "cfg": 2.0, "sampler": "euler",   "scheduler": "simple"},
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

# Negativprompts, die ein Workflow einsetzt, wenn keiner angegeben ist. Fuer
# registry.features_for, damit Frontend und Claude es sehen.
DEFAULT_NEGATIVES = {"qwen_image": QWEN_IMAGE_NEGATIVE}


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
        inputs: dict[str, Any] = {"positive": pos, "negative": neg, "vae": ["3", 0],
                                  "resolution": "resize", "resolution.megapixels": 1.0}
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
    Den Prompt-Ausbau der Vorlage (Gemma 4) laesst NV-AI weg -- dafuer gibt es "Prompt ausbauen".
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


def build_image(entry: dict[str, Any], p: dict[str, Any]) -> tuple[Graph, int]:
    wf = entry["workflow"]
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

def build_audio(entry: dict[str, Any], p: dict[str, Any]) -> tuple[Graph, int]:
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

    if wf == "ace_step":
        # ACE-Step trennt Genre-Tags von Songtext; leere Lyrics = instrumental.
        graph = {
            "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": ckpt}},
            "2": {"class_type": "TextEncodeAceStepAudio", "inputs": {
                "clip": ["1", 1], "tags": p["prompt"],
                "lyrics": p.get("lyrics", ""), "lyrics_strength": 1.0,
            }},
            "3": {"class_type": "TextEncodeAceStepAudio", "inputs": {
                "clip": ["1", 1], "tags": p.get("negative_prompt", ""),
                "lyrics": "", "lyrics_strength": 1.0,
            }},
            "4": {"class_type": "EmptyAceStepLatentAudio",
                  "inputs": {"seconds": seconds, "batch_size": 1}},
            "5": {"class_type": "KSampler", "inputs": {
                **common_sampler,
                "model": ["1", 0], "positive": ["2", 0], "negative": ["3", 0],
                "latent_image": ["4", 0],
            }},
            "6": {"class_type": "VAEDecodeAudio", "inputs": {"samples": ["5", 0], "vae": ["1", 2]}},
            "7": {"class_type": "SaveAudioMP3",
                  "inputs": {"audio": ["6", 0], "filename_prefix": "nvai_audio", "quality": "V0"}},
        }
        return graph, seed

    if wf == "ace_step_15":
        enc: dict[str, Any] = {
            "clip": ["1", 1], "tags": p["prompt"], "lyrics": p.get("lyrics", ""),
            "seed": seed, "duration": seconds, "language": p.get("language", "en"),
            # ComfyUI ab 0.41 lehnt den Knoten ohne Tempo, Taktart und Tonart ab
            # ("required_input_missing"); ohne Angabe gelten die Vorgaben des Knotens.
            "bpm": int(p.get("bpm") or 120),
            "timesignature": str(p.get("time_signature") or "4"),
            "keyscale": p.get("key_scale") or "C major",
            "generate_audio_codes": True, "cfg_scale": _pick(p, d, "cfg"),
            "temperature": 0.85, "top_p": 0.9, "top_k": 0, "min_p": 0.0,
        }
        graph = {
            "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": ckpt}},
            "2": {"class_type": "TextEncodeAceStepAudio1.5", "inputs": enc},
            "3": {"class_type": "TextEncodeAceStepAudio1.5", "inputs": {
                **enc, "tags": p.get("negative_prompt", ""), "lyrics": "",
            }},
            "4": {"class_type": "EmptyAceStep1.5LatentAudio",
                  "inputs": {"seconds": seconds, "batch_size": 1}},
            "5": {"class_type": "KSampler", "inputs": {
                **common_sampler,
                "model": ["1", 0], "positive": ["2", 0], "negative": ["3", 0],
                "latent_image": ["4", 0],
            }},
            "6": {"class_type": "VAEDecodeAudio", "inputs": {"samples": ["5", 0], "vae": ["1", 2]}},
            "7": {"class_type": "SaveAudioMP3",
                  "inputs": {"audio": ["6", 0], "filename_prefix": "nvai_audio", "quality": "V0"}},
        }
        return graph, seed

    raise ValueError(t(f"Kein Audio-Builder fuer Workflow '{wf}'",
                       f"No audio builder for workflow '{wf}'"))


# --------------------------------------------------------------- VIDEO

def normalize_frames(frames: int, workflow: str) -> int:
    """Wan und Kandinsky brauchen 4n+1 Frames, LTX 8n+1, Mochi 6n+1."""
    step = 8 if workflow in ("ltxv_t2v", "ltx25", "ltx23") else 6 if workflow == "mochi" else 4
    n = max(1, round((frames - 1) / step))
    return n * step + 1



# Feste Sigmas der destillierten LTX-2.5-Vorlagen: erste Stufe (halbe Aufloesung), zweite
# Stufe nach dem Hochskalieren.
LTX25_SIGMAS_1 = "1.0, 0.99375, 0.9875, 0.98125, 0.975, 0.909375, 0.725, 0.421875, 0.0"
LTX25_SIGMAS_2 = "0.85, 0.7250, 0.4219, 0.0"
LTX25_NEGATIVE = "pc game, console game, video game, cartoon, childish, ugly"


def _build_ltx25(entry, p, seed, width, height, frames, fps, start_image) -> tuple[Graph, int]:
    """LTX-2.5 (Lightricks, 22 Mrd.): Video mit Ton in einem Durchgang.

    Nachgebaut nach ComfyUIs Vorlagen video_ltx2_5_t2v.json und *_i2v.json: Die erste Stufe
    rechnet Bild- und Tonlatent gemeinsam auf halber Aufloesung (8 feste Sigmas), dann skaliert
    LTXVLatentUpsampler das Video auf volle Groesse, und eine zweite Stufe (3 Sigmas) rechnet
    nach. Mit Startbild setzt LTXVImgToVideoInplace es in beiden Stufen als ersten Frame ein
    (Staerke 0,7, dann 1,0). Den Prompt-Ausbau der Vorlage (Gemma 4 E2B) laesst NV-AI weg.
    Ausgabe: MP4 mit Ton (CreateVideo + SaveVideo).
    """
    ids = _Ids(start=40)
    w = max(256, int(width) // 64 * 64)
    h = max(256, int(height) // 64 * 64)
    negative = p.get("negative_prompt") or LTX25_NEGATIVE
    is23 = entry["workflow"] == "ltx23"
    graph: Graph = {
        "5": {"class_type": "LatentUpscaleModelLoader",
              "inputs": {"model_name": _file_by_target(entry, "latent_upscale_models")}},
    }
    if is23:
        # LTX-2.3 (Vorlage video_ltx2_3_*): ein dev-Checkpoint mit Bild- und Ton-VAE, der
        # Text-Encoder Gemma 3 12B laedt seine Projektion aus demselben Checkpoint, die
        # destillierte LoRA mit 0,5 macht daraus die schnelle Fassung.
        ckpt = _file_by_target(entry, "checkpoints")
        graph.update({
            "0": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": ckpt}},
            "1": {"class_type": "LoraLoaderModelOnly", "inputs": {
                "model": ["0", 0], "lora_name": _file_by_target(entry, "loras"), "strength_model": 0.5}},
            "2": {"class_type": "LTXAVTextEncoderLoader", "inputs": {
                "text_encoder": _file_by_target(entry, "text_encoders"), "ckpt_name": ckpt,
                "device": "default"}},
            "4": {"class_type": "LTXVAudioVAELoader", "inputs": {"ckpt_name": ckpt}},
        })
        vae: Ref = ["0", 2]
    else:
        graph.update({
            "1": {"class_type": "UNETLoader", "inputs": {
                "unet_name": _file_by_target(entry, "diffusion_models"), "weight_dtype": "default"}},
            "2": {"class_type": "CLIPLoader", "inputs": {
                "clip_name": _file_by_target(entry, "text_encoders"), "type": "ltxv"}},
            "3": {"class_type": "VAELoader", "inputs": {"vae_name": _file_by_target(entry, "vae", "video")}},
            "4": {"class_type": "VAELoader", "inputs": {"vae_name": _file_by_target(entry, "vae", "audio")}},
        })
        vae = ["3", 0]
    graph.update({
        "6": {"class_type": "CLIPTextEncode", "inputs": {"text": p["prompt"], "clip": ["2", 0]}},
        "7": {"class_type": "CLIPTextEncode", "inputs": {"text": negative, "clip": ["2", 0]}},
        "8": {"class_type": "LTXVConditioning",
              "inputs": {"positive": ["6", 0], "negative": ["7", 0], "frame_rate": fps}},
        "9": {"class_type": "EmptyLTXVLatentVideo", "inputs": {
            "width": w // 2, "height": h // 2, "length": frames, "batch_size": 1}},
        "10": {"class_type": "LTXVEmptyLatentAudio", "inputs": {
            "frames_number": frames, "frame_rate": int(fps), "batch_size": 1, "audio_vae": ["4", 0]}},
    })
    video: Ref = ["9", 0]
    image: Ref | None = None
    if start_image:
        load, scale, pre, inplace = ids(), ids(), ids(), ids()
        graph[load] = {"class_type": "LoadImage", "inputs": {"image": start_image}}
        graph[scale] = {"class_type": "ImageScale", "inputs": {
            "image": [load, 0], "upscale_method": "lanczos", "width": w, "height": h, "crop": "center"}}
        graph[pre] = {"class_type": "LTXVPreprocess", "inputs": {"image": [scale, 0], "img_compression": 18}}
        image = [pre, 0]
        graph[inplace] = {"class_type": "LTXVImgToVideoInplace", "inputs": {
            "vae": vae, "image": image, "latent": video, "strength": 0.7, "bypass": False}}
        video = [inplace, 0]

    def stage(av: Ref, sigmas: str, noise_seed: int) -> Ref:
        noise, sel, sig, guide, samp = ids(), ids(), ids(), ids(), ids()
        graph[noise] = {"class_type": "RandomNoise", "inputs": {"noise_seed": noise_seed}}
        graph[sel] = {"class_type": "KSamplerSelect", "inputs": {
            "sampler_name": "euler" if is23 else "euler_ancestral"}}
        graph[sig] = {"class_type": "ManualSigmas", "inputs": {"sigmas": sigmas}}
        if is23:
            graph[guide] = {"class_type": "CFGGuider", "inputs": {
                "model": ["1", 0], "positive": ["8", 0], "negative": ["8", 1], "cfg": 1.0}}
        else:
            graph[guide] = {"class_type": "LTXVDualCFGGuider", "inputs": {
                "model": ["1", 0], "positive": ["8", 0], "negative": ["8", 1],
                "video_cfg": 1.0, "audio_cfg": 1.0}}
        graph[samp] = {"class_type": "SamplerCustomAdvanced", "inputs": {
            "noise": [noise, 0], "guider": [guide, 0], "sampler": [sel, 0], "sigmas": [sig, 0],
            "latent_image": av}}
        sep = ids()
        graph[sep] = {"class_type": "LTXVSeparateAVLatent", "inputs": {"av_latent": [samp, 0]}}
        return sep

    cat1 = ids()
    graph[cat1] = {"class_type": "LTXVConcatAVLatent", "inputs": {"video_latent": video, "audio_latent": ["10", 0]}}
    sep1 = stage([cat1, 0], LTX25_SIGMAS_1, seed)
    up = ids()
    graph[up] = {"class_type": "LTXVLatentUpsampler", "inputs": {
        "samples": [sep1, 0], "upscale_model": ["5", 0], "vae": vae}}
    video2: Ref = [up, 0]
    if image is not None:
        inplace2 = ids()
        graph[inplace2] = {"class_type": "LTXVImgToVideoInplace", "inputs": {
            "vae": vae, "image": image, "latent": video2, "strength": 1.0, "bypass": False}}
        video2 = [inplace2, 0]
    cat2 = ids()
    graph[cat2] = {"class_type": "LTXVConcatAVLatent", "inputs": {"video_latent": video2, "audio_latent": [sep1, 1]}}
    sep2 = stage([cat2, 0], LTX25_SIGMAS_2, seed + 1)
    dec, aud, vid, save = ids(), ids(), ids(), ids()
    graph[dec] = {"class_type": "VAEDecodeTiled", "inputs": {
        "samples": [sep2, 0], "vae": vae, "tile_size": 512, "overlap": 64,
        "temporal_size": 64, "temporal_overlap": 16}}
    graph[aud] = {"class_type": "LTXVAudioVAEDecode", "inputs": {"samples": [sep2, 1], "audio_vae": ["4", 0]}}
    graph[vid] = {"class_type": "CreateVideo", "inputs": {"images": [dec, 0], "fps": fps, "audio": [aud, 0]}}
    graph[save] = {"class_type": "SaveVideo", "inputs": {
        "video": [vid, 0], "filename_prefix": "nvai_video", "format": "mp4", "format.codec": "h264"}}
    return graph, seed


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
        # Die Vorlagen lassen den Negativprompt leer; NV-AI nimmt nur einen eigenen.
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
        return _build_ltx25(entry, p, seed, width, height, frames, fps, start_image)

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


# ------------------------------------------------------------- Dispatch

FLUX3_WORKFLOWS = {"flux3_klein", "flux3_klein_base"}
BOOGU_WORKFLOWS = {"boogu", "boogu_turbo"}
HIDREAM_O1_WORKFLOWS = {"hidream_o1", "hidream_o1_dev"}
IMAGE_WORKFLOWS = ({"sdxl", "flux", "flux-dev", "sd3", "chroma", "longcat", "zimage",
                    "qwen_image", "qwen_image_lightning", "qwen_image21"}
                   | FLUX3_WORKFLOWS | BOOGU_WORKFLOWS | HIDREAM_O1_WORKFLOWS)
AUDIO_WORKFLOWS = {"stable_audio", "ace_step", "ace_step_15"}
VIDEO_WORKFLOWS = {"wan_t2v", "wan22_ti2v", "wan_i2v", "wan22_i2v",
                   "hunyuan15_t2v", "hunyuan15_i2v", "ltxv_t2v", "ltx25", "ltx23",
                   "kandinsky5_t2v", "kandinsky5_t2v_distilled", "kandinsky5_i2v", "mochi"}

# Diese laufen NICHT ueber ComfyUI, sondern in eigenen Worker-Prozessen
# (siehe nvai/mesh_workers.py). Sie haben deshalb hier bewusst keinen Graph-Builder.
EXTERNAL_WORKFLOWS = {"triposg", "trellis2"}


def build(entry: dict[str, Any], p: dict[str, Any]) -> tuple[Graph, int]:
    wf = entry.get("workflow")
    if wf in IMAGE_WORKFLOWS:
        return build_image(entry, p)
    if wf in AUDIO_WORKFLOWS:
        return build_audio(entry, p)
    if wf in VIDEO_WORKFLOWS:
        return build_video(entry, p)
    if wf in EXTERNAL_WORKFLOWS:
        raise ValueError(t(
            f"'{entry['id']}' laeuft in einem eigenen Worker, nicht in ComfyUI "
            f"-- siehe jobs.py, Handler 'img23d'.",
            f"'{entry['id']}' runs in its own worker, not in ComfyUI "
            f"-- see jobs.py, handler 'img23d'.",
        ))
    raise ValueError(t(
        f"Fuer '{entry['id']}' gibt es noch keinen Workflow-Builder (workflow={wf})",
        f"There is no workflow builder for '{entry['id']}' yet (workflow={wf})",
    ))
