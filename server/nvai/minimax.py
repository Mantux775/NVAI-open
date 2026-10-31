"""MiniMax H3 (seit 0.5.18): Video mit Stereoton, Startbild- (FL2VA) und Referenz-Fassung (Ref2VA), FastH3 und die
Turbo-LoRAs von lightx2v. catalog.py, catalog_en.py, workflows.py und loras.py holen Eintraege, Builder und LoRA-Basen
von hier.

Die MiniMax H3 Community License schliesst die EU, Grossbritannien, Suedkorea und die USA aus, auch private Nutzung und
die erzeugten Videos (Abschnitt I.3, I.5, V.4). Deshalb tragen alle Eintraege eine rote Lizenzmarke (license_badge),
jedes Ergebnis "Nicht veröffentlichen" (output_badge), und die Warnung steht, bis der Nutzer unter "Modelle" eine eigene
Genehmigung bestaetigt (registry.set_license). Graph nach ComfyUIs Vorlage video_minimax_h3_t2v (Unterprogramm "Image
to Video (MiniMax H3)"), Knoten aus comfy_extras/nodes_minimax_h3.py (ComfyUI 0.42.1).
"""
from __future__ import annotations

from typing import Any

from . import config
from .i18n import t

REPO = "Comfy-Org/MiniMax-H3"
WORKFLOW = "minimax_h3"
MODEL_ID = "minimax-h3-fl2va-int8"
# Die offenen Gewichte rechnen mit 24 fps; der Ton entsteht fuer genau diese Laenge.
FPS = 24
# MiniMaxH3ImageToVideo: 17k+5 Bilder, trainiert auf rund 124 bis 362 (5 bis 15 s bei 24 fps).
FRAME_STEP, FRAME_REST = 17, 5
DEFAULT_FRAMES, MAX_FRAMES = 124, 362
# Vorlage: res_multistep, simple, 20 Schritte ohne CFG (das Modell ist CFG-destilliert); mit der Turbo-LoRA 8.
STEPS, TURBO_STEPS = 20, 8
TURBO = "turbo"
# sol-attn (Model Sparse Attention): ComfyUIs Vorgaben fuer tau und den Beginn (Anteil der Schritte)
SOL_TAU, SOL_START = 1.3, 0.2
# Veda (Knotenpaket Veda-on-ComfyUI, MIT; Praediktor Veda-Sparse/Minimax-H3-T2VA-Veda-8NFE-600Step-Preview, MiniMax-Lizenz)
# in models/veda; Budget = Kacheln zu 128 Token je Abfrage-Kachel (Vorgabe des Knotens)
VEDA_PREDICTOR = "minimax_h3_t2va_veda_8nfe_600step_preview_fp8.safetensors"
# Fuer Ref2VA der eigene Praediktor (Veda-Sparse/Minimax-H3-R2VA-Veda-Preview): vom T2VA-Praediktor 600 Schritte auf
# 5,17-s-R2VA-Clips mit der Turbo-LoRA (8 Schritte) weitertrainiert, je 32 Referenz- und Video-Kacheln
VEDA_PREDICTOR_REF = "minimax_h3_r2va_veda_preview_fp8.safetensors"
VEDA_BUDGET = "32"
# Veda richtet NVAI-open nicht ein (Knotenpaket, triton-windows und Praediktoren von Hand): angeboten wird es nur, wenn
# das Knotenpaket in ComfyUIs custom_nodes liegt.
SPARSE_METHODS = ["sol-attn"] + (["veda"] if (config.COMFY_ROOT / "custom_nodes" / "Veda-on-ComfyUI").is_dir() else [])
# Kleinste NVIDIA-Architektur je Beschleuniger (comfy-kitchen 0.2.39: sol_attn "requires sm_80+", die INT8-Attention
# "SM75 or newer"; Veda rechnet mit Triton-INT8, ebenfalls ab 8.0). registry.features_for nimmt sie auf anderen Karten
# (und auf AMD) aus Auswahl und Empfehlung.
MIN_COMPUTE = {"sol-attn": 8.0, "veda": 8.0, "int8_attention": 7.5}

SIZES = [
    {"label": "864 × 480 — 16:9, am schnellsten (fremd gemessen: 5 s in rund 10,5 min)", "w": 864, "h": 480},
    {"label": "960 × 544 — 16:9 (fremd gemessen: 5 s in rund 13,5 min)", "w": 960, "h": 544},
    {"label": "1344 × 768 — 16:9, natives 768p, am langsamsten (nicht gemessen)", "w": 1344, "h": 768},
    {"label": "480 × 864 — 9:16, hochkant, am schnellsten", "w": 480, "h": 864},
    {"label": "768 × 1344 — 9:16, hochkant, natives 768p (nicht gemessen)", "w": 768, "h": 1344},
]
SIZE_LABELS = {
    SIZES[0]["label"]: "864 × 480 — 16:9, fastest (measured by others: 5 s in about 10.5 min)",
    SIZES[1]["label"]: "960 × 544 — 16:9 (measured by others: 5 s in about 13.5 min)",
    SIZES[2]["label"]: "1344 × 768 — 16:9, native 768p, slowest (not measured)",
    SIZES[3]["label"]: "480 × 864 — 9:16, portrait, fastest",
    SIZES[4]["label"]: "768 × 1344 — 9:16, portrait, native 768p (not measured)",
}

# Lizenz I.3/I.5 und V.4 sichtbar machen; das Antragsformular gilt laut MiniMax' Modellkarte "only for USA/EU/UK/South
# Korea". Die Warnung verschwindet erst, wenn der Nutzer unter "Modelle" eine eigene Genehmigung bestaetigt.
WARNING = ("Ohne eigene Lizenz von MiniMax in der EU, in Großbritannien, Südkorea und den USA nicht erlaubt: Die "
           "MiniMax H3 Community License (Abschnitt V.4) verbietet dort jede Nutzung, auch privat, und das gilt auch "
           "für alles damit Erzeugte. Videos und Bilder daraus dürfen nicht veröffentlicht werden, auch keine "
           "Standbilder oder Screenshots. Lizenzanfrage: platform.minimax.io/h3-license. Wer eine Genehmigung hat, "
           "setzt unter „Modelle“ den Haken.")
WARNING_EN = ("Not allowed in the EU, the UK, South Korea or the USA without a separate license from MiniMax: the "
              "MiniMax H3 Community License (section V.4) prohibits any use there, private use included, and that "
              "covers everything made with it. Videos and images from it must not be published, stills and "
              "screenshots included. License request: platform.minimax.io/h3-license. With a permission of your own, "
              "tick the box under “Models”.")
# Rote Marken (schemas.ModelInfo): am Modell und an jedem Ergebnis im Verlauf und im Studio.
LICENSE_BADGE = "In EU, UK, Südkorea und USA nicht erlaubt"
LICENSE_BADGE_EN = "Not allowed in the EU, UK, South Korea or USA"
OUTPUT_BADGE, OUTPUT_BADGE_EN = "Nicht veröffentlichen", "Do not publish"
# MiniMax neigt zu Zeitlupe: Die Dateien haben 24 fps, die Zeitlupe kommt aus dem Modell (gemessen: bei einer Explosion
# halb so viel Bildaenderung wie LTX-2.5; Tempo im Prompt hob die Spitze um 30-55 %, FastH3 bewegt sich fast wie LTX).
# Rat aus der lightx2v-Community (Hugging Face, Minimax-h3-Turbo, Diskussion #58): Bewegung mit Tempo beschreiben; die
# Referenz-Turbo-LoRAs machen die Bewegung steifer. Steht im Prompt-Hinweis und unter dem Modell.
TEMPO_HINT = (" MiniMax rechnet fest mit 24 fps (flüssig wie im Kino), neigt aber zu Zeitlupe: jede Bewegung mit Tempo "
              "beschreiben („streaks down fast“, „bursts in a split second“, „a quick, energetic …“, „at full real-time "
              "speed“), Wörter wie „slowly“ meiden. Turbo-LoRAs und die Referenz-Fassung bewegen sich etwas steifer.")
TEMPO_HINT_EN = (" MiniMax runs at a fixed 24 fps (smooth like cinema) but tends to slow motion: describe every movement "
                 "with its pace (\"streaks down fast\", \"bursts in a split second\", \"a quick, energetic …\", \"at full "
                 "real-time speed\") and avoid words like \"slowly\". Turbo LoRAs and the reference version move a bit "
                 "more stiffly.")
TEMPO_NOTE = " · neigt zu Zeitlupe: Tempo im Prompt beschreiben"
TEMPO_NOTE_EN = " · tends to slow motion: describe the pace in the prompt"

FEATURES: dict[str, Any] = {
    "start_image": "optional",
    "fps": FPS, "max_seconds": 15,
    "default_frames": DEFAULT_FRAMES, "min_frames": FRAME_REST, "max_frames": MAX_FRAMES,
    "frame_step": FRAME_STEP, "frame_rule": "17k+5",
    "sparse_attention": SPARSE_METHODS, "int8_attention": True, "min_compute": MIN_COMPUTE,
    "sizes": SIZES,
    "prompt_hint": (
        "Ein Block in ganzen englischen Sätzen: zuerst Stil und Look, dann die Szene; mehrere Einstellungen als "
        "Zeitleiste („[0s-2s] Shot 1: …“) mit der Kamera; zuletzt der Ton: Dialog in Anführungszeichen mit "
        "Sprecher, Geräusche, Musik. Mit Startbild beschreiben, was ab dem Bild geschieht. 8 Schritte nehmen die "
        "Turbo-LoRA (schneller), sonst 20." + TEMPO_HINT),
    "placeholder": (
        "Cinematic live-action look, overcast morning light. A fisherman in a yellow raincoat hauls a wet net into "
        "a small wooden boat while gulls circle above. [0s-3s] Medium shot from the side, the camera slowly pushes "
        "in. [3s-5s] Close-up of his hands pulling the net over the gunwale. Audio: waves slapping the hull, crying "
        "gulls, gusting wind, the creak of the boat."),
}

# Ref2VA: eigene Gewichte (minimax_h3_ref2va_*), bis zu 9 Referenzbilder; im Prompt <Picture 1>, <Picture 2> … in der
# Reihenfolge der Bilder (Vorlage video_minimax_h3_r2v). Laut Vorlage traegt "beta" bei Referenzen besser als "simple";
# "max" laesst die Referenzen bis 2048 px kurze Seite (staerkere Identitaet), "match" verkleinert sie aufs Videoformat.
MODEL_ID_REF = "minimax-h3-ref2va-int8"
WORKFLOW_REF = "minimax_h3_ref2va"
REF_LIMIT = 9
REF_SCHEDULER = "beta"
REF_IMAGE_SIZE = "max"
# FastH3 (FastVideo, DMD2-destilliert, nur T2V/FL2VA): eigener Checkpoint mit festen 8 Schritten
MODEL_ID_FAST = "minimax-h3-fasth3-8step-int8"
WORKFLOW_FAST = "minimax_h3_fast"
FASTH3_REPO = "FastVideo/FastVideo-FastH3-Comfy"

# Gemessene Zeiten (RTX 5060 Ti 16 GB, dieselbe Szene mit Seed 42): je Modell und Turbo-LoRA eine kurze Zeile unter dem
# Namen (features.tested). Erzeugt aus der Messreihe, deren Tabelle in docs/de/MODELLE.md steht; nicht von Hand aendern.
# <messreihe>
TESTED: dict[str, str] = {
    MODEL_ID: "Gemessen (9,4 s in 1344 × 576): 20 Schritte 37,3 · Turbo 8 15,8 · + INT8 8,0 · + sol-attn 8,2 · + sol-attn + INT8 6,9 · + Veda 6,1 · Turbo 4 + sol-attn 4,5 min",
    MODEL_ID_REF: "Gemessen (9,4 s in 1344 × 576): 20 Schritte 37,1 · Turbo 8 16,8 · + INT8 8,3 · + sol-attn 8,3 · + sol-attn + INT8 6,6 · + Veda 6,7 · Turbo 4 + sol-attn 4,8 min",
    MODEL_ID_FAST: "Gemessen (9,4 s in 1344 × 576): 8 Schritte fest 7,9 min",
    "minimax-h3-turbo-fl2v-8step-v1.0": "Gemessen (9,4 s in 1344 × 576): 15,8 min statt 37,3 ohne LoRA",
    "minimax-h3-turbo-ref2v-8step-v1.1-768p": "Gemessen (9,4 s in 1344 × 576): 16,8 min statt 37,1 ohne LoRA, mit sol-attn 8,3 min",
    "minimax-h3-turbo-fl2v-8step-v1.1-768p": "Gemessen (9,4 s in 1344 × 576): 15,8 min statt 37,3 ohne LoRA, mit sol-attn 8,2 min",
    "minimax-h3-turbo-ref2v-4step-v1.0-768p": "Gemessen (9,4 s in 1344 × 576): 8,5 min statt 37,1 ohne LoRA, mit sol-attn 4,8 min",
    "minimax-h3-turbo-fl2v-4step-v1.2-768p": "Gemessen (9,4 s in 1344 × 576): 8,7 min statt 37,3 ohne LoRA, mit sol-attn 4,5 min",
    "minimax-h3-turbo-ref2v-8step-v1.0-768p": "Gemessen (9,4 s in 1344 × 576): 15,7 min statt 37,1 ohne LoRA",
}
TESTED_EN: dict[str, str] = {
    MODEL_ID: "Measured (9.4 s at 1344 × 576): 20 steps 37.3 · turbo 8 15.8 · + INT8 8.0 · + sol-attn 8.2 · + sol-attn + INT8 6.9 · + Veda 6.1 · turbo 4 + sol-attn 4.5 min",
    MODEL_ID_REF: "Measured (9.4 s at 1344 × 576): 20 steps 37.1 · turbo 8 16.8 · + INT8 8.3 · + sol-attn 8.3 · + sol-attn + INT8 6.6 · + Veda 6.7 · turbo 4 + sol-attn 4.8 min",
    MODEL_ID_FAST: "Measured (9.4 s at 1344 × 576): 8 fixed steps 7.9 min",
    "minimax-h3-turbo-fl2v-8step-v1.0": "Measured (9.4 s at 1344 × 576): 15.8 min instead of 37.3 without a LoRA",
    "minimax-h3-turbo-ref2v-8step-v1.1-768p": "Measured (9.4 s at 1344 × 576): 16.8 min instead of 37.1 without a LoRA, with sol-attn 8.3 min",
    "minimax-h3-turbo-fl2v-8step-v1.1-768p": "Measured (9.4 s at 1344 × 576): 15.8 min instead of 37.3 without a LoRA, with sol-attn 8.2 min",
    "minimax-h3-turbo-ref2v-4step-v1.0-768p": "Measured (9.4 s at 1344 × 576): 8.5 min instead of 37.1 without a LoRA, with sol-attn 4.8 min",
    "minimax-h3-turbo-fl2v-4step-v1.2-768p": "Measured (9.4 s at 1344 × 576): 8.7 min instead of 37.3 without a LoRA, with sol-attn 4.5 min",
    "minimax-h3-turbo-ref2v-8step-v1.0-768p": "Measured (9.4 s at 1344 × 576): 15.7 min instead of 37.1 without a LoRA",
}
# </messreihe>
FEATURES["tested"] = TESTED.get(MODEL_ID, "")
# Vorgewaehlt (features.recommended): der schnellste gemessene Weg ohne Bildsprung, Turbo 8 v1.1 + sol-attn +
# INT8-Attention (Startbild 6,9, Referenz 6,6 statt 37 min; Veda sprang in 1344 × 576 gegen Ende). Die Generieren-Seite
# setzt es beim Wechsel aufs Modell, Studio und MCP bekommen es vom Server (GenerateVideoRequest.recommended), solange
# der Auftrag nichts anderes sagt. Fehlt die LoRA, gelten nur die beiden Attention-Schalter.
TURBO_FL2V = "minimax-h3-turbo-fl2v-8step-v1.1-768p"
TURBO_REF2V = "minimax-h3-turbo-ref2v-8step-v1.1-768p"
FEATURES["recommended"] = {"loras": [{"model_id": TURBO_FL2V, "strength": 1.0}],
                           "sparse_attention": "sol-attn", "int8_attention": True}

FEATURES_REF: dict[str, Any] = {
    "tested": TESTED.get(MODEL_ID_REF, ""),
    "recommended": {"loras": [{"model_id": TURBO_REF2V, "strength": 1.0}],
                    "sparse_attention": "sol-attn", "int8_attention": True},
    "references": REF_LIMIT,
    "fps": FPS, "max_seconds": 15,
    "default_frames": DEFAULT_FRAMES, "min_frames": FRAME_REST, "max_frames": MAX_FRAMES,
    "frame_step": FRAME_STEP, "frame_rule": "17k+5",
    "sparse_attention": SPARSE_METHODS, "int8_attention": True, "min_compute": MIN_COMPUTE,
    "sizes": SIZES,
    "prompt_hint": (
        "Referenzen im Prompt als <Picture 1>, <Picture 2> … in der Reihenfolge der Bilder ansprechen und sagen, was "
        "jede vorgibt („the man from <Picture 1>, with exactly his face“); dann Szene, Handlung, Kamera und Ton wie "
        "bei FL2VA. Kein Startbild: die ganze Szene entsteht aus dem Text. Laut Vorlage reagiert diese Fassung stark "
        "auf die Wortwahl." + TEMPO_HINT),
    "placeholder": (
        "Realistic live-action cinematic look. The man from <Picture 1>, with exactly his face, sits at a wooden "
        "table in a dim tavern and lifts a tin mug. Medium shot, the camera slowly pushes in. Audio: low chatter, "
        "the clink of the mug, a crackling fire."),
}

# FastH3: wie FL2VA, aber Schritte, Shift, Sampler und Sparse Attention fest nach ComfyUIs Doku zu FastVideo FastH3
# ("Steps are fixed at 8", MiniMaxH3SigmaShift 10/3, res_multistep/simple, BlockSparseAttention VSA keep 10 ab 20 %).
# Keine LoRAs (kein Eintrag in LORA_BASES), keine andere Sparse Attention; INT8-Attention ungemessen, also nicht
# vorgewaehlt.
FEATURES_FAST: dict[str, Any] = {
    **FEATURES,
    "distilled": {"steps": 8, "fixed": True, "shift": [10.0, 3.0], "sampler": "res_multistep", "scheduler": "simple",
                  "sparse": "vsa", "keep_percent": 10.0},
    "sparse_attention": [],
    "recommended": {},
    "tested": TESTED.get(MODEL_ID_FAST, ""),
    "prompt_hint": (
        "Wie bei der Startbild-Fassung: ein Block in ganzen englischen Sätzen, Szene, Zeitleiste mit Kamera, zuletzt der "
        "Ton. Die Schritte stehen fest auf 8 (der Checkpoint ist darauf destilliert)." + TEMPO_HINT),
}

# Turbo-LoRAs (lightx2v, ModelTC/Minimax-H3-Turbo; v1.1 seit 20.10.2026). Zu jeder gehoeren Schritte, Shift (Video/Ton)
# und Sampler (euler, simple, BasicGuider wie in deren ComfyUI-Workflows). Shift laut lightx2v-Release-Notizen auf
# Hugging Face: Startbild-LoRAs in 768p Video 6 ("This recommendation applies to FL2V, not REF2V", 20.10.), die
# 8-Schritt-v1.0 auf 544p 12; Referenz-LoRAs 12 (8-Schritt-v1.0 768p vom 3.9.: "Video shift: 12"); Ton immer 3. 12/3 ist
# auch ComfyUIs Vorgabe fuer H3. Fuer Ref2VA empfiehlt lightx2v ref_image_size "match" wie im Training. Die Builder lesen
# das aus features.turbo der gewaehlten LoRA (loras=[...] am Auftrag); ohne Angabe von steps nimmt der Auftrag die
# Schritte der LoRA.
TURBO_REPO = "lightx2v/Minimax-h3-Turbo"
LORA_FL2VA, LORA_REF2VA = "minimax_h3_fl2va", "minimax_h3_ref2va"
FAMILY_REF = "minimax_h3_ref2va"  # eigene Modellfamilie, damit die Generieren-Seite nur passende LoRAs empfiehlt
# loras.WORKFLOW_BASES / loras.BASES: welche LoRA-Basis zu welchem Graphen passt
LORA_BASES = {WORKFLOW: (LORA_FL2VA,), WORKFLOW_REF: (LORA_REF2VA,)}
LORA_LABELS = {LORA_FL2VA: "MiniMax H3 FL2VA", LORA_REF2VA: "MiniMax H3 Ref2VA"}


def _turbo_lora(lid: str, repo: str, file: str, family: str, turbo: dict[str, Any], name: str, best_for: str,
                description: str) -> dict[str, Any]:
    return {
        "id": lid, "name": name, "kind": "lora", "family": family, "workflow": None,
        "files": [{"repo": repo, "file": file, "target": "loras"}],
        "size_gb": 1.83, "vram_gb": 0, "trigger": "", "source_url": f"https://huggingface.co/{repo}",
        "license": "MiniMax H3 Community License", "commercial_ok": False,
        "warning": WARNING, "license_badge": LICENSE_BADGE,
        "best_for": best_for, "description": description,
        "pros": [f"{turbo['steps']} statt {STEPS} Schritte"],
        "cons": ["Laut ComfyUI etwas weichere Bewegung und schwächerer Ton als mit 20 Schritten"],
        "features": {"strength": 1.0, "recommended_for": ["minimax_h3" if family == LORA_FL2VA else FAMILY_REF],
                     "turbo": turbo, "tested": TESTED.get(lid, "")},
    }


TURBO_LORAS: list[dict[str, Any]] = [
    _turbo_lora(
        "minimax-h3-turbo-fl2v-8step-v1.1-768p", TURBO_REPO,
        "minimax_h3_fl2v_turbo_8step_v1.1_768p_comfyui_bf16.safetensors", LORA_FL2VA,
        {"steps": 8, "shift": [6.0, 3.0], "sampler": "euler", "scheduler": "simple"},
        "MiniMax H3 Turbo 8 Schritte v1.1 768p (Startbild, lightx2v)",
        "Schneller: 8 statt 20 Schritte für die Startbild-Fassung, trainiert auf 768p",
        "Turbo-LoRA von lightx2v (20.10.2026) für die FL2VA-Fassung: 8 Schritte bis 768p, Shift 6 (Video) / 3 (Ton), "
        "wie lightx2v es für die neuen Startbild-LoRAs empfiehlt. NVAI-open setzt Shift, Sampler euler und Scheduler "
        "simple selbst. Die 768p-Fassung (dort v1.0) nutzt lightx2v in seinem eigenen Online-Studio."),
    _turbo_lora(
        "minimax-h3-turbo-ref2v-8step-v1.1-768p", TURBO_REPO,
        "minimax_h3_ref2v_turbo_8step_v1.1_768p_comfyui_bf16.safetensors", LORA_REF2VA,
        {"steps": 8, "shift": [12.0, 3.0], "sampler": "euler", "scheduler": "simple", "ref_image_size": "match"},
        "MiniMax H3 Turbo 8 Schritte v1.1 768p (Referenz, lightx2v)",
        "Schneller: 8 statt 20 Schritte für die Referenz-Fassung, trainiert auf 768p",
        "Turbo-LoRA von lightx2v (20.10.2026) für die Ref2VA-Fassung: 8 Schritte bis 768p, Shift 12 (Video) / 3 (Ton) "
        "wie alle Referenz-LoRAs von lightx2v, Referenzen in der Größe „match“. NVAI-open setzt Shift, euler, simple "
        "und „match“ selbst. Laut ComfyUI schwächen Turbo-LoRAs die Referenzen; soll ein Gesicht sicher halten, 20 bis "
        "25 Schritte ohne LoRA."),
    _turbo_lora(
        "minimax-h3-turbo-fl2v-4step-v1.2-768p", TURBO_REPO,
        "minimax_h3_fl2v_turbo_4step_v1.2_768p_comfyui_bf16.safetensors", LORA_FL2VA,
        {"steps": 4, "shift": [6.0, 3.0], "sampler": "euler", "scheduler": "simple"},
        "MiniMax H3 Turbo 4 Schritte v1.2 768p (Startbild, lightx2v)",
        "Am schnellsten: 4 statt 20 Schritte für die Startbild-Fassung, bis 768p, saubererer Ton",
        "Turbo-LoRA von lightx2v (4.9.2026) für die FL2VA-Fassung: 4 Schritte bis 768p, Shift 6 (Video) / 3 (Ton), "
        "euler, laut lightx2v mit saubererem Ton als v1.1. Ein Nutzer fand das Bild dort schlechter als bei v1.1; die "
        "neuere v1.3 soll mit Sparse Attention schlechter laufen als v1.2."),
    _turbo_lora(
        "minimax-h3-turbo-ref2v-8step-v1.0-768p", TURBO_REPO,
        "minimax_h3_ref2v_turbo_8step_v1.0_768p_comfyui_bf16.safetensors", LORA_REF2VA,
        {"steps": 8, "shift": [12.0, 3.0], "sampler": "euler", "scheduler": "simple", "ref_image_size": "match"},
        "MiniMax H3 Turbo 8 Schritte v1.0 768p (Referenz, lightx2v)",
        "Schneller: 8 statt 20 Schritte für die Referenz-Fassung, die Vorgängerin von v1.1",
        "Turbo-LoRA von lightx2v (3.9.2026) für die Ref2VA-Fassung: 8 Schritte bis 768p, Shift 12 (Video) / 3 (Ton), "
        "euler, Referenzen in der Größe „match“ (Release-Notiz). Ein Nutzer fand sie bei lightx2v besser als v1.1 "
        "(Sprache und Prompt-Treue)."),
    _turbo_lora(
        "minimax-h3-turbo-ref2v-4step-v1.0-768p", TURBO_REPO,
        "minimax_h3_ref2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors", LORA_REF2VA,
        {"steps": 4, "shift": [12.0, 3.0], "sampler": "euler", "scheduler": "simple", "ref_image_size": "match"},
        "MiniMax H3 Turbo 4 Schritte v1.0 768p (Referenz, lightx2v)",
        "Am schnellsten: 4 statt 20 Schritte für die Referenz-Fassung, bis 768p",
        "Turbo-LoRA von lightx2v (20.10.2026) für die Ref2VA-Fassung: 4 Schritte bis 768p, Shift 12 / 3 wie alle "
        "Referenz-LoRAs von lightx2v, Referenzen in der Größe „match“. Laut ComfyUI geht Turbo bei Referenzen auf Kosten "
        "von Gesicht und Ton; ein Nutzer meldete bei lightx2v unscharfe, zitternde Bilder mit dieser Fassung."),
    _turbo_lora(
        "minimax-h3-turbo-fl2v-8step-v1.0", "Comfy-Org/MiniMax-H3",
        "loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors", LORA_FL2VA,
        {"steps": 8, "shift": [12.0, 3.0], "sampler": "euler", "scheduler": "simple"},
        "MiniMax H3 Turbo 8 Schritte v1.0 (Startbild, lightx2v)",
        "Schneller: 8 statt 20 Schritte für die Startbild-Fassung, trainiert auf 544p",
        "Die Turbo-LoRA aus ComfyUIs Vorlage (lightx2v v1.0): 8 Schritte (laut lightx2v auch 4), trainiert auf 544p mit "
        "Shift 12 / 3. Als LoRA gewählt rechnet NVAI-open wie lightx2v mit euler; nur mit steps ≤ 8 ohne LoRA-Wahl "
        "nimmt die Startbild-Fassung dieselbe Datei wie ComfyUIs Vorlage (res_multistep)."),
]

MODELS: list[dict[str, Any]] = [
    {
        "id": MODEL_ID,
        "name": "MiniMax H3 (INT8, mit Ton)",
        "kind": "video",
        "family": "minimax_h3",
        "workflow": WORKFLOW,
        "files": [
            {"repo": REPO, "file": "diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors",
             "target": "diffusion_models"},
            {"repo": REPO, "file": "text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors",
             "target": "text_encoders"},
            {"repo": REPO, "file": "vae/minimax_h3_video_vae_int8_convrot.safetensors", "target": "vae"},
            {"repo": REPO, "file": "vae/minimax_h3_audio_vae_fp32.safetensors", "target": "vae"},
            # 8 statt 20 Schritte (lightx2v, in Comfy-Orgs Paket); fehlt sie, rechnet das Modell mit 20.
            {"repo": REPO, "file": "loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors",
             "target": "loras", "optional": TURBO},
        ],
        "size_gb": 39.14,
        "model_gb": 19.53,
        "vram_gb": 14,
        "license": "MiniMax H3 Community License",
        "commercial_ok": False,
        "warning": WARNING,
        "license_badge": LICENSE_BADGE,
        "output_badge": OUTPUT_BADGE,
        "best_for": "Video mit Stereoton aus Text oder Startbild, 5 bis 15 s, folgt der Beschreibung genau" + TEMPO_NOTE,
        "description": (
            "MiniMax, Juli 2026. Ein Transformer erzeugt Bild und Stereoton (32 kHz) in einem Durchgang: Stimmen, "
            "Geräusche und Musik. Das volle Modell hat 33 Mrd. Parameter; eingebaut ist die beschnittene Fassung "
            "(pruned, laut Dateigröße rund 20 Mrd.) in INT8. Text-Encoder ist Qwen3-VL-32B (NVFP4). Die offenen "
            "Gewichte rechnen bis 768p (kurze Seite), 5 bis 15 s, 24 fps; 2K gibt es nur über MiniMax' API. Diese "
            "Fassung (FL2VA) nimmt Text und auf Wunsch ein Startbild.\n\n"
            "Graph nach ComfyUIs Vorlage video_minimax_h3_t2v: 20 Schritte res_multistep ohne CFG, mit der "
            "Turbo-LoRA 8 Schritte (steps=8). Länge auf dem Raster 17k+5 Bilder (124 = 5,2 s).\n\n"
            "Gemessen auf einer RTX 5060 Ti 16 GB: 9,4 s in 1344 × 576 mit 20 Schritten in 37 min, rund 107 s "
            "je Schritt, Grafikspeicher 14,9 GB, freier Arbeitsspeicher nie unter 31,8 GB (von 64). LTX-2.5 brauchte "
            "für dieselbe Szene in 1920 × 832 rund 7 min. Im Test folgte MiniMax der Beschreibung genauer als "
            "LTX-2.5. Fremd gemessen: 5 s in 864 × 480 rund 633 s, in 960 × 544 rund 809 s. Berichte: Gesichter "
            "zerfallen in weiten Einstellungen; nach jeder Prompt-Änderung lädt ComfyUI das Modell neu von der Platte."
        ),
        "pros": ["Video mit Stereoton (Stimmen, Geräusche, Musik) in einem Durchgang",
                 "5 bis 15 s am Stück, 24 fps", "Startbild als erstes Bild",
                 "Folgte im Test der Beschreibung genauer als LTX-2.5",
                 "Turbo-LoRA: 8 statt 20 Schritte"],
        "cons": ["Lizenz: ohne eigene Lizenz von MiniMax in der EU, Großbritannien, Südkorea und den USA verboten, "
                 "auch privat; Ergebnisse nicht veröffentlichen",
                 "Rund 39 GB Download",
                 "Langsam: 37 min für 9,4 s in 1344 × 576 (LTX-2.5: rund 7 min in 1920 × 832)",
                 "Höchstens 768p",
                 "Gesichter zerfallen in weiten Einstellungen (Bericht)"],
        "features": FEATURES,
    },
    {
        "id": MODEL_ID_REF,
        "name": "MiniMax H3 Referenz (INT8, mit Ton)",
        "kind": "video",
        "family": FAMILY_REF,
        "workflow": WORKFLOW_REF,
        "files": [
            {"repo": REPO, "file": "diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors",
             "target": "diffusion_models"},
            # Text-Encoder und VAEs teilt sie mit der FL2VA-Fassung.
            {"repo": REPO, "file": "text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors",
             "target": "text_encoders"},
            {"repo": REPO, "file": "vae/minimax_h3_video_vae_int8_convrot.safetensors", "target": "vae"},
            {"repo": REPO, "file": "vae/minimax_h3_audio_vae_fp32.safetensors", "target": "vae"},
        ],
        "size_gb": 37.32,
        "model_gb": 19.53,
        "vram_gb": 14,
        "license": "MiniMax H3 Community License",
        "commercial_ok": False,
        "warning": WARNING,
        "license_badge": LICENSE_BADGE,
        "output_badge": OUTPUT_BADGE,
        "best_for": "Video mit Stereoton aus Text und Referenzbildern (Figur, Gesicht)" + TEMPO_NOTE,
        "description": (
            "Die Referenz-Fassung von MiniMax H3 (Ref2VA, eigene Gewichte): bis zu 9 Referenzbilder legen Figur, "
            "Gesicht oder Stil fest, im Prompt als <Picture 1>, <Picture 2> … angesprochen; die Szene selbst entsteht "
            "aus dem Text, ohne Startbild. Bild und Stereoton in einem Durchgang, 24 fps, 5 bis 15 s.\n\n"
            "Graph nach ComfyUIs Vorlage video_minimax_h3_r2v: 20 Schritte res_multistep ohne CFG, Zeitplan beta (laut "
            "Vorlage bei Referenzen besser als simple), Referenzen in voller Größe bis 2048 px (ref_image_size max, "
            "stärkere Identität). Laut Vorlage reagiert diese Fassung stark auf die Wortwahl.\n\n"
            "Gemessen auf einer RTX 5060 Ti 16 GB: 9,4 s in 1344 × 576 in 37 min. Ein Gesicht aus zwei Referenzbildern "
            "blieb im Test über den ganzen Clip gleich; der Hintergrund einer Referenz wanderte ins Bild. "
            "Text-Encoder und VAEs teilt sie mit der FL2VA-Fassung; geladen wird nur der eigene Transformer (21 GB)."
        ),
        "pros": ["Figur oder Gesicht aus Referenzbildern, ohne Startbild",
                 "Gesicht aus Referenzbildern im Test über den ganzen Clip gehalten",
                 "Video mit Stereoton in einem Durchgang", "Bis zu 9 Referenzbilder"],
        "cons": ["Lizenz: ohne eigene Lizenz von MiniMax in der EU, Großbritannien, Südkorea und den USA verboten, "
                 "auch privat; Ergebnisse nicht veröffentlichen",
                 "Weitere 21 GB", "Langsam: 37 min für 9,4 s in 1344 × 576",
                 "Reagiert stark auf die Wortwahl (laut Vorlage)",
                 "Hintergrund einer Referenz kann ins Bild wandern (Test)"],
        "features": FEATURES_REF,
    },
    {
        "id": MODEL_ID_FAST,
        "name": "MiniMax H3 FastH3 8 Schritte (INT8, mit Ton)",
        "kind": "video",
        "family": "minimax_h3_fast",
        "workflow": WORKFLOW_FAST,
        "files": [
            {"repo": FASTH3_REPO, "file": "diffusion_models/fastvideo_fasth3_8step_v2_pruned_int8_convrot.safetensors",
             "target": "diffusion_models"},
            # Text-Encoder und VAEs wie MiniMax H3
            {"repo": REPO, "file": "text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors",
             "target": "text_encoders"},
            {"repo": REPO, "file": "vae/minimax_h3_video_vae_int8_convrot.safetensors", "target": "vae"},
            {"repo": REPO, "file": "vae/minimax_h3_audio_vae_fp32.safetensors", "target": "vae"},
        ],
        "size_gb": 38.42,
        "model_gb": 20.61,
        "vram_gb": 14,
        "license": "MiniMax H3 Community License",
        "commercial_ok": False,
        "warning": WARNING,
        "license_badge": LICENSE_BADGE,
        "output_badge": OUTPUT_BADGE,
        "best_for": "Schnell mit Ton aus Text oder Startbild, fest 8 Schritte, kaum Zeitlupe" + TEMPO_NOTE,
        "description": (
            "FastVideo FastH3 8-Step V2: ein DMD2-destillierter MiniMax-H3-Checkpoint (FastVideo mit Nuva Lab und "
            "NVIDIAs FastGen), Bild und Ton in genau 8 Schritten. Nur Text und Startbild (FL2VA), keine Referenzen. Er "
            "rechnet mit Video Sparse Attention (VSA) über eigene to_gate_compress-Schichten, Shift 10/3, res_multistep; "
            "NVAI-open setzt das fest wie ComfyUIs Vorlage. Laut ComfyUI tauscht FastH3 etwas Bewegungs- und Tonqualität "
            "gegen Tempo: für Entwürfe. Text-Encoder und VAEs teilt er mit MiniMax H3."
        ),
        "pros": ["8 Schritte und Video Sparse Attention fest eingebaut", "Video mit Stereoton in einem Durchgang"],
        "cons": ["Lizenz: ohne eigene Lizenz von MiniMax in der EU, Großbritannien, Südkorea und den USA verboten, "
                 "auch privat; Ergebnisse nicht veröffentlichen",
                 "Weitere 22 GB", "Etwas schwächere Bewegung und schwächerer Ton (laut ComfyUI)",
                 "Keine Referenzbilder"],
        "features": FEATURES_FAST,
    },
]
MODELS += TURBO_LORAS

EN: dict[str, dict[str, Any]] = {
    MODEL_ID: {
        "name": "MiniMax H3 (INT8, with sound)",
        "best_for": "Video with stereo sound from text or a start image, 5 to 15 s, follows the description closely" + TEMPO_NOTE_EN,
        "description": (
            "MiniMax, July 2026. A transformer makes picture and stereo sound (32 kHz) in one pass: voices, sound "
            "effects and music. The full model has 33B parameters; built in is the pruned version (about 20B going "
            "by the file size) in INT8. The text encoder is Qwen3-VL-32B (NVFP4). The open weights go up to 768p "
            "(short side), 5 to 15 s, 24 fps; 2K only through MiniMax' API. This version (FL2VA) takes text and "
            "optionally a start image.\n\n"
            "Graph after ComfyUI's template video_minimax_h3_t2v: 20 steps of res_multistep without CFG, with the "
            "turbo LoRA 8 steps (steps=8). Length on the 17k+5 frame grid (124 = 5.2 s).\n\n"
            "Measured on an RTX 5060 Ti 16 GB: 9.4 s at 1344 × 576 with 20 steps in 37 min, about "
            "107 s per step, 14.9 GB of graphics memory, free system memory never below 31.8 GB (of 64). LTX-2.5 "
            "took about 7 min for the same scene at 1920 × 832. In the test MiniMax followed the description more "
            "closely than LTX-2.5. Measured by others: 5 s at 864 × 480 about 633 s, at 960 × 544 about 809 s. "
            "Reports: faces fall apart in wide shots; after every prompt change ComfyUI loads the model from disk "
            "again."
        ),
        "pros": ["Video with stereo sound (voices, effects, music) in one pass",
                 "5 to 15 s in one go, 24 fps", "Start image as the first frame",
                 "Followed the description more closely than LTX-2.5 in the test",
                 "Turbo LoRA: 8 instead of 20 steps"],
        "cons": ["License: prohibited in the EU, the UK, South Korea and the USA without a separate license from "
                 "MiniMax, private use included; do not publish results",
                 "About 39 GB download",
                 "Slow: 37 min for 9.4 s at 1344 × 576 (LTX-2.5: about 7 min at 1920 × 832)",
                 "768p at most",
                 "Faces fall apart in wide shots (report)"],
        "warning": WARNING_EN,
        "license_badge": LICENSE_BADGE_EN,
        "output_badge": OUTPUT_BADGE_EN,
        "features": {
            "prompt_hint": (
                "One block of full English sentences: style and look first, then the scene; several shots as a "
                "timeline (\"[0s-2s] Shot 1: …\") with the camera; the sound last: dialogue in quotation marks "
                "with the speaker, effects, music. With a start image, describe what happens from that frame on. "
                "8 steps use the turbo LoRA (faster), otherwise 20." + TEMPO_HINT_EN),
        },
    },
    MODEL_ID_REF: {
        "name": "MiniMax H3 Reference (INT8, with sound)",
        "best_for": "Video with stereo sound from text and reference images (character, face)" + TEMPO_NOTE_EN,
        "description": (
            "The reference version of MiniMax H3 (Ref2VA, its own weights): up to 9 reference images set a character, "
            "a face or a style, addressed in the prompt as <Picture 1>, <Picture 2> …; the scene itself comes from the "
            "text, without a start image. Picture and stereo sound in one pass, 24 fps, 5 to 15 s.\n\n"
            "Graph after ComfyUI's template video_minimax_h3_r2v: 20 steps of res_multistep without CFG, beta schedule "
            "(better than simple with references, says the template), references at full size up to 2048 px "
            "(ref_image_size max, stronger identity). The template says this version reacts strongly to wording.\n\n"
            "Measured on an RTX 5060 Ti 16 GB: 9.4 s at 1344 × 576 in 37 min. A face from two reference images "
            "stayed the same through the whole clip in the test; the background of one reference moved into the "
            "picture. It shares the text encoder and the VAEs with the FL2VA version; only its own transformer "
            "(21 GB) is downloaded."
        ),
        "pros": ["Character or face from reference images, without a start image",
                 "Face from reference images held through the whole clip in the test",
                 "Video with stereo sound in one pass", "Up to 9 reference images"],
        "cons": ["License: prohibited in the EU, the UK, South Korea and the USA without a separate license from "
                 "MiniMax, private use included; do not publish results",
                 "Another 21 GB", "Slow: 37 min for 9.4 s at 1344 × 576",
                 "Reacts strongly to wording (says the template)",
                 "The background of a reference can move into the picture (test)"],
        "warning": WARNING_EN,
        "license_badge": LICENSE_BADGE_EN,
        "output_badge": OUTPUT_BADGE_EN,
        "features": {
            "prompt_hint": (
                "Address the references in the prompt as <Picture 1>, <Picture 2> … in the order of the images and say "
                "what each one sets (\"the man from <Picture 1>, with exactly his face\"); then scene, action, camera "
                "and sound as with FL2VA. No start image: the whole scene comes from the text. The template says this "
                "version reacts strongly to wording." + TEMPO_HINT_EN),
        },
    },
}
_TURBO_CONS_EN = ["Slightly softer motion and weaker sound than with 20 steps, says ComfyUI"]
EN[MODEL_ID_FAST] = {
    "name": "MiniMax H3 FastH3 8 steps (INT8, with sound)",
    "best_for": "Fast, with sound, from text or a start image, fixed 8 steps, hardly any slow motion" + TEMPO_NOTE_EN,
    "description": (
        "FastVideo FastH3 8-Step V2: a DMD2-distilled MiniMax H3 checkpoint (FastVideo with Nuva Lab and NVIDIA's "
        "FastGen), picture and sound in exactly 8 steps. Text and start image only (FL2VA), no references. It runs with "
        "video sparse attention (VSA) through its own to_gate_compress layers, shift 10/3, res_multistep; NVAI-open fixes "
        "these like ComfyUI's template. ComfyUI says FastH3 trades some motion and sound quality for speed: for drafts. "
        "It shares the text encoder and the VAEs with MiniMax H3."
    ),
    "pros": ["8 steps and video sparse attention built in", "Video with stereo sound in one pass"],
    "cons": ["License: prohibited in the EU, the UK, South Korea and the USA without a separate license from MiniMax, "
             "private use included; do not publish results",
             "Another 22 GB", "Slightly weaker motion and sound (says ComfyUI)", "No reference images"],
    "warning": WARNING_EN, "license_badge": LICENSE_BADGE_EN, "output_badge": OUTPUT_BADGE_EN,
    "features": {"prompt_hint": (
        "As with the start image version: one block of full English sentences, the scene, a timeline with the camera, "
        "the sound last. The steps are fixed at 8 (the checkpoint is distilled for that)." + TEMPO_HINT_EN)},
}
EN.update({
    "minimax-h3-turbo-fl2v-8step-v1.1-768p": {
        "name": "MiniMax H3 Turbo 8 steps v1.1 768p (start image, lightx2v)",
        "best_for": "Faster: 8 instead of 20 steps for the start image version, trained at 768p",
        "description": (
            "Turbo LoRA by lightx2v (20 October 2026) for the FL2VA version: 8 steps up to 768p, shift 6 (video) / 3 "
            "(sound), as lightx2v recommends for its new start image LoRAs. NVAI-open sets the shift, the euler sampler "
            "and the simple scheduler itself. lightx2v uses the 768p version (v1.0 there) in its own online studio."),
        "pros": ["8 instead of 20 steps"], "cons": _TURBO_CONS_EN,
        "warning": WARNING_EN, "license_badge": LICENSE_BADGE_EN,
    },
    "minimax-h3-turbo-ref2v-8step-v1.1-768p": {
        "name": "MiniMax H3 Turbo 8 steps v1.1 768p (reference, lightx2v)",
        "best_for": "Faster: 8 instead of 20 steps for the reference version, trained at 768p",
        "description": (
            "Turbo LoRA by lightx2v (20 October 2026) for the Ref2VA version: 8 steps up to 768p, shift 12 (video) / 3 "
            "(sound) like all reference LoRAs by lightx2v, references sized \"match\". NVAI-open sets the shift, euler, "
            "simple and \"match\" itself. ComfyUI says turbo LoRAs weaken the references; if a face must hold, use 20 "
            "to 25 steps without a LoRA."),
        "pros": ["8 instead of 20 steps"], "cons": _TURBO_CONS_EN,
        "warning": WARNING_EN, "license_badge": LICENSE_BADGE_EN,
    },
    "minimax-h3-turbo-fl2v-4step-v1.2-768p": {
        "name": "MiniMax H3 Turbo 4 steps v1.2 768p (start image, lightx2v)",
        "best_for": "Fastest: 4 instead of 20 steps for the start image version, up to 768p, cleaner sound",
        "description": (
            "Turbo LoRA by lightx2v (4 September 2026) for the FL2VA version: 4 steps up to 768p, shift 6 (video) / 3 "
            "(sound), euler, with cleaner sound than v1.1 says lightx2v. One user found the picture worse than v1.1 "
            "there; the newer v1.3 is said to run worse with sparse attention than v1.2."),
        "pros": ["4 instead of 20 steps"], "cons": _TURBO_CONS_EN,
        "warning": WARNING_EN, "license_badge": LICENSE_BADGE_EN,
    },
    "minimax-h3-turbo-ref2v-8step-v1.0-768p": {
        "name": "MiniMax H3 Turbo 8 steps v1.0 768p (reference, lightx2v)",
        "best_for": "Faster: 8 instead of 20 steps for the reference version, the predecessor of v1.1",
        "description": (
            "Turbo LoRA by lightx2v (3 September 2026) for the Ref2VA version: 8 steps up to 768p, shift 12 (video) / 3 "
            "(sound), euler, references sized \"match\" (release note). One user at lightx2v found it better than v1.1 "
            "(speech and prompt following)."),
        "pros": ["8 instead of 20 steps"], "cons": _TURBO_CONS_EN,
        "warning": WARNING_EN, "license_badge": LICENSE_BADGE_EN,
    },
    "minimax-h3-turbo-ref2v-4step-v1.0-768p": {
        "name": "MiniMax H3 Turbo 4 steps v1.0 768p (reference, lightx2v)",
        "best_for": "Fastest: 4 instead of 20 steps for the reference version, up to 768p",
        "description": (
            "Turbo LoRA by lightx2v (20 October 2026) for the Ref2VA version: 4 steps up to 768p, shift 12 / 3 like all "
            "reference LoRAs by lightx2v, references sized \"match\". ComfyUI says turbo costs face and sound with "
            "references; one user reported blurry, jittery pictures with this version at lightx2v."),
        "pros": ["4 instead of 20 steps"], "cons": _TURBO_CONS_EN,
        "warning": WARNING_EN, "license_badge": LICENSE_BADGE_EN,
    },
    "minimax-h3-turbo-fl2v-8step-v1.0": {
        "name": "MiniMax H3 Turbo 8 steps v1.0 (start image, lightx2v)",
        "best_for": "Faster: 8 instead of 20 steps for the start image version, trained at 544p",
        "description": (
            "The turbo LoRA from ComfyUI's template (lightx2v v1.0): 8 steps (4 also work, says lightx2v), trained at "
            "544p with shift 12 / 3. Chosen as a LoRA, NVAI-open runs it like lightx2v with euler; only with "
            "steps ≤ 8 and no LoRA chosen does the start image version use the same file like ComfyUI's template "
            "(res_multistep)."),
        "pros": ["8 instead of 20 steps"], "cons": _TURBO_CONS_EN,
        "warning": WARNING_EN, "license_badge": LICENSE_BADGE_EN,
    },
})
# Gemessene Zeiten auch auf Englisch (registry.localized fuehrt features zusammen)
for _id in [MODEL_ID, MODEL_ID_REF, MODEL_ID_FAST] + [e["id"] for e in TURBO_LORAS]:
    EN[_id].setdefault("features", {})["tested"] = TESTED_EN.get(_id, "")


def _turbo(entry: dict[str, Any], p: dict[str, Any]) -> dict[str, Any]:
    """Schritte, Shift, Sampler …: fest beim destillierten Checkpoint (features.distilled, FastH3), sonst features.turbo
    der am Auftrag gewaehlten Turbo-LoRA, sonst leer."""
    from . import registry

    if (entry.get("features") or {}).get("distilled"):
        return entry["features"]["distilled"]
    for ref in p.get("loras") or []:
        e = registry.get_entry(str(ref.get("model_id") or ""))
        if e and (e.get("features") or {}).get("turbo"):
            return e["features"]["turbo"]
    return {}


def _steps(turbo: dict[str, Any], p: dict[str, Any]) -> int:
    # Destillierte Checkpoints (FastH3) sind auf genau ihre Schrittzahl trainiert: dann gilt nur diese.
    return int(turbo["steps"] if turbo.get("fixed") else p.get("steps") or turbo.get("steps") or STEPS)


def run_meta(entry: dict[str, Any], p: dict[str, Any]) -> dict[str, Any]:
    """Was der Lauf wirklich nimmt, fuer die Angaben am Ergebnis: Schritte (Turbo-LoRA bzw. destilliert), CFG 1 (das
    Modell ist CFG-destilliert), Sparse Attention und INT8-Attention."""
    turbo = _turbo(entry, p)
    return {"steps": _steps(turbo, p), "cfg": 1.0,
            "sparse_attention": p.get("sparse_attention") or turbo.get("sparse"),
            "int8_attention": bool(p.get("int8_attention"))}


def _shift(g: dict[str, Any], model: list[Any], turbo: dict[str, Any]) -> list[Any]:
    """Shift (Video/Ton), auf den die Turbo-LoRA trainiert ist; ohne Angabe bleibt ComfyUIs Vorgabe 12/3. Haengt am
    UNET-Ausgang: loras.apply setzt die LoRA-Kette spaeter davor (UNET -> LoRA -> Shift)."""
    if not turbo.get("shift"):
        return model
    video, audio = turbo["shift"]
    g["1s"] = {"class_type": "MiniMaxH3SigmaShift", "inputs": {
        "model": model, "shift_video": float(video), "shift_audio": float(audio)}}
    return ["1s", 0]


def _attention(g: dict[str, Any], model: list[Any], p: dict[str, Any]) -> list[Any]:
    """Dichte Attention in INT8 (comfy-kitchen, ComfyUIs "Model Attention Backend" mit "comfy kitchen attention"); mit
    Sparse Attention gilt sie fuer deren dichte Teile (erste Schritte, kurze Sequenzen). Gemessen: halbiert die Rechenzeit
    wie sol-attn, beide zusammen 6,6 statt 16,8 min (Referenz, Turbo 8)."""
    if not p.get("int8_attention"):
        return model
    g["1b"] = {"class_type": "ModelAttentionBackend", "inputs": {"model": model, "attention": "comfy kitchen attention"}}
    return ["1b", 0]


def _sparse(g: dict[str, Any], model: list[Any], p: dict[str, Any], turbo: dict[str, Any],
            veda_predictor: str = VEDA_PREDICTOR) -> list[Any]:
    """Sparse Attention, zuletzt vor Sampler und Guider. sol-attn: ohne Training (ComfyUIs "Model Sparse Attention", Kernel
    aus comfy-kitchen, laeuft auf der 5060 Ti ohne Triton), ComfyUIs Vorgaben tau 1,3 ab 20 % der Schritte, Ton-Zeilen
    exakt (exact_kv_and_rows). vsa: fest beim
    FastH3-Checkpoint (dessen to_gate_compress-Schichten), keep 10 % ab 20 % laut ComfyUI-Doku. veda: gelernter Praediktor
    (Knotenpaket Veda-on-ComfyUI in custom_nodes, braucht triton-windows; Vorgabe 32 Kacheln je Abfrage), nicht mit
    sol-attn kombinierbar."""
    method = p.get("sparse_attention") or turbo.get("sparse")
    if not method:
        return model
    if method == "veda":
        g["1a"] = {"class_type": "VedaSparseAttention", "inputs": {
            "model": model, "predictor": veda_predictor, "generated_sparsity": VEDA_BUDGET,
            "reference_sparsity": VEDA_BUDGET, "full_attention_layers": "", "full_attention_steps": "", "verbose": False}}
        return ["1a", 0]
    if method == "sol-attn":
        tau = p.get("sparse_tau")
        selection = {"selection": "sol-attn", "selection.tau": float(SOL_TAU if tau is None else tau)}
    elif method == "vsa":
        selection = {"selection": "vsa", "selection.keep_percent": float(turbo.get("keep_percent") or 10.0)}
    else:
        raise ValueError(t(f"Unbekannte Sparse Attention: {method}", f"Unknown sparse attention: {method}"))
    g["1a"] = {"class_type": "BlockSparseAttention", "inputs": {
        "model": model, **selection, "start_percent": SOL_START, "end_percent": 1.0, "dense_blocks": "",
        "min_tokens": 12288, "extra_tokens": 256, "sink_conditioning": "exact_kv_and_rows", "verbose": False}}
    return ["1a", 0]


def _head(entry: dict[str, Any], p: dict[str, Any], workflow: str) -> tuple[dict[str, Any], dict[str, Any]]:
    """Gemeinsamer Anfang beider Wege: Pruefungen, Format auf dem 32er-Raster, Laenge auf 17k+5, die vier Lader."""
    from . import workflows as wf  # erst hier: workflows laedt diese Datei beim Import

    fps = float(p.get("fps") or FPS)
    if abs(fps - FPS) > 0.01:
        raise ValueError(t(f"MiniMax H3 rechnet mit {FPS} fps; bitte fps={FPS} angeben.",
                           f"MiniMax H3 runs at {FPS} fps; please pass fps={FPS}."))
    turbo = _turbo(entry, p)
    v = {"seed": wf._seed(p), "fps": fps,
         "width": max(256, int(p.get("width") or 864) // 32 * 32),
         "height": max(256, int(p.get("height") or 480) // 32 * 32),
         "frames": wf.normalize_frames(int(p.get("frames") or DEFAULT_FRAMES), workflow),
         "steps": _steps(turbo, p), "turbo": turbo}
    g: dict[str, Any] = {
        "1": {"class_type": "UNETLoader", "inputs": {
            "unet_name": wf._file_by_target(entry, "diffusion_models"), "weight_dtype": "default"}},
        "2": {"class_type": "CLIPLoader", "inputs": {
            "clip_name": wf._file_by_target(entry, "text_encoders"), "type": "minimax"}},
        "3": {"class_type": "VAELoader", "inputs": {"vae_name": wf._file_by_target(entry, "vae", "video")}},
        "4": {"class_type": "VAELoader", "inputs": {"vae_name": wf._file_by_target(entry, "vae", "audio")}},
    }
    return g, v


def _tail(g: dict[str, Any], v: dict[str, Any], p: dict[str, Any], model: list[Any], scheduler: str) -> None:
    """Gemeinsames Ende: Rauschen, res_multistep (mit Turbo-LoRA deren Sampler), BasicGuider ohne CFG auf Knoten 8
    (Conditioning, Latent), beide VAEs dekodieren dasselbe Latent, der Ton geht wie bei LTX-2.5 durch den Limiter ins
    MP4."""
    from . import workflows as wf

    g["9"] = {"class_type": "RandomNoise", "inputs": {"noise_seed": v["seed"]}}
    g["10"] = {"class_type": "KSamplerSelect", "inputs": {
        "sampler_name": v["turbo"].get("sampler") or "res_multistep"}}
    g["11"] = {"class_type": "BasicScheduler", "inputs": {
        "model": model, "scheduler": scheduler, "steps": v["steps"], "denoise": 1.0}}
    g["12"] = {"class_type": "BasicGuider", "inputs": {"model": model, "conditioning": ["8", 0]}}
    g["13"] = {"class_type": "SamplerCustomAdvanced", "inputs": {
        "noise": ["9", 0], "guider": ["12", 0], "sampler": ["10", 0], "sigmas": ["11", 0],
        "latent_image": ["8", 1]}}
    g["14"] = {"class_type": "VAEDecode", "inputs": {"samples": ["13", 0], "vae": ["3", 0]}}
    g["15"] = {"class_type": "VAEDecodeAudio", "inputs": {"samples": ["13", 0], "vae": ["4", 0]}}
    g["16"] = {"class_type": "NVAIAudioLimiter", "inputs": {
        "audio": ["15", 0], "ceiling_db": wf.VIDEO_AUDIO_CEILING_DB, "lookahead_ms": 5.0, "release_ms": 80.0}}
    g["17"] = {"class_type": "CreateVideo", "inputs": {"images": ["14", 0], "fps": v["fps"], "audio": ["16", 0]}}
    crf = p.get("crf")
    g["18"] = {"class_type": "SaveVideo", "inputs": {
        "video": ["17", 0], "filename_prefix": "nvai_video", "format": "mp4",
        "format.codec": "h264", "format.codec.encoding": "re-encode",
        "format.codec.encoding.crf": float(wf.VIDEO_CRF if crf is None else crf)}}


def build(entry: dict[str, Any], p: dict[str, Any]) -> tuple[dict[str, Any], int]:
    """FL2VA wie die Vorlage video_minimax_h3_t2v: UNET (+ Turbo-LoRA bei steps <= 8), MiniMaxH3ImageToVideo mit
    optionalem erstem Bild liefert Conditioning und das gemeinsame Bild-Ton-Latent."""
    from . import registry, workflows as wf

    g, v = _head(entry, p, WORKFLOW)
    # Die eingebaute Turbo-LoRA (ComfyUIs Vorlage) nur ohne am Auftrag gewaehlte Turbo-LoRA
    turbo = v["steps"] <= TURBO_STEPS and not v["turbo"]
    if turbo and not registry.optional_status(entry).get(TURBO):
        raise ValueError(t(f"Für {v['steps']} Schritte fehlt die Turbo-LoRA; ohne sie {STEPS} Schritte.",
                           f"{v['steps']} steps need the turbo LoRA; without it use {STEPS} steps."))
    model: list[Any] = ["1", 0]
    if turbo:
        g["5"] = {"class_type": "LoraLoaderModelOnly", "inputs": {
            "model": ["1", 0], "lora_name": wf._file_by_target(entry, "loras", TURBO), "strength_model": 1.0}}
        model = ["5", 0]
    cond: dict[str, Any] = {"clip": ["2", 0], "vae": ["3", 0], "prompt": p["prompt"],
                            "width": v["width"], "height": v["height"], "length": v["frames"]}
    if p.get("start_image"):
        # Der Knoten zieht das erste Bild ohne Zuschnitt auf das Format; vorher mittig zuschneiden, sonst verzerrt.
        g["6"] = {"class_type": "LoadImage", "inputs": {"image": p["start_image"]}}
        g["7"] = {"class_type": "ImageScale", "inputs": {
            "image": ["6", 0], "upscale_method": "lanczos", "width": v["width"], "height": v["height"],
            "crop": "center"}}
        cond["first_frame"] = ["7", 0]
    g["8"] = {"class_type": "MiniMaxH3ImageToVideo", "inputs": cond}
    model = _sparse(g, _attention(g, _shift(g, model, v["turbo"]), p), p, v["turbo"])
    _tail(g, v, p, model, v["turbo"].get("scheduler") or "simple")
    return g, v["seed"]


def build_ref(entry: dict[str, Any], p: dict[str, Any]) -> tuple[dict[str, Any], int]:
    """Ref2VA wie die Vorlage video_minimax_h3_r2v: MiniMaxH3ReferenceToVideo mit den Referenzbildern als
    ref_images.ref_image_0 … (im Prompt <Picture 1> …), beiden VAEs und ref_image_size max; Zeitplan beta."""
    refs = p.get("reference_images") or []
    if not refs:
        raise ValueError(t("Die Referenz-Fassung braucht mindestens ein Referenzbild (reference_asset_ids).",
                           "The reference version needs at least one reference image (reference_asset_ids)."))
    if p.get("start_image"):
        raise ValueError(t("Die Referenz-Fassung nimmt kein Startbild; das Bild als Referenz übergeben.",
                           "The reference version takes no start image; pass the image as a reference."))
    g, v = _head(entry, p, WORKFLOW_REF)
    turbo = v["turbo"]
    # Mit Turbo-LoRA die Referenzgroesse ihres Trainings ("match"), sonst volle Groesse fuer staerkere Identitaet
    cond: dict[str, Any] = {"clip": ["2", 0], "vae": ["3", 0], "audio_vae": ["4", 0], "prompt": p["prompt"],
                            "width": v["width"], "height": v["height"], "length": v["frames"],
                            "ref_image_size": turbo.get("ref_image_size") or REF_IMAGE_SIZE}
    for i, name in enumerate(refs):
        g[f"r{i}"] = {"class_type": "LoadImage", "inputs": {"image": name}}
        cond[f"ref_images.ref_image_{i}"] = [f"r{i}", 0]
    g["8"] = {"class_type": "MiniMaxH3ReferenceToVideo", "inputs": cond}
    _tail(g, v, p, _sparse(g, _attention(g, _shift(g, ["1", 0], turbo), p), p, turbo, VEDA_PREDICTOR_REF),
          p.get("scheduler") or turbo.get("scheduler") or REF_SCHEDULER)
    return g, v["seed"]


FRAME_GRID = {WORKFLOW: (FRAME_STEP, FRAME_REST), WORKFLOW_REF: (FRAME_STEP, FRAME_REST),
              WORKFLOW_FAST: (FRAME_STEP, FRAME_REST)}
BUILDERS = {WORKFLOW: build, WORKFLOW_REF: build_ref, WORKFLOW_FAST: build}
