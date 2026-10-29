"""Kuratierter Modellkatalog fuer 16 GB VRAM.

Jeder Eintrag wurde gegen die HuggingFace-API geprueft (Repo + Datei existieren,
Groesse stimmt) und gegen die Node-Liste der lokalen ComfyUI-Installation
(`workflow` ist nur gesetzt, wenn die noetigen Nodes vorhanden sind).

Feldbedeutung:
  files      Liste der noetigen Downloads. Viele moderne Modelle sind aufgeteilt
             in Diffusion-Model + Text-Encoder + VAE.
  vram_gb    Realistischer VRAM-Bedarf beim Sampling, nicht die Dateigroesse.
  workflow   Schluessel des Workflow-Builders in comfy.py. None = noch kein Builder.
  commercial_ok  Fuer ein verkauftes Spiel nutzbar. Kein Rechtsrat.
"""
from __future__ import annotations

import re
from pathlib import PurePosixPath
from typing import Any

# ---------------------------------------------------------------- BILD

# Qwens eigene Formatempfehlung (Modellkarte Qwen-Image-2512, aspect_ratios): rund
# 1,76 MP statt der ~1 MP der allgemeinen Formatliste.
QWEN_NATIVE_SIZES = [
    {"label": "1328 × 1328 — Qwen nativ, Objekte", "w": 1328, "h": 1328},
    {"label": "1056 × 1584 — Qwen nativ 2:3, Figuren", "w": 1056, "h": 1584},
    {"label": "1104 × 1472 — Qwen nativ 3:4", "w": 1104, "h": 1472},
    {"label": "1584 × 1056 — Qwen nativ 3:2, Fahrzeuge", "w": 1584, "h": 1056},
    {"label": "1472 × 1104 — Qwen nativ 4:3", "w": 1472, "h": 1104},
    {"label": "1664 × 928 — Qwen nativ 16:9, Panorama", "w": 1664, "h": 928},
    {"label": "928 × 1664 — Qwen nativ 9:16", "w": 928, "h": 1664},
]
QWEN_PROMPT_HINT = (
    "Ganze Sätze statt Stichworte: zuerst Medium und Stil, dann das Motiv mit Material, "
    "Farbe und Zustand, dann Licht und Hintergrund. Schrift in Anführungszeichen setzt "
    "Qwen buchstabengenau. Konstruktion ausdrücklich nennen („rope handles pass through "
    "drilled holes“), sonst wird sie erfunden."
)
QWEN_PLACEHOLDER = (
    'Studio product photograph of a weathered wooden ammunition crate. Black stenciled '
    'letters on the front read "MUNITION 7,92". Rope handles pass through drilled holes in '
    'the side boards. Plain light grey background, soft even light.'
)

# FLUX 3 Image Klein erzeugt nativ bis 4K (BFL). Die Formatschranke der API liegt bei
# 2048; alle Seiten sind Vielfache von 16, wie EmptyFlux2LatentImage es verlangt.
FLUX3_LARGE_SIZES = [
    {"label": "1152 × 1728 — 2 MP hochkant, Figuren mit Detail", "w": 1152, "h": 1728},
    {"label": "1440 × 1440 — 2 MP, Objekte mit Detail", "w": 1440, "h": 1440},
    {"label": "1728 × 1152 — 2 MP quer, Fahrzeuge mit Detail", "w": 1728, "h": 1152},
    {"label": "2048 × 2048 — 4 MP, maximal", "w": 2048, "h": 2048},
]
# HiDream-O1 ist auf rund 4 Megapixel trainiert (ComfyUI, EmptyHiDreamO1LatentImage);
# darunter wird es laut Hersteller deutlich schlechter.
HIDREAM_O1_SIZES = [
    {"label": "2048 × 2048 — 4 MP, trainiert", "w": 2048, "h": 2048},
    {"label": "1728 × 2304 — 4 MP hochkant, Figuren", "w": 1728, "h": 2304},
    {"label": "2304 × 1728 — 4 MP quer", "w": 2304, "h": 1728},
    {"label": "1664 × 2496 — 4 MP 2:3, Figuren", "w": 1664, "h": 2496},
    {"label": "2496 × 1664 — 4 MP 3:2, Fahrzeuge", "w": 2496, "h": 1664},
    {"label": "2560 × 1440 — 4 MP 16:9, Panorama", "w": 2560, "h": 1440},
]
BOOGU_FILES_SHARED = [
    {"repo": "Comfy-Org/Boogu-Image", "file": "text_encoders/qwen3vl_8b_fp8_scaled.safetensors",
     "target": "text_encoders"},
    {"repo": "Comfy-Org/Boogu-Image", "file": "vae/flux1_vae_bf16.safetensors", "target": "vae"},
]

FLUX3_PROMPT_HINT = (
    "Kurz und vollständig beschreiben: Stil, Motiv, Anzahl, Anordnung, Konstruktion. Der "
    "Upsampler baut daraus die lange Bildbeschreibung, auf die FLUX 3 trainiert ist — ohne "
    "Stilangabe plant er ein Foto, und was offen bleibt, erfindet er (im Test einen Mantel "
    "als Umhang). Text in Anführungszeichen bleibt wörtlich. Referenzbilder heißen im Prompt "
    "„the first image“, „the second image“ usw."
)
FLUX3_PLACEHOLDER = (
    'a weathered wooden ammunition crate, black stenciled "MUNITION 7,92" on the front, '
    'rope handles pass through drilled holes in the side boards, studio shot on plain '
    'light grey'
)
FLUX3_FILES_SHARED = [
    # Qwen3-VL-4B als Text-Encoder (int8, Standard der ComfyUI-Vorlagen fuer <= 24 GB).
    {"repo": "black-forest-labs/flux-3-image-klein-comfy",
     "file": "text_encoders/qwen3vl_4b_int8_convrot.safetensors", "target": "text_encoders"},
    # Der Prompt-Upsampler (Qwen3.5-9B). BFL: ohne ihn generische Bilder, das Modell ist
    # auf seine Beschreibungen trainiert. int8 ist BFLs Standard; w4a8 waere 3 GB kleiner.
    {"repo": "black-forest-labs/flux-3-image-klein-comfy",
     "file": "text_encoders/qwen3.5_9b_flux3_prompt_upsampler_int8_convrot.safetensors",
     "target": "text_encoders"},
    {"repo": "black-forest-labs/flux-3-image-klein-comfy",
     "file": "vae/flux2-vae.safetensors", "target": "vae"},
]
# Für Karten ohne FP4 (RTX 20/30/40) und mit wenig Speicher: BFLs eigene INT8-Vorlage
# (workflows/flux3_klein_int8_t2i.json im Repo) nimmt den w4a8-Upsampler, 3 GB kleiner.
FLUX3_FILES_SMALL = [
    FLUX3_FILES_SHARED[0],
    {"repo": "black-forest-labs/flux-3-image-klein-comfy",
     "file": "text_encoders/qwen3.5_9b_flux3_prompt_upsampler_w4a8.safetensors",
     "target": "text_encoders"},
    FLUX3_FILES_SHARED[2],
]
FLUX3_LICENSE_WARNING = (
    "FLUX Kommunity License: Bilder kommerziell nur bei unter 5 Mio. US-$ Jahresumsatz "
    "(inkl. verbundener Unternehmen), jedes Bild vor der Veröffentlichung prüfen, KI-Kennzeichnung "
    "soweit gesetzlich verlangt. BFL kann die Lizenz jederzeit kündigen."
)

# Krea 2 (Krea.ai, Juni 2026): laut Krea 1 bis 2 MP; Seiten Vielfache von 16.
KREA2_SIZES = [
    {"label": "1408 × 1408 — 2 MP, Objekte mit Detail", "w": 1408, "h": 1408},
    {"label": "1152 × 1728 — 2 MP hochkant, Figuren mit Detail", "w": 1152, "h": 1728},
    {"label": "1728 × 1152 — 2 MP quer, Fahrzeuge mit Detail", "w": 1728, "h": 1152},
    {"label": "1920 × 1088 — 2 MP 16:9, Panorama", "w": 1920, "h": 1088},
]
KREA2_PROMPT_HINT = (
    "Ganze englische Sätze, Stil zuerst: Medium, dann das Motiv mit Material und Licht, zuletzt der "
    "Hintergrund. Den Bildausschnitt ausdrücklich nennen („medium shot from the waist up, his whole "
    "head inside the frame“), sonst rückt Krea das Betonte ins Bild und schneidet anderes ab. Krea 2 "
    "ist auf ausführliche Beschreibungen trainiert; ein paar Worte vorher mit „Prompt ausbauen“ "
    "ausbauen. Der Negativprompt wirkt hier nicht (cfg 1)."
)
KREA2_PLACEHOLDER = (
    "Candid 35 mm film photograph of an old fisherman mending a net on a wooden pier at golden hour, "
    "weathered hands, salt-stained wool sweater, soft warm light, shallow depth of field"
)
KREA2_LICENSE_WARNING = (
    "Krea 2 Community License: kommerziell nur bei unter 1 Mio. US-$ Jahresumsatz (inkl. "
    "verbundener Unternehmen), Inhaltsfilter oder Prüfung jedes Bildes von Hand vorgeschrieben, "
    "KI-Kennzeichnung soweit gesetzlich verlangt. Krea kann die Lizenz mit 30 Tagen Frist kündigen."
)
KREA2_FILES_SHARED = [
    # Derselbe Qwen3-VL-4B wie bei FLUX 3 und derselbe VAE wie bei Qwen-Image (beide bytegleich,
    # SHA-256 am 24.10. verglichen); Comfy-Org/Krea-2 ist anders als Kreas eigene Repos nicht gated.
    {"repo": "Comfy-Org/Krea-2", "file": "text_encoders/qwen3vl_4b_int8_convrot.safetensors",
     "target": "text_encoders"},
    {"repo": "Comfy-Org/Krea-2", "file": "vae/qwen_image_vae.safetensors", "target": "vae"},
    # Stil-Referenz (ostris, Krea 2 Community License, 0,46 GB, nicht gated): optional, schaltet bis
    # zu zwei Referenzbilder frei, deren Stil Krea übernimmt (workflows.build_krea2).
    {"repo": "ostris/krea2_turbo_style_reference", "file": "krea2_style_reference.safetensors",
     "target": "loras", "optional": "style_reference"},
]
# Was die optionale Stil-Referenz freischaltet (registry.features_for, "with_optional"). Laut ostris
# auf ein bis zwei Referenzbilder trainiert.
KREA2_WITH_OPTIONAL = {"style_reference": {"references": 2, "reference_kind": "style"}}

# MOSS-Image (OpenMOSS, 16.10.2026): laut OpenMOSS 1 bis 2 MP empfohlen, 0,25 bis 4 MP möglich, Seiten
# Vielfache von 16 -- dieselben 2-MP-Formate wie bei Krea 2.
MOSS_IMAGE_SIZES = KREA2_SIZES
MOSS_IMAGE_PROMPT_HINT = (
    "MOSS-Image ist auf Bildbeschreibungen trainiert: beschreiben, wie das fertige Bild aussieht, nicht was zu "
    "tun ist. Erst Medium und Motiv, dann Ort und Aufbau, dann Licht und Farben. Schrift wörtlich in "
    "Anführungszeichen, mit Ort, Größe und Schriftart; Zeilenumbrüche selbst setzen. Kurze Prompts baut "
    "MOSS-Image vorher mit seinem eigenen Text-Encoder aus (abschaltbar). Layout: ein JSON mit „summary“ und "
    "„items“ als Prompt, dann ohne Ausbau. Der Negativprompt wirkt (cfg 3)."
)
MOSS_IMAGE_PLACEHOLDER = (
    "Vintage travel poster in flat gouache colors: snow-capped peaks at sunrise above a red cable car, bold "
    "Art Deco lettering \"ALPENGLOW\" across the top and \"SINCE 1928\" in small capitals at the bottom"
)
MOSS_IMAGE_FILES = [
    {"repo": "Comfy-Org/MOSS-Image", "file": "diffusion_models/moss_image_sft_int8_convrot.safetensors",
     "target": "diffusion_models"},
    # Standard-Qwen3.5-9B (W4A8) wie in ComfyUIs Vorlage; der Upsampler von FLUX 3 ist ein feinjustiertes
    # Qwen3.5-9B und taugt nicht als Text-Encoder.
    {"repo": "Comfy-Org/MOSS-Image", "file": "text_encoders/qwen3.5_9b_w4a8_gptq.safetensors",
     "target": "text_encoders"},
    # Die kleine FLUX.2-VAE wie in der Vorlage: Apache-2.0 (BFLs FLUX.2-small-decoder); die große führt
    # flux-2-swift-mlx als „FLUX.2 Non-Commercial“ -- so bleibt MOSS-Image durchgehend Apache-2.0.
    {"repo": "Comfy-Org/MOSS-Image", "file": "vae/flux2-vae_small.safetensors", "target": "vae"},
]

QWEN21_LICENSE_WARNING = (
    "Qwen Research License: nur für Forschung und Evaluation, keine kommerzielle Nutzung — "
    "auch keine Bilder für ein verkauftes Spiel. Für Endassets Qwen-Image-2512 (Apache-2.0) "
    "nehmen."
)
# Qwens Seitenverhaeltnisse aus der Modellkarte, auf die 2048er-Grenze der API verkleinert
# (Qwen selbst nennt 2048 × 2048 und 2400 × 1792 usw.). Vielfache von 32.
QWEN21_SIZES = [
    {"label": "1536 × 1536 — 2,4 MP, Objekte", "w": 1536, "h": 1536},
    {"label": "1344 × 1792 — 3:4, Figuren", "w": 1344, "h": 1792},
    {"label": "1792 × 1344 — 4:3, Fahrzeuge", "w": 1792, "h": 1344},
    {"label": "2048 × 2048 — Qwen nativ, maximal", "w": 2048, "h": 2048},
]


# Kandinsky 5.0 Video Lite: Text-Encoder und VAE wie in ComfyUIs Vorlagen. Qwen2.5-VL kommt
# aus demselben Repo wie bei Qwen-Image, damit die Datei nur einmal auf der Platte liegt.
KANDINSKY5_SHARED = [
    {"repo": "Comfy-Org/Qwen-Image_ComfyUI",
     "file": "split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors", "target": "text_encoders"},
    {"repo": "comfyanonymous/flux_text_encoders", "file": "clip_l.safetensors", "target": "text_encoders"},
    {"repo": "Kijai/HunyuanVideo_comfy", "file": "hunyuan_video_vae_bf16.safetensors", "target": "vae"},
]
KANDINSKY5_VAE_WARNING = (
    "Das Modell steht unter MIT, der VAE stammt aber von HunyuanVideo (Tencent Hunyuan Community "
    "License). Die gilt laut Tencent nicht in der EU, in Großbritannien und Südkorea — vor "
    "kommerzieller Nutzung dort prüfen."
)

IMAGE_MODELS: list[dict[str, Any]] = [
    {
        "id": "sdxl-base",
        "name": "SDXL Base 1.0",
        "kind": "image",
        "family": "sdxl",
        "workflow": "sdxl",
        "files": [{"repo": "stabilityai/stable-diffusion-xl-base-1.0",
                   "file": "sd_xl_base_1.0.safetensors", "target": "checkpoints"}],
        "size_gb": 6.46,
        "vram_gb": 8,
        "license": "CreativeML Open RAIL++-M",
        "commercial_ok": True,
        "best_for": "Allrounder und Ausgangspunkt für eigene Stile",
        "description": (
            "Das Basismodell, um das herum das größte Ökosystem der Szene gewachsen ist. "
            "Für sich genommen unspektakulär, aber jede LoRA, jeder ControlNet und jeder "
            "Feintune für Game-Art setzt darauf auf. Wenn du einen konsistenten Look über "
            "hunderte Assets brauchst, trainierst du am Ende eine LoRA — und die wird "
            "SDXL-basiert sein."
        ),
        "pros": [
            "Riesige Auswahl an LoRAs, ControlNets und Feintunes",
            "Sehr genügsam: ~8 GB VRAM, viel Luft für parallele Arbeit",
            "Schnell (~12 s für 1024², 28 Steps auf der 5060 Ti)",
            "Lizenz unkritisch für kommerzielle Spiele",
        ],
        "cons": [
            "Prompt-Treue deutlich unter FLUX/SD3.5 — lange Prompts werden ignoriert",
            "Text im Bild ist praktisch unbrauchbar",
            "Roh oft flau; braucht gute Prompts oder einen Feintune",
        ],
    },
    {
        "id": "juggernaut-xl-v9",
        "name": "Juggernaut XL v9",
        "kind": "image",
        "family": "sdxl",
        "workflow": "sdxl",
        "files": [{"repo": "RunDiffusion/Juggernaut-XL-v9",
                   "file": "Juggernaut-XL_v9_RunDiffusionPhoto_v2.safetensors", "target": "checkpoints"}],
        "size_gb": 6.62,
        "vram_gb": 8,
        "license": "CreativeML Open RAIL++-M",
        "commercial_ok": True,
        "best_for": "Realistische Texturen, Materialien, Environment-Referenzen",
        "description": (
            "SDXL-Feintune mit Fokus auf Fotorealismus. Für Game-Dev vor allem dann stark, "
            "wenn du Material- und Texturreferenzen brauchst: Stein, Metall, Stoff, Rost, "
            "Holz. Auch für Concept-Art von Umgebungen, die realistisch wirken sollen."
        ),
        "pros": [
            "Deutlich besseres Out-of-the-box-Ergebnis als SDXL Base",
            "Sehr gut bei Materialien und Oberflächen",
            "Voll LoRA-kompatibel zu SDXL",
        ],
        "cons": [
            "Zieht alles Richtung Fotorealismus — für Stilisiertes ungeeignet",
            "Erbt die SDXL-Schwächen bei Prompt-Treue und Text",
        ],
    },
    {
        "id": "illustrious-xl",
        "name": "Illustrious XL v0.1",
        "kind": "image",
        "family": "sdxl",
        "workflow": "sdxl",
        "files": [{"repo": "OnomaAIResearch/Illustrious-xl-early-release-v0",
                   "file": "Illustrious-XL-v0.1.safetensors", "target": "checkpoints"}],
        "size_gb": 6.46,
        "vram_gb": 8,
        "license": "Fair AI Public License 1.0-SD",
        "commercial_ok": True,
        "best_for": "Stilisierte 2D-Assets, Charaktere, Anime-/Cartoon-Look",
        "description": (
            "Der Standard für stilisierte 2D-Kunst. Versteht Tag-basierte Prompts (Danbooru-Stil) "
            "sehr präzise, was bei Charakter-Assets enorm hilft: Pose, Kleidung, Ausdruck und "
            "Perspektive lassen sich gezielt steuern. Für 2D-Spiele oder stilisierte UI-Assets "
            "meist die bessere Wahl als SDXL Base."
        ),
        "pros": [
            "Exzellente Kontrolle über Charaktermerkmale via Tags",
            "Konsistenter Stil über viele Generierungen",
            "Sehr aktive LoRA-Szene",
        ],
        "cons": [
            "Tag-Syntax will gelernt sein — natürliche Sprache funktioniert schlechter",
            "Für Fotorealismus oder Environments ungeeignet",
            "Lizenz verlangt, dass abgeleitete Modelle offen bleiben",
        ],
    },
    {
        "id": "flux1-schnell-fp8",
        "name": "FLUX.1 schnell (fp8)",
        "kind": "image",
        "family": "flux",
        "workflow": "flux",
        "files": [{"repo": "Comfy-Org/flux1-schnell",
                   "file": "flux1-schnell-fp8.safetensors", "target": "checkpoints"}],
        "size_gb": 16.05,
        "vram_gb": 12,
        "license": "Apache-2.0",
        "commercial_ok": True,
        "best_for": "Komplexe Prompts, schnelle Iteration, kommerzielle Nutzung",
        "description": (
            "Der beste Kompromiss aus Qualität, Geschwindigkeit und Lizenz. Versteht lange, "
            "verschachtelte Prompts, die SDXL komplett ignoriert, und braucht dafür nur 4 Steps. "
            "Apache-2.0 heißt: uneingeschränkt kommerziell nutzbar — anders als FLUX.1 dev. "
            "Für Game-Assets, die in ein verkauftes Spiel sollen, ist das meine Standardempfehlung."
        ),
        "pros": [
            "Hervorragende Prompt-Treue, versteht Beziehungen zwischen Objekten",
            "Nur 4 Steps nötig — trotz Größe schnell",
            "Apache-2.0: keine Lizenzsorgen",
            "Brauchbarer Text im Bild",
        ],
        "cons": [
            "16 GB Download; ComfyUI lagert den Text-Encoder auf die CPU aus",
            "Erster Lauf nach dem Laden dauert spürbar länger",
            "Negative Prompts wirkungslos (CFG 1.0)",
            "Weniger LoRAs als für SDXL",
        ],
    },
    {
        "id": "z-image",
        "name": "Z-Image",
        "kind": "image",
        "family": "zimage",
        "workflow": "zimage",
        "files": [
            {"repo": "Comfy-Org/z_image",
             "file": "split_files/diffusion_models/z_image_bf16.safetensors",
             "target": "diffusion_models"},
            {"repo": "Comfy-Org/z_image",
             "file": "split_files/text_encoders/qwen_3_4b_fp8_mixed.safetensors",
             "target": "text_encoders"},
            {"repo": "Comfy-Org/z_image", "file": "split_files/vae/ae.safetensors",
             "target": "vae", "as": "flux_ae.safetensors"},
        ],
        "size_gb": 17.0,
        "vram_gb": 12,
        "license": "Apache-2.0",
        "commercial_ok": True,
        "best_for": "Prompt-Treue bei mittleren Karten — 6 B Parameter mit starkem Encoder",
        "description": (
            "Deutlich kleiner als Chroma (6 statt 8,9 Mrd. Parameter), hält sich aber "
            "sehr genau an lange Beschreibungen. Der Text-Encoder ist Qwen3-4B, also ein "
            "echtes Sprachmodell statt CLIP — mehrteilige Szenen werden dadurch "
            "zuverlässiger umgesetzt. Nicht CFG-destilliert, der negative Prompt wirkt "
            "also (cfg 4.0); die Turbo-Variante kann das nicht. Der VAE ist derselbe "
            "Flux-VAE wie bei Chroma und LongCat — ist eines davon installiert, "
            "entfallen 0,3 GB vom Download."
        ),
        "pros": [
            "Sehr gute Prompt-Treue bei einem Drittel der Parameter größerer Modelle",
            "Negativer Prompt wirkt (cfg 4.0)",
            "Apache-2.0",
            "Läuft auf 12-GB-Karten mit Reserve",
        ],
        "cons": [
            "Neuer und weniger erprobt als Chroma",
            "Kaum LoRAs im Umlauf",
            "Auf 8 GB passen Encoder und Modell nicht — dort die int8-Fassung nehmen",
        ],
    },
    {
        "id": "z-image-int8",
        "name": "Z-Image (int8, für kleine Karten)",
        "kind": "image",
        "family": "zimage",
        "workflow": "zimage",
        "files": [
            {"repo": "Comfy-Org/z_image",
             "file": "split_files/diffusion_models/z_image_int8_convrot.safetensors",
             "target": "diffusion_models"},
            {"repo": "Comfy-Org/z_image",
             "file": "split_files/text_encoders/qwen_3_4b_fp4_mixed.safetensors",
             "target": "text_encoders"},
            {"repo": "Comfy-Org/z_image", "file": "split_files/vae/ae.safetensors",
             "target": "vae", "as": "flux_ae.safetensors"},
        ],
        "size_gb": 9.3,
        "vram_gb": 7,
        "license": "Apache-2.0",
        "commercial_ok": True,
        "best_for": "Die Wahl für 8-GB-Karten — dasselbe Modell, stark quantisiert",
        "description": (
            "Dasselbe Modell wie `z-image`, aber in int8 statt bf16 und mit einem in "
            "fp4 quantisierten Text-Encoder: 9,3 GB Download statt 17, und der "
            "Speicherbedarf sinkt auf rund 7 GB. Damit läuft es auf einer 8-GB-Karte. "
            "Quantisierung kostet etwas Detailtreue — auf einer Karte, die die große "
            "Fassung nicht halten kann, ist das trotzdem der bessere Handel: ein Modell "
            "im Speicher ist um ein Vielfaches schneller als eines, das bei jedem "
            "Schritt nachgeladen wird."
        ),
        "pros": [
            "Läuft auf 8 GB VRAM",
            "Nur 9,3 GB Download",
            "Negativer Prompt wirkt",
            "Apache-2.0",
        ],
        "cons": [
            "Leichter Qualitätsverlust gegenüber der bf16-Fassung",
            "int8/fp4 setzt eine hinreichend neue Karte voraus (ab RTX 40)",
        ],
    },
    {
        "id": "qwen-image-2512-lightning",
        "name": "Qwen-Image-2512 (NVFP4, Lightning 8 Schritte)",
        "kind": "image",
        "family": "qwenimage",
        "workflow": "qwen_image_lightning",
        "files": [
            # Community-Quantisierung in ComfyUIs eigenem NVFP4-Format, laeuft ohne
            # Zusatz-Node. v2 haelt einige Schichten in bf16 -- laut Ersteller an Kanten
            # und Haaren deutlich sauberer als v1 (11,6 GB).
            {"repo": "Hippotes/Qwen-Image-2512-quants",
             "file": "qwen-image-2512-nvfp4-v2.safetensors",
             "target": "diffusion_models"},
            {"repo": "Comfy-Org/Qwen-Image_ComfyUI",
             "file": "split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors",
             "target": "text_encoders"},
            {"repo": "Comfy-Org/Qwen-Image_ComfyUI",
             "file": "split_files/vae/qwen_image_vae.safetensors", "target": "vae"},
            {"repo": "lightx2v/Qwen-Image-2512-Lightning",
             "file": "Qwen-Image-2512-Lightning-8steps-V1.0-bf16.safetensors",
             "target": "loras"},
        ],
        "size_gb": 25.4,
        "vram_gb": 14,
        "license": "Apache-2.0",
        "commercial_ok": True,
        "best_for": "Schnelle Entwürfe mit dem stärksten Apache-Modell — Endassets mit 50 Schritten",
        "features": {
            "text_rendering": True, "sizes": QWEN_NATIVE_SIZES,
            "prompt_hint": QWEN_PROMPT_HINT + " Der Negativprompt wirkt hier nicht (cfg 1) — "
                           "Ausschlüsse positiv formulieren.",
            "placeholder": QWEN_PLACEHOLDER,
        },
        "description": (
            "Qwen-Image-2512 hat 20 Mrd. Parameter und ist das bestplatzierte offene "
            "Bildmodell mit Apache-Lizenz (Arena-Elo 999, Stand Oktober 2026). In bf16 "
            "wären das 41 GB — hier in NVFP4 sind es 14,9 GB, und RTX-50-Karten rechnen "
            "dieses Format in Hardware.\n\n"
            "Die Lightning-LoRA verkürzt das Sampling von 50 auf 8 Schritte bei cfg 1. "
            "Der negative Prompt wirkt dadurch nicht mehr; Ausschlüsse positiv "
            "formulieren oder die volle Fassung `qwen-image-2512-nvfp4` nehmen. Beide "
            "teilen sich dieselben Dateien.\n\n"
            "Text-Encoder ist Qwen2.5-VL-7B, ein echtes Sprachmodell: lange, mehrteilige "
            "Beschreibungen und Schrift im Bild gelingen deutlich zuverlässiger als mit "
            "CLIP. Native Auflösung ist 1328 × 1328; die ~1-MP-Formate aus der "
            "Formattabelle funktionieren ebenfalls.\n\n"
            "Gemessen auf einer RTX 5060 Ti mit PyTorch cu130: rund 17 s pro Bild bei "
            "1024 × 1024, beim ersten Lauf nach dem Start 28 s. `batch_size=4` lohnt sich: "
            "40 s für vier Bilder."
        ),
        "pros": [
            "Apache-2.0, bestplatziertes offenes Modell mit kommerzieller Lizenz",
            "8 statt 50 Schritte",
            "NVFP4: 20 Mrd. Parameter in 14,9 GB statt 41 GB",
            "Qwen2.5-VL als Encoder: lange Prompts, Schrift im Bild",
        ],
        "cons": [
            "Verliert konstruktive Details: Bei gleichem Seed lagen die Seilgriffe einer "
            "Kiste ohne Bohrung lose auf dem Holz, die 50-Schritt-Fassung führte sie durch "
            "Löcher",
            "Negativer Prompt wirkungslos (cfg 1.0)",
            "Community-Quantisierung, kein offizielles Release — leichter Qualitätsverlust "
            "gegenüber bf16",
            "Encoder (9,4 GB) und Modell (14,9 GB) passen nicht gleichzeitig in 16 GB — "
            "jeder neue Prompt zahlt einen Nachlade-Zyklus",
            "Braucht PyTorch cu130 im ComfyUI-venv — mit cu128 dauert jedes Bild dreimal so "
            "lang (gemessen 50 statt 17 s)",
        ],
    },
    {
        "id": "qwen-image-2512-nvfp4",
        "name": "Qwen-Image-2512 (NVFP4, volle 50 Schritte)",
        "kind": "image",
        "family": "qwenimage",
        "workflow": "qwen_image",
        "files": [
            {"repo": "Hippotes/Qwen-Image-2512-quants",
             "file": "qwen-image-2512-nvfp4-v2.safetensors",
             "target": "diffusion_models"},
            {"repo": "Comfy-Org/Qwen-Image_ComfyUI",
             "file": "split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors",
             "target": "text_encoders"},
            {"repo": "Comfy-Org/Qwen-Image_ComfyUI",
             "file": "split_files/vae/qwen_image_vae.safetensors", "target": "vae"},
        ],
        "size_gb": 24.5,
        "model_gb": 14.9,
        "vram_gb": 14,
        "license": "Apache-2.0",
        "commercial_ok": True,
        "best_for": "Endassets — konstruktive Details stimmen deutlich besser als bei Lightning",
        "features": {
            "text_rendering": True, "sizes": QWEN_NATIVE_SIZES,
            "prompt_hint": QWEN_PROMPT_HINT + " Ohne eigenen Negativprompt gilt der aus "
                           "Qwens Modellkarte.",
            "placeholder": QWEN_PLACEHOLDER,
        },
        "description": (
            "Dasselbe Modell wie `qwen-image-2512-lightning`, aber ohne Destillation: "
            "50 Schritte bei cfg 4.0. Das kostet ein Vielfaches an Zeit, dafür wirkt der "
            "negative Prompt, und Texturen bleiben näher am unquantisierten Original. "
            "Gemessen auf einer RTX 5060 Ti mit PyTorch cu130: rund 93 s pro Bild bei "
            "1024 × 1024. Unter cu128 waren es 500 s.\n\n"
            "Bei gleichem Seed deutlich besser als Lightning: Die Seilgriffe der Testkiste "
            "liefen durch Bohrungen und unter die Leisten, statt ohne Halt auf dem Holz zu "
            "liegen. Für Endassets diese Fassung nehmen, Lightning nur für Entwürfe.\n\n"
            "Qwens Modellkarte empfiehlt als Negativprompt: `低分辨率，低画质，肢体畸形，"
            "手指畸形，画面过饱和，蜡像感，人脸无细节，过度光滑，画面具有AI感。构图混乱。"
            "文字模糊，扭曲` (niedrige Auflösung, deformierte Glieder und Finger, "
            "übersättigt, wächsern, zu glatt, KI-Look, wirre Komposition, verzerrte Schrift)."
        ),
        "pros": [
            "Konstruktiv stimmiger als Lightning: Seilgriffe mit Bohrungen statt lose aufgelegt",
            "Negativer Prompt wirkt (cfg 4.0)",
            "Keine Destillation — näher am Original",
            "Apache-2.0",
            "Teilt alle Dateien mit der Lightning-Fassung",
        ],
        "cons": [
            "50 Schritte mit je zwei Durchgängen — ein Vielfaches der Lightning-Zeit",
            "Encoder und Modell passen nicht gleichzeitig in 16 GB",
        ],
    },
    {
        "id": "qwen-image-2512-int8",
        "name": "Qwen-Image-2512 (INT8, für RTX 20/30/40)",
        "kind": "image",
        "family": "qwenimage",
        "workflow": "qwen_image",
        "files": [
            # Mit Comfy-Orgs eigenem Werkzeug quantisiert (comfy-quants, int8 tensorwise mit ConvRot,
            # dieselbe Schichtauswahl wie die offiziellen Exporte). Laeuft ohne Zusatz-Node ab ComfyUI
            # 0.27 und rechnet auf jeder NVIDIA-Karte ab RTX 20 in Hardware. Community-Upload; eine
            # bytegleiche Kopie liegt unter wazimondo/Qwen-Image-2512-int8-tensorwise.
            {"repo": "LAXMAYDAY/Qwen-Image-2512-int8-tensorwise",
             "file": "qwen-image-2512-int8-tensorwise.safetensors",
             "target": "diffusion_models"},
            {"repo": "Comfy-Org/Qwen-Image_ComfyUI",
             "file": "split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors",
             "target": "text_encoders"},
            {"repo": "Comfy-Org/Qwen-Image_ComfyUI",
             "file": "split_files/vae/qwen_image_vae.safetensors", "target": "vae"},
        ],
        "size_gb": 30.2,
        "model_gb": 20.56,
        "vram_gb": 16,
        "license": "Apache-2.0",
        "commercial_ok": True,
        "best_for": "Qwen-Image-2512 auf Karten ohne FP4 (RTX 20/30/40)",
        "features": {
            "text_rendering": True, "sizes": QWEN_NATIVE_SIZES,
            "prompt_hint": QWEN_PROMPT_HINT + " Ohne eigenen Negativprompt gilt der aus "
                           "Qwens Modellkarte.",
            "placeholder": QWEN_PLACEHOLDER,
        },
        "description": (
            "Dasselbe Modell wie `qwen-image-2512-nvfp4` (50 Schritte, cfg 4), aber in INT8 statt "
            "NVFP4. INT8 rechnet auf jeder NVIDIA-Karte ab RTX 20 in Hardware; NVFP4 nur auf RTX 50, "
            "auf älteren Karten wird es Schicht für Schicht entpackt und ist deutlich langsamer.\n\n"
            "Quantisiert mit Comfy-Orgs Werkzeug comfy-quants (int8 tensorwise mit ConvRot), läuft "
            "ohne Zusatz-Node. Die Datei ist 20,6 GB groß; auf Karten mit weniger Speicher lädt "
            "ComfyUI Teile aus dem Arbeitsspeicher nach.\n\n"
            "Gemessen auf einer RTX 5060 Ti (16 GB) bei 1024 × 1024: 119 s pro Bild, mit Laden "
            "132 s (NVFP4 dort 101 bzw. 108 s). Die Testkiste kam gleichwertig: Schrift "
            "buchstabengenau, Seilgriffe durch Bohrungen.\n\n"
            "Auf einer RTX 4060 mit 8 GB (am Riser, PCIe 3.0 x4) gemessen: 653 s samt Laden, die "
            "NVFP4-Fassung dort 1095 s. Keine der beiden passt in 8 GB, INT8 rechnet aber in Hardware. "
            "Schrift und Seilgriffe auch hier sauber.\n\n"
            "Alles Weitere — Prompt-Regeln, Negativprompt, native Formate — wie bei der NVFP4-Fassung."
        ),
        "pros": [
            "Rechnet auf RTX 20/30/40 in Hardware",
            "RTX 4060 (8 GB): 653 statt 1095 s mit NVFP4",
            "Negativer Prompt wirkt (cfg 4.0)",
            "Apache-2.0",
            "Teilt Text-Encoder und VAE mit den NVFP4-Fassungen",
        ],
        "cons": [
            "20,6 GB statt 14,9 GB: auf 16 GB und weniger lädt ComfyUI Teile nach",
            "Auf RTX 50 ist die NVFP4-Fassung die schnellere Wahl",
            "Community-Upload, keine offizielle Fassung von Qwen oder Comfy-Org",
        ],
    },
    {
        "id": "qwen-image-2.1-int8",
        "name": "Qwen-Image 2.1 (INT8, 25 Schritte) — nicht kommerziell",
        "kind": "image",
        "family": "qwenimage21",
        "workflow": "qwen_image21",
        "files": [
            {"repo": "Comfy-Org/Qwen-Image-2.1",
             "file": "diffusion_models/qwen_image_2.1_int8_convrot.safetensors",
             "target": "diffusion_models"},
            {"repo": "Comfy-Org/Qwen-Image-2.1",
             "file": "text_encoders/qwen3vl_8b_int8_convrot.safetensors",
             "target": "text_encoders"},
            {"repo": "Comfy-Org/Qwen-Image-2.1",
             "file": "vae/qwen_image_2.1_vae_bf16.safetensors", "target": "vae"},
        ],
        "size_gb": 17.29,
        "vram_gb": 12,
        "license": "Qwen Research License",
        "commercial_ok": False,
        "warning": QWEN21_LICENSE_WARNING,
        "best_for": "Ausprobieren: Bearbeiten mit bis zu zehn Referenzbildern, Schrift — nur "
                    "nicht kommerziell",
        "features": {
            "references": 10, "img2img": False, "mask": False, "hires": False,
            "text_rendering": True, "sizes": QWEN21_SIZES,
            "prompt_hint": QWEN_PROMPT_HINT + " Referenzbilder heißen im Prompt <image1>, "
                           "<image2> usw.; das erste ist das Bild, das bearbeitet wird.",
            "placeholder": QWEN_PLACEHOLDER,
        },
        "description": (
            "Qwen (Alibaba), September 2026. Nachfolger von Qwen-Image-2512 mit 7 Mrd. "
            "Parametern im Bildteil und Qwen3-VL-8B als Text-Encoder. Ein Modell für Text "
            "zu Bild und Bearbeiten: bis zu zehn Referenzbilder, laut Qwen auch durchsichtige "
            "Bilder (RGBA) und bessere Schrift. Diese Fassung ist ComfyUIs INT8-Paket, "
            "Einstellungen wie in ComfyUIs Vorlage: 25 Schritte, cfg 1 — der Negativprompt "
            "wirkt deshalb nicht.\n\n"
            "Gemessen auf der RTX 5060 Ti: 1024² in 26 s, 1344 × 1792 in 64 s, erster Lauf "
            "mit Laden 109 s; Bearbeiten mit einem Referenzbild 34–38 s. Text zu Bild im Test "
            "sehr sauber, Schrift buchstabengenau. Beim Bearbeiten blieben Form und Schrift "
            "erhalten, das Ergebnis wirkte aber überzeichnet (harter Kontrast, körniger "
            "Hintergrund) — auch mit 50 Schritten und genau ComfyUIs Vorlagengraph.\n\n"
            "**Nur für nicht-kommerzielle Zwecke.** Die Qwen Research License erlaubt "
            "Forschung und Evaluation; jede kommerzielle Nutzung, also auch Bilder für ein "
            "verkauftes Spiel, braucht eine eigene Lizenz von Alibaba. Für Endassets "
            "Qwen-Image-2512 (Apache-2.0) oder FLUX 3 nehmen."
        ),
        "pros": [
            "Bearbeiten mit bis zu zehn Referenzbildern",
            "Schrift im Bild",
            "Kleiner als Qwen-Image-2512: 7 statt 20 Mrd. Parameter im Bildteil",
        ],
        "cons": [
            "Qwen Research License: nur nicht kommerziell — nicht für Assets im verkauften Spiel",
            "cfg 1: der Negativprompt wirkt nicht",
            "Bearbeiten wirkt im Test überzeichnet: harter Kontrast, körniger Hintergrund",
        ],
    },
    {
        "id": "flux3-klein-nvfp4",
        "name": "FLUX 3 Image Klein (NVFP4, 16 Schritte)",
        "kind": "image",
        "family": "flux3",
        "workflow": "flux3_klein",
        "files": [
            # Offizielle NVFP4-Fassung von BFL. Repo ist gated: Lizenz auf Hugging Face
            # akzeptieren und Token hinterlegen (hf auth login), sonst 401.
            {"repo": "black-forest-labs/flux-3-image-klein-comfy",
             "file": "diffusion_models/flux3-image-klein-nvfp4.safetensors",
             "target": "diffusion_models"},
            *FLUX3_FILES_SHARED,
        ],
        "size_gb": 20.23,
        "model_gb": 5.28,
        "vram_gb": 12,
        "license": "FLUX Kommunity License v1.0",
        "commercial_ok": True,
        "warning": FLUX3_LICENSE_WARNING,
        "best_for": "Bearbeiten mit Referenzbildern, gleichbleibende Figuren, Platzierung per Box — schnell",
        "description": (
            "Black Forest Labs, Oktober 2026. 5,6 Mrd. Parameter, Text-Encoder Qwen3-VL-4B. "
            "Ein Modell für Text-zu-Bild und Bearbeitung: bis zu zehn Referenzbilder, im "
            "Prompt als „the first image“, „the second image“ angesprochen. Damit lassen "
            "sich Figuren über mehrere Bilder gleich halten, Teile ersetzen oder Motive "
            "kombinieren — das kann sonst keines der Modelle hier.\n\n"
            "Die destillierte Fassung ist BFLs Produktionsmodell (dieselbe wie hinter ihrer "
            "API): 16 Schritte ohne Guidance, der negative Prompt wirkt deshalb nicht.\n\n"
            "Vor jedem Bild baut ein mitgelieferter Upsampler (Qwen3.5-9B) den Prompt zur "
            "vollen Bildbeschreibung aus — BFL zufolge ist das Modell genau darauf trainiert, "
            "und kurze Prompts ergäben sonst generische Bilder. Die ausgebaute Beschreibung "
            "steht im Asset unter „caption“. Wiederholte Prompts nimmt NVAI-open aus dem "
            "Zwischenspeicher.\n\n"
            "Elemente lassen sich per Bounding-Box-Tabelle am Prompt-Ende platzieren "
            "([oben, links, unten, rechts] auf einem 0–1000-Raster). Die Boxen lenken Lage "
            "und Größe, sind aber keine harte Maske.\n\n"
            "Gemessen auf einer RTX 5060 Ti (NVFP4, cu130, ComfyUI 0.41.3) bei 1024 × 1024: "
            "neuer Prompt rund 30 s (Upsampler 8–15 s, Bild 12 s), derselbe Prompt mit neuem "
            "Seed 13–16 s, vier Bilder 37 s, 1440 × 1440 in 26 s, Bearbeiten mit einem "
            "Referenzbild 45 s.\n\n"
            "Im Test: Schrift dreimal von drei fehlerfrei („MUNITION 7,92“), fünf von fünf "
            "Soldaten vollständig mit Füßen, drei Kisten genau an den Box-Positionen, und beim "
            "Bearbeiten blieb die Vorlage bis auf die Griffe unverändert. Schwächen: Ohne "
            "Stilangabe plant der Upsampler ein Foto, und was der Prompt offen lässt, erfindet "
            "er — den Soldaten hängte er einen Mantel wie einen Umhang über den Rücken, "
            "Seilgriffe hingen lose über die Front statt eine Schlaufe zu bilden. Was zählt, "
            "ausdrücklich vorgeben und die `caption` prüfen. Konstruktion löst Qwen-Image-2512 "
            "mit 50 Schritten zuverlässiger.\n\n"
            "Lizenz: FLUX Kommunity License — siehe Warnhinweis."
        ),
        "features": {
            "upsampler": True, "references": 10, "bbox": True,
            # Ein Startbild wird zur Referenz (jobs.py); angerauschtes img2img und der
            # zweite Durchgang passen nicht zur Flow-Map der destillierten Fassung.
            "img2img": False, "hires": False, "text_rendering": True,
            "sizes": FLUX3_LARGE_SIZES,
            "prompt_hint": FLUX3_PROMPT_HINT + " Der Negativprompt wirkt hier nicht (cfg 1).",
            "placeholder": FLUX3_PLACEHOLDER,
        },
        "pros": [
            "Bearbeiten mit Referenzbild: Vorlage blieb im Test bis auf die geänderten Griffe "
            "unverändert",
            "Bis zu 10 Referenzbilder: Figuren konsistent halten, Motive kombinieren",
            "Box-Platzierung traf im Test alle drei Positionen",
            "Schnell: 13–16 s pro Bild bei bekanntem Prompt, rund 30 s bei neuem",
            "Schrift im Test dreimal von drei fehlerfrei",
            "Offizielle NVFP4-Fassung von BFL, rechnet auf RTX 50 in Hardware",
        ],
        "cons": [
            "Kommunity-Lizenz statt Apache: Umsatzgrenze, Prüfpflicht, jederzeit kündbar",
            "Upsampler erfindet, was offen bleibt (Mantel als Umhang, lose hängende Seile) — "
            "Wichtiges ausdrücklich vorgeben",
            "Seilgriffe im Test dreimal ohne sinnvolle Befestigung — Konstruktion kann Qwen 50 "
            "besser",
            "Ohne Stilangabe fotorealistisch",
            "Negativer Prompt wirkungslos (destilliert, cfg 1)",
            "Repo gated: Lizenz auf Hugging Face akzeptieren und Token hinterlegen",
        ],
    },
    {
        "id": "flux3-klein-int8",
        "name": "FLUX 3 Image Klein (INT8, für RTX 20/30/40)",
        "kind": "image",
        "family": "flux3",
        "workflow": "flux3_klein",
        "files": [
            # BFLs offizielle INT8-Fassung (convrot). Rechnet nativ auf allen NVIDIA-Karten
            # ab RTX 20; NVFP4 dagegen nur auf RTX 50 in Hardware. Repo gated wie oben.
            {"repo": "black-forest-labs/flux-3-image-klein-comfy",
             "file": "diffusion_models/flux3-image-klein-int8-convrot.safetensors",
             "target": "diffusion_models"},
            *FLUX3_FILES_SMALL,
        ],
        "size_gb": 17.75,
        "model_gb": 5.83,
        # BFL: laeuft auf 8-GB-Karten wie der RTX 3070 -- auf 8 GB also "knapp" (gpu.fits)
        "vram_gb": 6.5,
        "license": "FLUX Kommunity License v1.0",
        "commercial_ok": True,
        "warning": FLUX3_LICENSE_WARNING,
        "best_for": "FLUX 3 auf Karten ohne FP4 (RTX 20/30/40) und ab 8 GB Grafikspeicher",
        "description": (
            "Dasselbe Modell wie FLUX 3 Image Klein (NVFP4), aber in BFLs INT8-Fassung. "
            "INT8 rechnet auf jeder NVIDIA-Karte ab RTX 20 in Hardware; NVFP4 nur auf RTX 50 — "
            "auf älteren Karten wird es Schicht für Schicht entpackt und ist deutlich langsamer.\n\n"
            "Wie in BFLs eigener INT8-Vorlage mit dem kleineren Upsampler (w4a8, 6,7 statt "
            "9,8 GB). Laut BFL läuft diese Fassung auf 8-GB-Karten wie der RTX 3070 und auf "
            "einer RTX 4070 in unter 9 s pro Bild (16 Schritte, 1 Megapixel). Von uns noch "
            "nicht gemessen.\n\n"
            "Alles Weitere — Referenzbilder, Box-Platzierung, Upsampler, Prompt-Regeln — wie "
            "bei der NVFP4-Fassung.\n\n"
            "Lizenz: FLUX Kommunity License — siehe Warnhinweis."
        ),
        "features": {
            "upsampler": True, "references": 10, "bbox": True,
            "img2img": False, "hires": False, "text_rendering": True,
            "sizes": FLUX3_LARGE_SIZES,
            "prompt_hint": FLUX3_PROMPT_HINT + " Der Negativprompt wirkt hier nicht (cfg 1).",
            "placeholder": FLUX3_PLACEHOLDER,
        },
        "pros": [
            "Läuft auf RTX 20/30/40 in Hardware, laut BFL schon mit 8 GB Grafikspeicher",
            "Referenzbilder, Box-Platzierung und Upsampler wie die NVFP4-Fassung",
            "3 GB kleinerer Upsampler (w4a8), wie in BFLs INT8-Vorlage",
        ],
        "cons": [
            "Kommunity-Lizenz statt Apache: Umsatzgrenze, Prüfpflicht, jederzeit kündbar",
            "Auf RTX 50 ist die NVFP4-Fassung die schnellere Wahl",
            "Von uns noch nicht gemessen — Zeiten und Qualität stammen von BFL",
            "Repo gated: Lizenz auf Hugging Face akzeptieren und Token hinterlegen",
        ],
    },
    {
        "id": "flux3-klein-base-nvfp4",
        "name": "FLUX 3 Image Klein Base (NVFP4, 50 Schritte)",
        "kind": "image",
        "family": "flux3",
        "workflow": "flux3_klein_base",
        "files": [
            {"repo": "black-forest-labs/flux-3-image-klein-comfy",
             "file": "diffusion_models/flux3-image-klein-base-nvfp4.safetensors",
             "target": "diffusion_models"},
            *FLUX3_FILES_SHARED,
        ],
        "size_gb": 20.21,
        "vram_gb": 12,
        "license": "FLUX Kommunity License v1.0",
        "commercial_ok": True,
        "warning": FLUX3_LICENSE_WARNING,
        "best_for": "FLUX 3 mit wirksamem Negativprompt — undestilliert, 50 Schritte",
        "description": (
            "Dasselbe Modell wie `flux3-klein-nvfp4`, aber undestilliert: 50 Schritte mit "
            "CFG 3,5, je Schritt zwei Durchgänge. BFL bietet diese Fassung vor allem für "
            "Feintuning und LoRA-Training an; dafür wirkt hier der negative Prompt.\n\n"
            "Teilt Text-Encoder, Upsampler und VAE mit der destillierten Fassung — "
            "zusätzlich sind nur 5,3 GB zu laden.\n\n"
            "Gemessen: 53 s bei 1024 × 1024 (1,09 Schritte pro Sekunde mit CFG). Im Test ohne "
            "erkennbaren Vorteil gegenüber der destillierten Fassung — bei derselben "
            "Beschreibung hingen die Seilgriffe ebenso lose."
        ),
        "features": {
            "upsampler": True, "references": 10, "bbox": True,
            "img2img": False, "hires": False, "text_rendering": True,
            "sizes": FLUX3_LARGE_SIZES,
            "prompt_hint": FLUX3_PROMPT_HINT + " Der Negativprompt wirkt (cfg 3,5).",
            "placeholder": FLUX3_PLACEHOLDER,
        },
        "pros": [
            "Negativer Prompt wirkt (CFG 3,5)",
            "Undestilliert — Grundlage für eigene LoRAs",
            "Teilt alle Zusatzdateien mit der destillierten Fassung",
        ],
        "cons": [
            "Kommunity-Lizenz statt Apache: Umsatzgrenze, Prüfpflicht, jederzeit kündbar",
            "53 statt 13 s pro Bild — im Test ohne sichtbaren Gewinn",
            "BFL nennt als Produktionsmodell die destillierte Fassung",
        ],
    },
    {
        "id": "krea2-turbo-nvfp4",
        "name": "Krea 2 Turbo (NVFP4, 8 Schritte)",
        "kind": "image",
        "family": "krea2",
        "workflow": "krea2_turbo",
        "files": [
            {"repo": "Comfy-Org/Krea-2", "file": "diffusion_models/krea2_turbo_nvfp4.safetensors",
             "target": "diffusion_models"},
            *KREA2_FILES_SHARED,
        ],
        "size_gb": 12.8,
        "model_gb": 7.67,
        "vram_gb": 10,
        "license": "Krea 2 Community License",
        "commercial_ok": True,
        "warning": KREA2_LICENSE_WARNING,
        "best_for": "Fotografische, ästhetische Bilder mit wenig KI-Look — dritte Wahl nach Qwen und FLUX 3",
        "features": {
            "hires": False, "mask": False, "outpaint": None, "sizes": KREA2_SIZES,
            "with_optional": KREA2_WITH_OPTIONAL,
            "prompt_hint": KREA2_PROMPT_HINT, "placeholder": KREA2_PLACEHOLDER,
        },
        "description": (
            "Krea 2 von Krea.ai (Juni 2026): ein Diffusion-Transformer mit 12 Mrd. Parametern, offen "
            "veröffentlicht als Raw (zum Feintunen) und Turbo (destilliert, 8 Schritte, cfg 1). Krea ist "
            "für Bilder mit wenig KI-Look bekannt. Text-Encoder ist Qwen3-VL-4B, derselbe wie bei FLUX 3, "
            "der VAE ist der von Qwen-Image; wer eines der beiden Modelle hat, lädt nur noch 7,7 GB.\n\n"
            "Gemessen auf der RTX 5060 Ti (24.10.): rund 20 s je Bild mit 1 MP, erster Lauf mit Laden 41 s, "
            "1408 × 1408 (2 MP) 37 s; im selben Vergleich mit gleichem Prompt und Seed Qwen-Image-2512 "
            "109–160 s und FLUX 3 31–36 s. Krea wirkte am fotografischsten: Hände und Gesichter natürlich, "
            "die Kistenschrift buchstabengenau, die Seile laufen durch Bohrungen (die Kiste kam aber offen, "
            "einen Deckel nannte der Prompt nicht), die stehende Figur hat beide Stiefel im Bild. Beim alten Fischer, dessen Prompt die Hände betont, lag der Kopf in drei "
            "von drei Bildern oben außerhalb; mit „medium shot from the waist up, his whole head inside the "
            "frame“ in zwei von zwei im Bild.\n\n"
            "Stil-Referenz (seit 0.5.10): Mit der optionalen LoRA von ostris (0,46 GB, Krea-2-Lizenz; „Zusätze laden“ unter „Modelle“ holt sie) nimmt Krea 2 ein oder zwei Bilder als Stilvorlage. Malweise, Farben und Licht kommen aus dem Bild, der Inhalt aus dem Prompt. Gemessen: ein Leuchtturm mit einer Aquarell- bzw. Holzschnitt-Vorlage deutlich in deren Stil, 41–48 statt 24 s; mit beiden Vorlagen 71 s, dabei setzte sich die erste fast ganz durch.\n\n"
            "Ausgaben von 1 bis 2 MP. Der Negativprompt wirkt nicht (cfg 1). Kreas Vorlage baut kurze "
            "Prompts vorher aus; hier übernimmt das „Prompt ausbauen“.\n\n"
            "Lizenz: Krea 2 Community License — siehe Warnhinweis."
        ),
        "pros": [
            "Fotografischer Look, wenig KI-Glätte",
            "Gemessen rund 20 s je Bild (1 MP), 2 MP in 37 s",
            "Schrift im Bild buchstabengenau",
            "Stil-Referenz mit 1–2 Bildern (optionale LoRA, 0,46 GB)",
            "8 Schritte, NVFP4 nur 7,7 GB",
            "Teilt Text-Encoder und VAE mit FLUX 3 und Qwen-Image",
        ],
        "cons": [
            "Community-Lizenz: kommerziell nur unter 1 Mio. US-$ Umsatz, Prüfpflicht, kündbar",
            "Bildausschnitt ausdrücklich nennen, sonst schneidet es ab (Fischer: Kopf 3 von 3)",
            "Negativer Prompt wirkungslos (cfg 1)",
            "Referenzbilder nur als Stilvorlage; zum Bearbeiten bleibt FLUX 3",
        ],
    },
    {
        "id": "krea2-turbo-int8",
        "name": "Krea 2 Turbo (INT8, für RTX 20/30/40)",
        "kind": "image",
        "family": "krea2",
        "workflow": "krea2_turbo",
        "files": [
            {"repo": "Comfy-Org/Krea-2", "file": "diffusion_models/krea2_turbo_int8_convrot.safetensors",
             "target": "diffusion_models"},
            *KREA2_FILES_SHARED,
        ],
        "size_gb": 18.6,
        "model_gb": 13.49,
        "vram_gb": 16,
        "license": "Krea 2 Community License",
        "commercial_ok": True,
        "warning": KREA2_LICENSE_WARNING,
        "best_for": "Krea 2 auf Karten ohne FP4 (RTX 20/30/40)",
        "features": {
            "hires": False, "mask": False, "outpaint": None, "sizes": KREA2_SIZES,
            "with_optional": KREA2_WITH_OPTIONAL,
            "prompt_hint": KREA2_PROMPT_HINT, "placeholder": KREA2_PLACEHOLDER,
        },
        "description": (
            "Dasselbe Modell wie `krea2-turbo-nvfp4`, in Comfy-Orgs INT8-Fassung (ConvRot), die auf jeder "
            "NVIDIA-Karte ab RTX 20 in Hardware rechnet. 13,5 GB; auf Karten mit weniger Speicher lädt "
            "ComfyUI Teile aus dem Arbeitsspeicher nach. Die Prompt-Hinweise der NVFP4-Fassung gelten "
            "auch hier.\n\n"
            "Gemessen auf einer RTX 4060 mit 8 GB (am Riser, PCIe 3.0 x4), 1024 × 1024: erstes Bild 193 s, "
            "danach 82 s, Bild wie mit NVFP4 (Schrift genau). Die NVFP4-Fassung brauchte dort 46 s samt "
            "Laden: Sie passt mit 7,7 GB in den Grafikspeicher, die INT8-Fassung muss über den langsamen "
            "Anschluss nachgeladen werden. An einem normalen Anschluss (PCIe 4.0 x8, RTX 40 ohne FP4 "
            "nachgestellt) war INT8 dagegen doppelt so schnell: mit 8 GB 13 statt 25 s, mit 16 GB 12 statt "
            "25 s. NVAI-open empfiehlt deshalb INT8 und nur am langsamen Anschluss NVFP4.\n\n"
            "Lizenz: Krea 2 Community License — siehe Warnhinweis."
        ),
        "pros": [
            "Rechnet auf RTX 20/30/40 in Hardware",
            "Teilt Text-Encoder und VAE mit FLUX 3 und Qwen-Image",
        ],
        "cons": [
            "Community-Lizenz: kommerziell nur unter 1 Mio. US-$ Umsatz, Prüfpflicht, kündbar",
            "Auf RTX 50 ist die NVFP4-Fassung die schnellere Wahl",
            "Am langsamen Anschluss (PCIe 3.0 x4) langsamer als NVFP4 (RTX 4060 am Riser: 82 statt 46 s)",
        ],
    },
    {
        "id": "moss-image-sft-int8",
        "name": "MOSS-Image SFT (INT8, 50 Schritte)",
        "kind": "image",
        "family": "moss_image",
        "workflow": "moss_image",
        "files": MOSS_IMAGE_FILES,
        "size_gb": 13.0,
        "model_gb": 5.41,
        "vram_gb": 12,
        "license": "Apache-2.0",
        "commercial_ok": True,
        "best_for": "Schrift und Layout im Bild, Plakate und Grafiken — frei nutzbar (Apache-2.0)",
        "features": {
            "hires": False, "img2img": False, "mask": False, "outpaint": None, "upsampler": True,
            "text_rendering": True, "sizes": MOSS_IMAGE_SIZES,
            "prompt_hint": MOSS_IMAGE_PROMPT_HINT, "placeholder": MOSS_IMAGE_PLACEHOLDER,
        },
        "description": (
            "MOSS-Image von OpenMOSS (16.10.2026): ein Diffusion-Transformer mit 5 Mrd. Parametern unter "
            "Apache-2.0, trainiert auf ausführliche Bildbeschreibungen. Text-Encoder ist Qwen3.5-9B (W4A8), dazu "
            "kommt die kleine FLUX.2-VAE, die ebenfalls unter Apache-2.0 steht. Einen knappen Prompt baut NVAI-open "
            "vorher mit MOSS' eigenem Text-Encoder zur vollen Beschreibung aus (Systemprompt aus ComfyUIs Vorlage, "
            "abschaltbar); sie steht danach im Asset unter „caption“.\n\n"
            "Gemessen auf der RTX 5060 Ti (25.10.) mit OpenMOSS' Einstellung (50 Schritte, cfg 3, Vorgabe): rund "
            "51 s je Bild mit 1 MP, der Ausbau beim ersten Mal rund 11 s dazu; mit den 25 Schritten aus ComfyUIs "
            "Vorlage 28 s. Die Schrift kam in allen Tests buchstabengenau („MUNITION 7,92“, das Plakat "
            "„ALPENGLOW“ mit „SINCE 1928“), der Soldat stand mit beiden Stiefeln im Bild, der Fischer behielt "
            "den Kopf im Bild. Mit 50 Schritten liefen die Kistenseile in drei von drei Bildern durch Bohrungen, "
            "mit 25 Schritten in zwei von drei; einmal fehlte der Deckel (nicht im Prompt genannt).\n\n"
            "Auf dem Mac gibt es MOSS-Image nicht (keine MLX-Fassung)."
        ),
        "pros": [
            "Apache-2.0: Bilder ohne Umsatzgrenze und Prüfpflicht verkaufbar",
            "Schrift im Bild in Englisch und Chinesisch, auch lange Texte",
            "Layout per JSON: wo welches Objekt und welche Zeile steht",
            "Eigener Prompt-Ausbau (abschaltbar), Negativprompt wirkt",
        ],
        "cons": [
            "Nur Text zu Bild: keine Referenzbilder, kein Bearbeiten, keine Maske",
            "Text-Encoder Qwen3.5-9B: 7,3 GB zusätzlich (nicht derselbe wie der Upsampler von FLUX 3)",
            "Auf dem Mac nicht verfügbar (keine MLX-Fassung)",
        ],
    },
    {
        "id": "longcat-image",
        "name": "LongCat-Image",
        "kind": "image",
        "family": "longcat",
        "workflow": "longcat",
        "files": [
            {"repo": "Comfy-Org/LongCat-Image",
             "file": "split_files/diffusion_models/longcat_image_bf16.safetensors",
             "target": "diffusion_models"},
            # Beide liegen bereits auf der Platte: der Encoder kam mit HunyuanVideo 1.5,
            # der VAE mit Chroma. Die Dateien sind bitgleich mit denen, die ComfyUIs
            # LongCat-Template laedt (VAE sha256 afc8e282…) — der Download ueberspringt
            # sie deshalb und es bleiben nur 11,7 GiB fuer das Modell selbst.
            {"repo": "Comfy-Org/HunyuanVideo_1.5_repackaged",
             "file": "split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors",
             "target": "text_encoders"},
            {"repo": "lodestones/Chroma", "file": "ae.safetensors",
             "target": "vae", "as": "flux_ae.safetensors"},
        ],
        "size_gb": 21.4,
        "vram_gb": 12,
        "license": "Apache-2.0",
        "commercial_ok": True,
        "best_for": "Szenen mit mehreren Objekten und einer Handlung",
        "description": (
            "Flux-Architektur mit Qwen2.5-VL als Text-Encoder — dasselbe Sprachmodell, das "
            "auch HunyuanVideo 1.5 benutzt. Dadurch versteht es lange, mehrteilige "
            "Beschreibungen deutlich besser als ein CLIP-basiertes Modell, das den Prompt "
            "in 77-Token-Blöcke zerlegt.\n\n"
            "Nicht CFG-destilliert: der negative Prompt wirkt wirklich (cfg 4.0), anders "
            "als bei FLUX schnell.\n\n"
            "Von den 21,4 GB sind nur **11,7 GiB wirklich neu** — Text-Encoder und VAE "
            "liegen bereits von HunyuanVideo und Chroma auf der Platte und werden "
            "wiederverwendet."
        ),
        "pros": [
            "Nur ~11,7 GiB echter Download — Encoder und VAE sind schon da",
            "Qwen2.5-VL versteht lange Szenenbeschreibungen ohne 77-Token-Blöcke",
            "Negativer Prompt wirkt (cfg 4.0)",
            "Apache-2.0",
        ],
        "cons": [
            "Encoder (9,4 GB) und Modell (12,5 GB) passen nicht gleichzeitig in 16 GB — "
            "jeder Lauf zahlt einen Nachlade-Zyklus",
            "Neu und wenig erprobt; kaum LoRAs oder ControlNets im Umlauf",
            "Nur Text-zu-Bild in NVAI-open; die Edit-Variante ist nicht eingebunden",
        ],
    },
    {
        "id": "chroma1-hd-fp8",
        "name": "Chroma1-HD (fp8, passt in den Speicher)",
        "kind": "image",
        "family": "chroma",
        "workflow": "chroma",
        "files": [
            {"repo": "Comfy-Org/Chroma1-HD_repackaged",
             "file": "split_files/diffusion_models/Chroma1-HD-fp8mixed.safetensors",
             "target": "diffusion_models"},
            {"repo": "comfyanonymous/flux_text_encoders",
             "file": "t5xxl_fp8_e4m3fn_scaled.safetensors", "target": "text_encoders"},
            {"repo": "lodestones/Chroma", "file": "ae.safetensors",
             "target": "vae", "as": "flux_ae.safetensors"},
        ],
        "size_gb": 13.68,
        "vram_gb": 11,
        "license": "Apache-2.0",
        "commercial_ok": True,
        "best_for": "Erste Wahl für Szenenbilder — hält sich am besten an lange Prompts",
        "description": (
            "Dieselbe Chroma1-HD, aber in gemischtem fp8 statt bf16: 8,6 statt 16,6 GB. "
            "Das ist der entscheidende Unterschied auf einer 16-GB-Karte — die bf16-Datei "
            "passt physisch nicht hinein und muss bei jedem Sampling-Schritt über PCIe "
            "nachgeladen werden, was ein Bild von etwa 30 auf 110 Sekunden streckt.\n\n"
            "Inhaltlich unverändert: aus FLUX.1 schnell weiterentwickelt, Apache-2.0, ohne "
            "Inhaltsfilter, und mit funktionierendem negativem Prompt (anders als FLUX "
            "schnell, das CFG-destilliert ist). Genau die Datei, die ComfyUIs eigenes "
            "Chroma-Template lädt.\n\n"
            "Für narrative Szenen mit mehreren Objekten und einer Handlung war es im "
            "direkten Vergleich das treffsicherste der hier verfügbaren Modelle."
        ),
        "pros": [
            "Passt vollständig in den Speicher — rund dreimal schneller als die bf16-Fassung",
            "Negativer Prompt wirkt wirklich (cfg 4.0), anders als bei FLUX schnell",
            "Beste Prompt-Treue bei langen Szenenbeschreibungen im Testvergleich",
            "Apache-2.0, keine Inhaltsfilter",
        ],
        "cons": [
            "fp8 statt bf16 — minimaler Qualitätsverlust gegenüber der großen Datei",
            "Braucht mehr Schritte als FLUX schnell",
            "Community-Projekt ohne Support-Garantie",
        ],
    },
    {
        "id": "chroma1-hd",
        "name": "Chroma1-HD (bf16 — zu groß für 16 GB)",
        "kind": "image",
        "family": "chroma",
        "workflow": "chroma",
        "files": [
            {"repo": "lodestones/Chroma1-HD", "file": "Chroma1-HD.safetensors",
             "target": "diffusion_models"},
            {"repo": "comfyanonymous/flux_text_encoders",
             "file": "t5xxl_fp8_e4m3fn_scaled.safetensors", "target": "text_encoders"},
            {"repo": "lodestones/Chroma", "file": "ae.safetensors",
             "target": "vae", "as": "flux_ae.safetensors"},
        ],
        "size_gb": 21.69,
        "vram_gb": 17,
        "license": "Apache-2.0",
        "commercial_ok": True,
        "warning": "Passt mit 16,6 GB nicht in die Karte — nimm die fp8-Fassung",
        "best_for": "Nur mit mehr als 16 GB VRAM sinnvoll — sonst die fp8-Fassung nehmen",
        "description": (
            "Die volle bf16-Fassung. Inhaltlich identisch mit `chroma1-hd-fp8`, aber die "
            "Datei allein wiegt 16,6 GB und passt damit nicht in eine 16-GB-Karte. ComfyUI "
            "lädt sie dann bei jedem Sampling-Schritt stückweise über PCIe nach — gemessen "
            "rund 110 Sekunden pro Bild statt etwa 30.\n\n"
            "Nur behalten, wenn eine größere Karte im Spiel ist. Sonst ist "
            "`chroma1-hd-fp8` in jeder Hinsicht die bessere Wahl: gleiches Modell, "
            "8 GB weniger, dreifache Geschwindigkeit."
        ),
        "pros": [
            "Volle bf16-Genauigkeit ohne Quantisierungsverlust",
            "Apache-2.0, keine Inhaltsfilter",
        ],
        "cons": [
            "16,6 GB Modelldatei — passt nicht in 16 GB VRAM",
            "Dauerhaftes Nachladen über PCIe: etwa dreimal langsamer als fp8",
            "21,7 GB Download für ein Ergebnis, das die fp8-Fassung schneller liefert",
        ],
    },
    {
        "id": "pony-v6-xl",
        "name": "Pony Diffusion V6 XL",
        "kind": "image",
        "family": "sdxl",
        "workflow": "sdxl",
        "files": [{"repo": "LyliaEngine/Pony_Diffusion_V6_XL",
                   "file": "ponyDiffusionV6XL_v6StartWithThisOne.safetensors", "target": "checkpoints"}],
        "size_gb": 6.46,
        "vram_gb": 8,
        "license": "CDLA-Permissive-2.0",
        "commercial_ok": True,
        "best_for": "Charaktere und Kreaturen, ungefiltert, riesiges LoRA-Ökosystem",
        "description": (
            "Trotz des Namens ein breit einsetzbarer SDXL-Feintune und eine der meistgenutzten "
            "Basen der Szene — ein Großteil aller Charakter-LoRAs setzt darauf auf. Ungefiltert "
            "und sehr gut steuerbar über Qualitäts-Tags (score_9, score_8_up …), die man aber "
            "kennen muss. Für stilisierte Charaktere, Kreaturen und Monster stark."
        ),
        "pros": [
            "CDLA-Permissive-2.0 — eine der freizügigsten Lizenzen überhaupt",
            "Keine Inhaltsfilter",
            "Enormes LoRA-Ökosystem für Charaktere",
            "Nur 6,5 GB und ~8 GB VRAM",
        ],
        "cons": [
            "Eigene Prompt-Syntax mit score-Tags — ohne die sind Ergebnisse schlecht",
            "Ignoriert natürliche Sprache weitgehend",
            "Für realistische Environments ungeeignet",
        ],
    },
    {
        "id": "noobai-xl-v1.1",
        "name": "NoobAI-XL v1.1",
        "kind": "image",
        "family": "sdxl",
        "workflow": "sdxl",
        "files": [{"repo": "Laxhar/noobai-XL-1.1",
                   "file": "NoobAI-XL-v1.1.safetensors", "target": "checkpoints"}],
        "size_gb": 6.62,
        "vram_gb": 8,
        "license": "Fair AI Public License 1.0-SD",
        "commercial_ok": True,
        "best_for": "Stilisierte 2D-Assets ohne Filter, breiteres Wissen als Illustrious",
        "description": (
            "Auf Illustrious aufgebaut und deutlich weiter trainiert. Kennt mehr Charaktere, "
            "Stile und Konzepte als das Original und filtert nichts. Wenn Illustrious bei "
            "einem Motiv passt, aber inhaltlich ausweicht, ist das hier der direkte Ersatz."
        ),
        "pros": [
            "Ungefiltert bei gleichzeitig sehr guter Tag-Steuerung",
            "Größeres Konzeptwissen als Illustrious v0.1",
            "SDXL-kompatibel: LoRAs und ControlNets funktionieren",
        ],
        "cons": [
            "Tag-Syntax nötig (Danbooru-Stil)",
            "Fair-AI-Lizenz verlangt, dass abgeleitete Modelle offen bleiben",
            "Nicht für Fotorealismus",
        ],
    },
    {
        "id": "hidream-o1-dev-fp8",
        "name": "HiDream-O1-Image Dev (fp8, 28 Schritte)",
        "kind": "image",
        "family": "hidream_o1",
        "workflow": "hidream_o1_dev",
        "files": [{"repo": "Comfy-Org/HiDream-O1-Image",
                   "file": "checkpoints/hidream_o1_image_dev_fp8_scaled.safetensors",
                   "target": "checkpoints"}],
        "size_gb": 8.07,
        "vram_gb": 12,
        "license": "MIT",
        "commercial_ok": True,
        "best_for": "Große Bilder (4 MP), Bearbeiten mit Referenzbildern — MIT-Lizenz",
        "description": (
            "HiDream.ai, Mai 2026. 8 Mrd. Parameter, rechnet direkt im Pixelraum: Text-Encoder "
            "und Bildausgabe stecken in einer einzigen Datei, eine eigene VAE gibt es nicht. "
            "Auf rund 4 Megapixel trainiert (2048 × 2048 und ähnliche Formate); kleinere Bilder "
            "werden laut Hersteller deutlich schlechter.\n\n"
            "Die Dev-Fassung ist destilliert: 28 Schritte bei cfg 1, der negative Prompt wirkt "
            "deshalb nicht. Referenzbilder werden an den Prompt gehängt (Bearbeiten, Motive "
            "kombinieren).\n\n"
            "Gemessen auf einer RTX 5060 Ti (fp8, ComfyUI 0.42.1) bei 1728 × 2304: 41 s, beim "
            "ersten Bild mit ComfyUI-Start 87 s. Im Test ganze Figur mit beiden Stiefeln, saubere "
            "Hände; der „glatte graue“ Hintergrund wurde ein gefleckter Stoff. Bearbeiten mit "
            "Referenzbild (104 s) traf die Änderung, machte aber Farben flau und den Hintergrund "
            "dunkel — zum Bearbeiten ist Boogu-Image Edit besser.\n\n"
            "Werte aus ComfyUIs Vorlage image_hidream_o1_dev.json. MIT-Lizenz."
        ),
        "features": {
            "references": 4, "img2img": False, "mask": False, "hires": False,
            "sizes": HIDREAM_O1_SIZES,
            "prompt_hint": ("Ganze Sätze: Stil, Motiv, Material, Licht, Hintergrund. Für "
                            "Bearbeitungen sagen, was sich ändert und was bleibt. Format um "
                            "4 Megapixel wählen, darunter leidet die Qualität."),
        },
        "pros": ["MIT-Lizenz, kommerziell frei", "Eine Datei, 8 GB",
                 "Referenzbilder zum Bearbeiten und Kombinieren", "Nativ 4 Megapixel"],
        "cons": ["Unter 4 Megapixel deutlich schlechter (laut Hersteller)",
                 "Negativer Prompt wirkungslos (destilliert, cfg 1)",
                 "Zensur nicht dokumentiert"],
    },
    {
        "id": "hidream-o1-fp8",
        "name": "HiDream-O1-Image (fp8, 40 Schritte)",
        "kind": "image",
        "family": "hidream_o1",
        "workflow": "hidream_o1",
        "files": [{"repo": "Comfy-Org/HiDream-O1-Image",
                   "file": "checkpoints/hidream_o1_image_fp8_scaled.safetensors",
                   "target": "checkpoints"}],
        "size_gb": 8.07,
        "vram_gb": 12,
        "license": "MIT",
        "commercial_ok": True,
        "best_for": "Volle Qualität mit Negativprompt, 4 MP — langsamer als Dev",
        "description": (
            "Die volle, nicht destillierte Fassung von HiDream-O1-Image: 40 Schritte mit cfg 5, "
            "der negative Prompt wirkt. Dazu glättet ein eigener Knoten die Nähte zwischen den "
            "Bildkacheln. Sonst wie die Dev-Fassung: Pixelraum, eine Datei, rund 4 Megapixel, "
            "Referenzbilder.\n\n"
            "Gemessen auf einer RTX 5060 Ti bei 1728 × 2304: 142 s. Die Vorlage nimmt den Sampler "
            "dpmpp_2m_sde_gpu; mit der fp8-Datei zerfiel der Hintergrund dabei in Blöcke, NVAI-open "
            "nimmt deshalb euler (sauber).\n\n"
            "Werte aus ComfyUIs Vorlage image_hidream_o1.json, Sampler geändert. MIT-Lizenz."
        ),
        "features": {
            "references": 4, "img2img": False, "mask": False, "hires": False,
            "sizes": HIDREAM_O1_SIZES,
            "prompt_hint": ("Ganze Sätze: Stil, Motiv, Material, Licht, Hintergrund. Der "
                            "Negativprompt wirkt (cfg 5). Format um 4 Megapixel wählen."),
        },
        "pros": ["MIT-Lizenz", "Negativer Prompt wirkt (cfg 5)", "Referenzbilder", "Nativ 4 Megapixel"],
        "cons": ["40 Schritte bei 4 MP: deutlich langsamer als Dev", "Zensur nicht dokumentiert"],
    },
    {
        "id": "boogu-image-turbo-nvfp4",
        "name": "Boogu-Image 0.1 Turbo (NVFP4, 4 Schritte)",
        "kind": "image",
        "family": "boogu",
        "workflow": "boogu_turbo",
        "files": [{"repo": "Comfy-Org/Boogu-Image",
                   "file": "diffusion_models/boogu_image_turbo_hotfix_nvfp4.safetensors",
                   "target": "diffusion_models"}, *BOOGU_FILES_SHARED],
        "size_gb": 16.59,
        "vram_gb": 11,
        "license": "Apache-2.0",
        "commercial_ok": True,
        "best_for": "Schnelle Entwürfe in 4 Schritten — Apache-2.0",
        "description": (
            "Boogu, Juni 2026 (Forschungsprojekt, Version 0.1). 10 Mrd. Parameter mit Qwen3-VL-8B "
            "als Text-Encoder. Die Turbo-Fassung rechnet 4 Schritte bei cfg 1, der negative "
            "Prompt wirkt nicht. NVAI-open nimmt die korrigierte „hotfix“-Fassung.\n\n"
            "Gemessen auf einer RTX 5060 Ti bei 832 × 1216: 9,8 s, beim ersten Bild 17 s. Im Test "
            "ganze Figur, glatter grauer Hintergrund wie verlangt.\n\n"
            "Werte aus ComfyUIs Vorlage image_boogu_image_0_1_turbo_t2i.json. Apache-2.0."
        ),
        "features": {"references": 0, "img2img": False, "mask": False, "hires": False,
                     "prompt_hint": "Ganze Sätze: Stil, Motiv, Material, Licht, Hintergrund."},
        "pros": ["Apache-2.0", "4 Schritte", "NVFP4: Modell nur 5,8 GB"],
        "cons": ["Version 0.1, laut Hersteller Forschungsprojekt",
                 "Negativer Prompt wirkungslos (cfg 1)", "Text-Encoder 10,6 GB",
                 "Zensur nicht dokumentiert"],
    },
    {
        "id": "boogu-image-nvfp4",
        "name": "Boogu-Image 0.1 Base (NVFP4, 25 Schritte)",
        "kind": "image",
        "family": "boogu",
        "workflow": "boogu",
        "files": [{"repo": "Comfy-Org/Boogu-Image",
                   "file": "diffusion_models/boogu_image_base_nvfp4.safetensors",
                   "target": "diffusion_models"}, *BOOGU_FILES_SHARED],
        "size_gb": 16.59,
        "vram_gb": 11,
        "license": "Apache-2.0",
        "commercial_ok": True,
        "best_for": "Volle Qualität mit Negativprompt — Apache-2.0",
        "description": (
            "Die nicht destillierte Base-Fassung von Boogu-Image 0.1: 25 Schritte mit cfg 3,5, "
            "der negative Prompt wirkt. Text-Encoder und VAE teilt sie mit Turbo und Edit.\n\n"
            "Werte wie in ComfyUIs Vorlage image_boogu_image_0_1_edit.json (eine eigene "
            "Text-zu-Bild-Vorlage für Base gibt es nicht). Gemessen auf einer RTX 5060 Ti bei "
            "832 × 1216: 66 s. Apache-2.0."
        ),
        "features": {"references": 0, "img2img": False, "mask": False, "hires": False,
                     "prompt_hint": "Ganze Sätze: Stil, Motiv, Material, Licht, Hintergrund. Der Negativprompt wirkt."},
        "pros": ["Apache-2.0", "Negativer Prompt wirkt (cfg 3,5)"],
        "cons": ["Version 0.1, laut Hersteller Forschungsprojekt", "Zensur nicht dokumentiert"],
    },
    {
        "id": "boogu-image-edit-nvfp4",
        "name": "Boogu-Image 0.1 Edit (NVFP4, Bearbeiten)",
        "kind": "image",
        "family": "boogu",
        "workflow": "boogu",
        "files": [{"repo": "Comfy-Org/Boogu-Image",
                   "file": "diffusion_models/boogu_image_edit_nvfp4.safetensors",
                   "target": "diffusion_models"}, *BOOGU_FILES_SHARED],
        "size_gb": 16.59,
        "vram_gb": 11,
        "license": "Apache-2.0",
        "commercial_ok": True,
        "best_for": "Ein Bild nach Anweisung ändern — Apache-2.0",
        "description": (
            "Die Bearbeiten-Fassung von Boogu-Image 0.1: ein Referenzbild plus Anweisung "
            "(„remove the hat“, „make it winter“). Das Bild geht zweimal ein: als Bildverständnis "
            "für die Anweisung und als Referenz für den Inhalt. 25 Schritte, cfg 3,5.\n\n"
            "Gemessen auf einer RTX 5060 Ti bei 832 × 1216: rund 147 s. Im Test („Tropenhelm durch "
            "rote Baseballkappe ersetzen“) änderte es nur den Hut; Gesicht, Kleidung, Tasche, "
            "Stiefel und Hintergrund blieben gleich.\n\n"
            "Werte aus ComfyUIs Vorlage image_boogu_image_0_1_edit.json. Apache-2.0."
        ),
        "features": {"references": 4, "img2img": False, "mask": False, "hires": False,
                     "prompt_hint": ("Anweisung, was sich ändern soll, und was bleiben soll. "
                                     "Am besten ein Referenzbild; mehrere sind erlaubt.")},
        "pros": ["Apache-2.0-Alternative zum Bearbeiten mit FLUX 3", "Anweisung in Alltagssprache"],
        "cons": ["Braucht ein Referenzbild", "Version 0.1, laut Hersteller Forschungsprojekt",
                 "Zensur nicht dokumentiert"],
    },
    {
        "id": "sdxl-vae-fp16",
        "name": "SDXL VAE (fp16-fix)",
        "kind": "image",
        "family": "sdxl",
        "workflow": None,
        "files": [{"repo": "madebyollin/sdxl-vae-fp16-fix",
                   "file": "sdxl_vae.safetensors", "target": "vae"}],
        "size_gb": 0.31,
        "vram_gb": 0,
        "license": "MIT",
        "commercial_ok": True,
        "best_for": "Zubehör: behebt Artefakte bei SDXL-Feintunes",
        "description": (
            "Kein eigenständiges Modell, sondern ein Ersatz-VAE. Hilft, wenn SDXL-Feintunes "
            "schwarze Flächen oder Farbstiche produzieren."
        ),
        "pros": ["Winzig", "Behebt bekannte fp16-Artefakte"],
        "cons": ["Allein nutzlos — nur in Kombination mit einem SDXL-Checkpoint"],
    },
]

# --------------------------------------------------------------- AUDIO

AUDIO_MODELS: list[dict[str, Any]] = [
    {
        "id": "stable-audio-open-1.0",
        "name": "Stable Audio Open 1.0",
        "kind": "audio",
        "family": "stable_audio",
        "workflow": "stable_audio",
        "files": [
            {"repo": "Comfy-Org/stable-audio-open-1.0_repackaged",
             "file": "stable-audio-open-1.0.safetensors", "target": "checkpoints"},
            # Der Checkpoint enthaelt keinen Text-Encoder -- ComfyUI erwartet ihn
            # separat unter dem Namen t5_base.safetensors.
            {"repo": "google-t5/t5-base", "file": "model.safetensors",
             "target": "text_encoders", "as": "t5_base.safetensors"},
        ],
        "size_gb": 5.41,
        "vram_gb": 6,
        "license": "Stability AI Community License",
        "commercial_ok": True,
        "best_for": "Soundeffekte und Ambient-Loops — der Game-Dev-Fall",
        "description": (
            "Auf Soundeffekte und Klanglandschaften trainiert, nicht auf Songs. Genau das, "
            "was man beim Spielebau ständig braucht: Schritte auf Kies, Schwerthieb, "
            "Türknarren, Regen, Lagerfeuer, Menschenmenge. Erzeugt bis zu 47 Sekunden bei "
            "44,1 kHz Stereo. Beschreibe den Klang, nicht die Musik."
        ),
        "pros": [
            "Klar der beste Kandidat für SFX und Ambience",
            "Nur ~6 GB VRAM, läuft nebenher",
            "47 s am Stück reichen für Loops",
            "Eine Datei, keine Zusatz-Encoder",
        ],
        "cons": [
            "Kann keine Musik mit Struktur und keinen Gesang",
            "Community License mit 1-Mio.-USD-Umsatzgrenze",
            "Ergebnisse brauchen oft Nachbearbeitung (Schnitt, Loop-Punkte)",
        ],
    },
    {
        "id": "stable-audio-3-medium",
        "name": "Stable Audio 3 Medium",
        "kind": "audio",
        "family": "stable_audio3",
        "workflow": "stable_audio_3",
        "files": [
            {"repo": "Comfy-Org/stable-audio-3",
             "file": "checkpoints/stable_audio_3_medium.safetensors", "target": "checkpoints"},
            # Text-Encoder T5Gemma separat, wie in ComfyUIs Vorlage audio_stable_audio_3_medium
            {"repo": "Comfy-Org/stable-audio-3",
             "file": "text_encoders/t5gemma_b_b_ul2.safetensors", "target": "text_encoders"},
        ],
        "size_gb": 10.41,
        "vram_gb": 10,
        "license": "Stability AI Community License",
        "commercial_ok": True,
        "best_for": "Instrumentale Spielmusik, Ambient und Spannungsflächen",
        "description": (
            "Das Musikmodell von Stability AI aus dem Jahr 2026, destilliert auf 8 Schritte. "
            "Erzeugt instrumentale Stücke in 44,1 kHz Stereo, in NVAI-open bis 5 Minuten (laut "
            "Stability kann das Modell bis 6:20), laut Stability nur mit lizenzierten Daten "
            "trainiert. Kein Gesang und keine Liedtexte, "
            "ein Chor kommt höchstens als wortlose Klangfläche. Gattung, Instrumente, Stimmung "
            "und Tempo beschreiben, als Satz oder als Liste."
        ),
        "pros": [
            "Laut Stability nur mit lizenzierten Daten trainiert",
            "Bis 5 Minuten am Stück, 44,1 kHz Stereo; gemessen 60 s in 9–12 s, 300 s in 64 s",
            "Destilliert: 8 Schritte, CFG 1",
        ],
        "cons": [
            "Kein Gesang, keine Liedtexte",
            "Community License mit 1-Mio.-USD-Umsatzgrenze; der Text-Encoder (T5Gemma) steht unter den Gemma-Bedingungen",
            "Lange Stücke brauchen viel Grafikspeicher: 300 s füllten 16 GB fast ganz (60 s: 9,7 GB)",
            "Neu in NVAI-open, noch wenig erprobt",
        ],
    },
]

# --------------------------------------------------------------- VIDEO

# LTX-2.5: was beide Fassungen (NVFP4 fuer RTX 50, INT8 fuer RTX 20/30/40) teilen. Die optionalen
# Dateien schalten Zusatzfunktionen frei (registry.is_installed/features_for): den Laengenkopf fuer
# "Laenge automatisch", den zeitlichen Hochskalierer fuer DFR mit 48 fps und das Detail-IC-LoRA fuer
# DFR. Das IC-LoRA liegt in einem eigenen Repo mit eigener Freigabe auf Hugging Face; fehlt sie,
# laeuft LTX-2.5 trotzdem, nur ohne DFR.
LTX25_SHARED_FILES: list[dict[str, Any]] = [
    {"repo": "Lightricks/LTX-2.5",
     "file": "text_encoders/gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot.safetensors",
     "target": "text_encoders"},
    {"repo": "Lightricks/LTX-2.5", "file": "vae/ltx-2.5-video-vae-bf16.safetensors", "target": "vae"},
    {"repo": "Lightricks/LTX-2.5", "file": "vae/ltx-2.5-audio-vae-bf16.safetensors", "target": "vae"},
    {"repo": "Lightricks/LTX-2.5",
     "file": "latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors",
     "target": "latent_upscale_models"},
    {"repo": "Lightricks/LTX-2.5", "file": "model_patches/ltx-2.5-duration-head-bf16.safetensors",
     "target": "model_patches", "optional": "auto_duration"},
    {"repo": "Lightricks/LTX-2.5",
     "file": "latent_upscale_models/ltx-2.5-latent-temporal-upscaler-x2-bf16-1.0.safetensors",
     "target": "latent_upscale_models", "optional": "temporal_upscale"},
    {"repo": "Lightricks/LTX-2.5-22b-IC-LoRA-Pixel-Spatial-Upscaler",
     "file": "ltx-2.5-22b-ic-lora-pixel-spatial-upscaler-x2-1.0.safetensors",
     "target": "loras", "optional": "dfr"},
]

# Breite und Hoehe auf Vielfachen von 64 (die erste Stufe rechnet auf halber Groesse).
# 1080p zuerst (Nutzer, 24.10.: "die höhere Qualität immer bevorzugen, aber darauf hinweisen"); die
# Generieren-Seite nimmt das erste Format als Vorgabe. Gemessen 5 s: 1080p 251 s, 720p 93 s.
LTX25_SIZES = [
    {"label": "1920 × 1088 — 1080p, beste Qualität (rund 2,7-mal so lang)", "w": 1920, "h": 1088},
    {"label": "1088 × 1920 — 1080p hochkant, beste Qualität", "w": 1088, "h": 1920},
    {"label": "1280 × 704 — 16:9, 720p, schneller", "w": 1280, "h": 704},
    {"label": "704 × 1280 — 9:16, hochkant, schneller", "w": 704, "h": 1280},
    {"label": "1024 × 576 — 16:9, am schnellsten", "w": 1024, "h": 576},
    {"label": "1024 × 1024 — quadratisch", "w": 1024, "h": 1024},
]

# Was die Generieren-Seite und Claude (list_models) anbieten. auto_duration, dfr und temporal_upscale
# setzt registry.features_for auf False, solange die optionalen Dateien fehlen.
LTX25_FEATURES: dict[str, Any] = {
    "start_image": "optional", "end_image": True, "loop": True, "audio_input": True,
    "auto_duration": True, "dfr": True, "temporal_upscale": True, "motion_speed": True,
    "multishot": True, "fps": 24, "max_seconds": 20, "sizes": LTX25_SIZES,
    "prompt_hint": (
        "Ein Absatz im Präsens, 4 bis 8 Sätze: Einstellung, Ort und Licht, die Handlung von Anfang "
        "bis Ende mit Verben, Figuren, die Kamerabewegung, zuletzt der Ton. Gesprochenes in "
        "Anführungszeichen. Mehrere Einstellungen: jeden Schnitt ausschreiben (\"A hard cut "
        "transitions to …\"), 2 bis 4 Einstellungen. Personen: Gesicht groß und frontal im Startbild, "
        "nicht abwenden lassen; sprechen nur mit Gesicht im Bild und immer gleich beschriebener Stimme, "
        "sonst klingt sie anders."),
    "placeholder": (
        "Cinematic wide shot of a lighthouse on a rocky coast at dusk. Waves crash against the rocks "
        "while the beam sweeps slowly across the dark sea. The camera pushes in slowly. Sound: roaring "
        "surf, gusting wind, a distant foghorn."),
}

LTX25_WARNING = ("LTX-2 Community License: kostenlos nur unter 10 Mio. US-$ Jahresumsatz; das "
                 "Wasserzeichen darf nicht entfernt werden. Repo gated — Lizenz auf Hugging Face "
                 "akzeptieren und Token hinterlegen. Für DFR hat das Detail-IC-LoRA eine eigene "
                 "Freigabe.")

LTX25_WAYS = (
    "Wege in NVAI-open:\n"
    "• Text zu Video oder mit Startbild: zwei Stufen, erst halbe Auflösung, dann hochskaliert und "
    "nachgerechnet.\n"
    "• Start- und Endbild: ein Übergang zwischen zwei Bildern. Mit „Schleife“ ist das Startbild "
    "auch das Endbild, für nahtlose Loops.\n"
    "• Höchste Qualität (DFR, Diffusion Fidelity Rendering): Detail-Keyframes und ein "
    "Detail-IC-LoRA, auf Wunsch mit 48 fps.\n"
    "• Länge automatisch: Ein Zusatzkopf schätzt die Dauer aus der beschriebenen Handlung.\n"
    "• Ton vorgeben: ein vorhandener Ton, etwa Musik aus Stable Audio 3, bleibt unverändert, das Bild "
    "richtet sich danach.\n"
    "• Mehrere Einstellungen (Multishot): Schnitte im Prompt ausschreiben.\n"
    "• Zeitlupe: zusammen mit der Slow-Motion-LoRA von Lightricks.\n"
)


VIDEO_MODELS: list[dict[str, Any]] = [
    # LTX-2.5 steht vorn: Ohne eigene Wahl nimmt NVAI-open das erste installierte Videomodell
    # (registry.get_active_model), und LTX-2.5 ist das empfohlene (Nutzerwunsch 24.10.2026).
    {
        "id": "ltx25-distilled-nvfp4",
        "name": "LTX-2.5 (NVFP4, destilliert, mit Ton)",
        "kind": "video",
        "family": "ltx25",
        "workflow": "ltx25",
        "files": [
            # Repo ist gated: Lizenz auf Hugging Face akzeptieren und Token hinterlegen.
            {"repo": "Lightricks/LTX-2.5",
             "file": "diffusion_models/ltx-2.5-22b-distilled-transformer-nvfp4.safetensors",
             "target": "diffusion_models"},
            *LTX25_SHARED_FILES,
        ],
        "size_gb": 37.51,
        "model_gb": 18.72,
        "vram_gb": 16,
        "license": "LTX-2 Community License",
        "commercial_ok": True,
        "warning": LTX25_WARNING,
        "best_for": "Das empfohlene Videomodell: Video mit Ton aus Text, Startbild oder Start- und Endbild",
        "description": (
            "Lightricks, August 2026. 22 Mrd. Parameter, erzeugt Bild und Ton in einem Durchgang: "
            "Geräusche, Musik und Sprache passend zur Szene; Gesprochenes gehört in "
            "Anführungszeichen in den Prompt. Text-Encoder ist Gemma 4 12B (INT8). Modell und Encoder "
            "passen nicht gleichzeitig in 16 GB, ComfyUI lagert aus.\n\n"
            + LTX25_WAYS + "\n"
            "Gemessen auf einer RTX 5060 Ti (16 GB, 24 fps, 1280 × 704, mit Ton): 5 s aus Text in 93 s "
            "(erster Lauf mit Laden 122 s), mit Startbild 109 s, Start- und Endbild 154 s, Schleife "
            "über 4 s 125 s; 1920 × 1088 in 251 s; 20 s zu vorgegebenem Ton bei 1024 × 576 in 302 s. "
            "Der Grafikspeicher ist dabei fast voll. Leise beschriebene Geräusche („crackles softly“) "
            "kommen sehr leise heraus, laute Quellen ausdrücklich nennen.\n\n"
            "Ausgabe als MP4 mit Ton. Graphen nach ComfyUIs Vorlagen video_ltx2_5_t2v, _i2v, _flf2v "
            "und _dfr_i2v."
        ),
        "pros": ["Video mit passendem Ton", "Text, Startbild, Start- und Endbild, Schleife",
                 "DFR für mehr Detail, auf Wunsch mit 48 fps",
                 "Länge automatisch, Ton vorgeben, Multishot, Zeitlupe",
                 "NVFP4: rechnet auf RTX 50 in Hardware", "Lizenz erlaubt die EU"],
        "cons": ["37,5 GB Download", "Kostenlos nur unter 10 Mio. US-$ Umsatz",
                 "DFR braucht eine eigene Freigabe auf Hugging Face (Detail-IC-LoRA)",
                 "Breite und Höhe werden auf Vielfache von 64 gerundet", "Zensur nicht dokumentiert"],
        "features": LTX25_FEATURES,
    },
    {
        "id": "ltx25-distilled-int8",
        "name": "LTX-2.5 (INT8, destilliert, mit Ton)",
        "kind": "video",
        "family": "ltx25",
        "workflow": "ltx25",
        "files": [
            {"repo": "Lightricks/LTX-2.5",
             "file": "diffusion_models/ltx-2.5-22b-distilled-transformer-comfy-int8-convrot.safetensors",
             "target": "diffusion_models"},
            *LTX25_SHARED_FILES,
        ],
        "size_gb": 40.29,
        "model_gb": 21.5,
        "vram_gb": 16,
        "license": "LTX-2 Community License",
        "commercial_ok": True,
        "warning": LTX25_WARNING,
        "best_for": "Dasselbe LTX-2.5 für RTX 20/30/40 (INT8 in Hardware) und AMD Radeon",
        "description": (
            "Dasselbe Modell in der INT8-Fassung, die ComfyUIs eigene LTX-2.5-Vorlagen verwenden "
            "(INT8 mit ConvRot). Für Karten ohne FP4-Einheiten gedacht: RTX 20, 30 und 40 rechnen "
            "INT8 in Hardware, NVFP4 müssten sie Schicht für Schicht entpacken.\n\n"
            + LTX25_WAYS + "\n"
            "Auf einer RTX 50 ist die NVFP4-Fassung kleiner und die richtige; diese Fassung ist in "
            "NVAI-open noch nicht gemessen."
        ),
        "pros": ["Alle Wege wie die NVFP4-Fassung", "INT8 läuft ab RTX 20 in Hardware",
                 "Lizenz erlaubt die EU"],
        "cons": ["40,3 GB Download", "In NVAI-open noch nicht gemessen",
                 "Kostenlos nur unter 10 Mio. US-$ Umsatz",
                 "DFR braucht eine eigene Freigabe auf Hugging Face (Detail-IC-LoRA)"],
        "features": LTX25_FEATURES,
    },
    {
        "id": "wan21-t2v-1.3b",
        "name": "Wan 2.1 T2V 1.3B",
        "kind": "video",
        "family": "wan",
        "workflow": "wan_t2v",
        "files": [
            {"repo": "Comfy-Org/Wan_2.1_ComfyUI_repackaged",
             "file": "split_files/diffusion_models/wan2.1_t2v_1.3B_fp16.safetensors",
             "target": "diffusion_models"},
            {"repo": "Comfy-Org/Wan_2.1_ComfyUI_repackaged",
             "file": "split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors",
             "target": "text_encoders"},
            {"repo": "Comfy-Org/Wan_2.1_ComfyUI_repackaged",
             "file": "split_files/vae/wan_2.1_vae.safetensors", "target": "vae"},
        ],
        "size_gb": 9.15,
        "vram_gb": 8,
        "license": "Apache-2.0",
        "commercial_ok": True,
        "best_for": "Der Einstieg in Video — läuft entspannt auf 16 GB",
        "description": (
            "Das kleine Wan-Modell ist für deine Karte der vernünftigste Startpunkt: nur "
            "1,3B Parameter, ~8 GB VRAM, und trotzdem zeitlich stabile Clips. Typisch sind "
            "480p und 3–5 Sekunden bei 16 fps. Für Spiele brauchbar bei animierten Texturen, "
            "Effekt-Loops, Hintergrundvideos oder Trailer-Schnipseln."
        ),
        "pros": [
            "Läuft mit Reserve auf 16 GB — kein Offload nötig",
            "Apache-2.0, uneingeschränkt kommerziell",
            "Gute zeitliche Konsistenz für seine Größe",
            "Schnellster Weg zu einem ersten Video",
        ],
        "cons": [
            "480p und wenige Sekunden — kein fertiges Trailermaterial",
            "Details flimmern, Text im Bild zerfällt",
            "Dreiteiliger Download (Modell + Encoder + VAE)",
        ],
    },
    {
        "id": "wan22-ti2v-5b",
        "name": "Wan 2.2 TI2V 5B",
        "kind": "video",
        "family": "wan22",
        "workflow": "wan22_ti2v",
        "files": [
            {"repo": "Comfy-Org/Wan_2.2_ComfyUI_Repackaged",
             "file": "split_files/diffusion_models/wan2.2_ti2v_5B_fp16.safetensors",
             "target": "diffusion_models"},
            {"repo": "Comfy-Org/Wan_2.2_ComfyUI_Repackaged",
             "file": "split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors",
             "target": "text_encoders"},
            {"repo": "Comfy-Org/Wan_2.2_ComfyUI_Repackaged",
             "file": "split_files/vae/wan2.2_vae.safetensors", "target": "vae"},
        ],
        "size_gb": 16.89,
        "vram_gb": 13,
        "license": "Apache-2.0",
        "commercial_ok": True,
        "best_for": "Beste Video-Qualität, die real auf 16 GB passt",
        "description": (
            "Wan 2.2 in der 5B-Variante wurde ausdrücklich für Consumer-Karten gebaut und "
            "kann Text-zu-Video und Bild-zu-Video im selben Modell. 720p wird erreichbar. "
            "Wenn du ein generiertes Konzeptbild in Bewegung sehen willst, ist das hier der "
            "richtige Griff."
        ),
        "pros": [
            "Text-zu-Video und Bild-zu-Video in einem Modell",
            "Deutlich bessere Bewegung und Detailtreue als 1.3B",
            "720p realistisch erreichbar",
            "Apache-2.0",
        ],
        "cons": [
            "~13 GB VRAM: parallel läuft nichts mehr",
            "16,9 GB Download",
            "Merklich langsamer — mehrere Minuten pro Clip",
        ],
    },
    {
        "id": "wan22-i2v-a14b",
        "name": "Wan 2.2 I2V A14B (fp8)",
        "kind": "video",
        "family": "wan22",
        "workflow": "wan22_i2v",
        "files": [
            {"repo": "Comfy-Org/Wan_2.2_ComfyUI_Repackaged",
             "file": "split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors",
             "target": "diffusion_models"},
            {"repo": "Comfy-Org/Wan_2.2_ComfyUI_Repackaged",
             "file": "split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors",
             "target": "diffusion_models"},
            {"repo": "Comfy-Org/Wan_2.2_ComfyUI_Repackaged",
             "file": "split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors",
             "target": "text_encoders"},
            # A14B rechnet mit dem Wan-2.1-VAE (16 Kanaele). Der neue wan2.2_vae gehoert
            # ausschliesslich zum 5B-TI2V-Modell -- vertauscht ergibt das Farbmatsch.
            {"repo": "Comfy-Org/Wan_2.2_ComfyUI_Repackaged",
             "file": "split_files/vae/wan_2.1_vae.safetensors", "target": "vae"},
        ],
        "size_gb": 33.13,
        "vram_gb": 14,
        "license": "Apache-2.0",
        "commercial_ok": True,
        "best_for": "Bestes Bild-zu-Video, das auf 16 GB läuft — belebt ein Standbild glaubhaft",
        "description": (
            "Zwei Experten zu je 14B teilen sich den Lauf: der High-Noise-Experte legt "
            "Bewegung und Bildaufbau an, der Low-Noise-Experte zeichnet die Details aus. "
            "ComfyUI lädt sie nacheinander, deshalb passt das Modell trotz 2×13,3 GB auf "
            "deine Karte — es kostet nur einen Modellwechsel mitten im Lauf.\n\n"
            "Menschliche Bewegung, Stoff, Wasser und Kamerafahrten sind hier deutlich "
            "überzeugender als bei allem anderen im Katalog. Anders als Wan 2.1 I2V braucht "
            "dieses Modell kein CLIP-Vision: das Startbild geht direkt ins Conditioning."
        ),
        "pros": [
            "Die mit Abstand beste Bild-zu-Video-Qualität hier",
            "Bewegung und Anatomie bleiben über den Clip konsistent",
            "Apache-2.0 — uneingeschränkt kommerziell nutzbar",
            "720p möglich, 480p sehr solide",
        ],
        "cons": [
            "33 GB Download — der größte Posten im Katalog",
            "Modellwechsel mitten im Lauf: rechne mit vielen Minuten pro Clip",
            "~14 GB VRAM je Experte: vorher VRAM leeren",
            "Braucht zwingend ein Startbild",
        ],
    },
    {
        "id": "ltx23-nvfp4",
        "name": "LTX-2.3 (NVFP4, mit Ton)",
        "kind": "video",
        "family": "ltx23",
        "workflow": "ltx23",
        "files": [
            {"repo": "Lightricks/LTX-2.3-nvfp4", "file": "ltx-2.3-22b-dev-nvfp4.safetensors",
             "target": "checkpoints"},
            {"repo": "Comfy-Org/ltx-2",
             "file": "split_files/text_encoders/gemma_3_12B_it_fp4_mixed.safetensors",
             "target": "text_encoders"},
            {"repo": "Comfy-Org/ltx-2.3",
             "file": "split_files/loras/ltx_2.3_22b_distilled_1.1_lora_dynamic_fro09_avg_rank_111_bf16.safetensors",
             "target": "loras"},
            {"repo": "Lightricks/LTX-2.3", "file": "ltx-2.3-spatial-upscaler-x2-1.1.safetensors",
             "target": "latent_upscale_models"},
        ],
        "size_gb": 34.89,
        "vram_gb": 16,
        "license": "LTX-2 Community License",
        "commercial_ok": True,
        "warning": ("LTX-2 Community License: kostenlos nur unter 10 Mio. US-$ Jahresumsatz."),
        "best_for": "Video mit Ton; Basis der meisten Community-LoRAs und -Feintunings für LTX",
        "description": (
            "Lightricks, Vorgänger von LTX-2.5 mit derselben Architektur (22 Mrd. Parameter, Bild "
            "und Ton in einem Durchgang). Für 2.3 gibt es weit mehr Community-Erweiterungen als für "
            "2.5: LoRAs für Stile, Figuren und Bewegung, und Feintunings ohne Inhaltsfilter. Dafür "
            "ist es der richtige Unterbau.\n\n"
            "NVAI-open rechnet wie ComfyUIs Vorlage video_ltx2_3_t2v.json: dev-Checkpoint in NVFP4 "
            "plus destillierte LoRA (Stärke 0,5), zwei Stufen mit festen Sigmas, Text-Encoder "
            "Gemma 3 12B (fp4). Mit Startbild Bild zu Video. Gemessen auf einer RTX 5060 Ti, 97 "
            "Frames (4 s) bei 24 fps: 1280 × 704 mit Ton in 101 s, Bild zu Video 448 × 832 in 65 s. "
            "Im Test Schmied mit Hammerklang; mit Startbild blieb die Figur erhalten."
        ),
        "pros": ["Video mit passendem Ton", "Text und Bild zu Video in einem Modell",
                 "Größte Auswahl an Community-LoRAs für LTX", "Kein Gated-Repo"],
        "cons": ["35 GB Download", "Kostenlos nur unter 10 Mio. US-$ Umsatz",
                 "Neuere Fassung LTX-2.5 ist bei gleicher Größe besser",
                 "Breite und Höhe werden auf Vielfache von 64 gerundet"],
    },
    {
        "id": "kandinsky5-lite-t2v",
        "name": "Kandinsky 5.0 Video Lite T2V (2B)",
        "kind": "video",
        "family": "kandinsky5",
        "workflow": "kandinsky5_t2v",
        "files": [
            {"repo": "kandinskylab/Kandinsky-5.0-T2V-Lite-sft-5s",
             "file": "model/kandinsky5lite_t2v_sft_5s.safetensors", "target": "diffusion_models"},
            *KANDINSKY5_SHARED,
        ],
        "size_gb": 14.69,
        "vram_gb": 12,
        "license": "MIT (VAE: Tencent Hunyuan Community License)",
        "commercial_ok": True,
        "warning": KANDINSKY5_VAE_WARNING,
        "best_for": "Kleines, MIT-lizenziertes Videomodell, 5 s in 768 × 512",
        "description": (
            "Kandinsky Lab (Sber), 2 Mrd. Parameter, MIT-Lizenz. Text-Encoder Qwen2.5-VL 7B und "
            "CLIP-L, der VAE stammt von HunyuanVideo. Auf 5 s trainiert: 121 Frames bei 24 fps in "
            "768 × 512 (Hersteller), längere Clips nicht.\n\n"
            "Werte aus ComfyUIs Vorlage video_kandinsky5_t2v.json: 50 Schritte, cfg 5, "
            "euler_ancestral, beta, shift 5. Der Text-Encoder ist derselbe wie bei Qwen-Image und "
            "wird nur einmal geladen. Gemessen auf einer RTX 5060 Ti: 5 s Video in 768 × 512 in "
            "26 Minuten (1578 s) — für Entwürfe die destillierte Fassung nehmen."
        ),
        "pros": ["MIT-Lizenz für das Modell", "Nur 2 Mrd. Parameter",
                 "Text-Encoder mit Qwen-Image geteilt", "Negativprompt wirkt (cfg 5)"],
        "cons": ["VAE unter Tencent-Lizenz", "50 Schritte", "Höchstens 5 s",
                 "Zensur nicht dokumentiert"],
    },
    {
        "id": "kandinsky5-lite-t2v-distilled",
        "name": "Kandinsky 5.0 Video Lite T2V, destilliert (16 Schritte)",
        "kind": "video",
        "family": "kandinsky5",
        "workflow": "kandinsky5_t2v_distilled",
        "files": [
            {"repo": "kandinskylab/Kandinsky-5.0-T2V-Lite-distilled16steps-5s",
             "file": "model/kandinsky5lite_t2v_distilled16steps_5s.safetensors",
             "target": "diffusion_models"},
            *KANDINSKY5_SHARED,
        ],
        "size_gb": 14.69,
        "vram_gb": 12,
        "license": "MIT (VAE: Tencent Hunyuan Community License)",
        "commercial_ok": True,
        "warning": KANDINSKY5_VAE_WARNING,
        "best_for": "Schnelle Videoentwürfe mit Kandinsky",
        "description": (
            "Dieselbe Kandinsky 5.0 Lite, auf 16 Schritte und ohne CFG destilliert. Laut "
            "Modellkarte auf einer H100 35 s statt 77 s für 5 s Video. NVAI-open rechnet mit 16 "
            "Schritten und cfg 1; der Negativprompt wirkt dabei nicht. Gemessen auf einer RTX 5060 "
            "Ti: 5 s Video (121 Frames, 768 × 512) in rund 300 s. Im Test ein Schmied mit "
            "schlüssiger Hammerbewegung und Glut."
        ),
        "pros": ["Rund dreimal weniger Schritte", "MIT-Lizenz für das Modell"],
        "cons": ["VAE unter Tencent-Lizenz", "Negativprompt wirkungslos (cfg 1)", "Höchstens 5 s"],
    },
    {
        "id": "kandinsky5-lite-i2v",
        "name": "Kandinsky 5.0 Video Lite I2V (2B)",
        "kind": "video",
        "family": "kandinsky5",
        "workflow": "kandinsky5_i2v",
        "files": [
            {"repo": "kandinskylab/Kandinsky-5.0-I2V-Lite-5s",
             "file": "model/kandinsky5lite_i2v_5s.safetensors", "target": "diffusion_models"},
            *KANDINSKY5_SHARED,
        ],
        "size_gb": 14.69,
        "vram_gb": 12,
        "license": "MIT (VAE: Tencent Hunyuan Community License)",
        "commercial_ok": True,
        "warning": KANDINSKY5_VAE_WARNING,
        "best_for": "Ein Standbild beleben, mit kleinem Modell",
        "description": (
            "Bild-zu-Video-Fassung von Kandinsky 5.0 Lite. Das Startbild wird auf das gewählte "
            "Format zugeschnitten und nach dem Rechnen wieder als erster Frame eingesetzt, wie in "
            "ComfyUIs Vorlage video_kandinsky5_i2v.json. Startbild ist Pflicht. Gemessen auf einer "
            "RTX 5060 Ti: 5 s in 768 × 512 in 27 Minuten (1617 s). Im Querformat hielt es die Szene "
            "und setzte die Anweisung um; im Hochformat 512 × 768 sprang das Video nach dem ersten "
            "Frame in eine Nahaufnahme — nur 768 × 512 verwenden."
        ),
        "pros": ["MIT-Lizenz für das Modell", "Startbild bleibt als erster Frame exakt erhalten"],
        "cons": ["VAE unter Tencent-Lizenz", "Braucht ein Startbild", "Nur im Querformat 768 × 512 verlässlich",
                 "27 Minuten für 5 s"],
    },
    {
        "id": "mochi-1-preview-fp8",
        "name": "Mochi 1 preview (fp8)",
        "kind": "video",
        "family": "mochi",
        "workflow": "mochi",
        "files": [
            {"repo": "Comfy-Org/mochi_preview_repackaged",
             "file": "split_files/diffusion_models/mochi_preview_fp8_scaled.safetensors",
             "target": "diffusion_models"},
            {"repo": "comfyanonymous/flux_text_encoders",
             "file": "t5xxl_fp8_e4m3fn_scaled.safetensors", "target": "text_encoders"},
            {"repo": "Comfy-Org/mochi_preview_repackaged",
             "file": "split_files/vae/mochi_vae.safetensors", "target": "vae"},
        ],
        "size_gb": 16.11,
        "vram_gb": 14,
        "license": "Apache-2.0",
        "commercial_ok": True,
        "best_for": "Apache-lizenziertes Text-zu-Video mit flüssiger Bewegung",
        "description": (
            "Genmo, 10 Mrd. Parameter, Apache-2.0. Laut Hersteller stark bei Bewegung und "
            "Prompttreue, gedacht für 480p (848 × 480) bei 30 fps. Text-Encoder T5-XXL (mit Chroma "
            "geteilt).\n\n"
            "NVAI-open rechnet wie ComfyUIs Mochi-Beispiel: 30 Schritte, cfg 4,5, euler. Frames werden "
            "auf 6n+1 gerundet, der VAE dekodiert gekachelt. Gemessen auf einer RTX 5060 Ti: 49 "
            "Frames in 848 × 480 in 351 s mit Laden. Im Test ein Fuchs, der sauber durch Schnee "
            "läuft, mit seitlicher Kamerafahrt."
        ),
        "pros": ["Apache-2.0, auch kommerziell", "Negativprompt wirkt", "Nur Text, keine Lizenzbedingungen"],
        "cons": ["Nur Text zu Video", "Preview-Stand von 2024, kein Nachfolger",
                 "Laut Modellkarte NSFW-Inhalte eingeschränkt"],
    },
    {
        "id": "ltxv-2b-095",
        "name": "LTX-Video 2B v0.9.5",
        "kind": "video",
        "family": "ltxv",
        "workflow": "ltxv_t2v",
        "files": [{"repo": "Lightricks/LTX-Video",
                   "file": "ltx-video-2b-v0.9.5.safetensors", "target": "checkpoints"}],
        "size_gb": 5.91,
        "vram_gb": 8,
        "license": "LTX-Video Open Weights License",
        "commercial_ok": True,
        "best_for": "Schnelle Iteration — Videovorschau in Sekunden statt Minuten",
        "description": (
            "Auf Geschwindigkeit optimiert und erzeugt Clips oft schneller als deren "
            "Abspieldauer. Genau richtig, um zwanzig Varianten einer Idee durchzuprobieren, "
            "bevor du das gute Modell darauf ansetzt. Qualitativ unter Wan 2.2, dafür "
            "um Größenordnungen schneller."
        ),
        "pros": [
            "Mit Abstand das schnellste Videomodell hier",
            "Nur 5,9 GB Download, eine Datei",
            "Ideal zum Ausprobieren von Bewegungsideen",
        ],
        "cons": [
            "Sichtbar schwächer als Wan bei Details und Konsistenz",
            "Braucht sehr ausführliche Prompts, sonst passiert wenig",
            "Eigene Lizenz — vor kommerzieller Nutzung lesen",
        ],
    },
    {
        "id": "wan21-i2v-480p-14b",
        "name": "Wan 2.1 I2V 480p 14B (fp8)",
        "kind": "video",
        "family": "wan",
        "workflow": "wan_i2v",
        "files": [
            {"repo": "Comfy-Org/Wan_2.1_ComfyUI_repackaged",
             "file": "split_files/diffusion_models/wan2.1_i2v_480p_14B_fp8_scaled.safetensors",
             "target": "diffusion_models"},
            {"repo": "Comfy-Org/Wan_2.1_ComfyUI_repackaged",
             "file": "split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors",
             "target": "text_encoders"},
            {"repo": "Comfy-Org/Wan_2.1_ComfyUI_repackaged",
             "file": "split_files/vae/wan_2.1_vae.safetensors", "target": "vae"},
            {"repo": "Comfy-Org/Wan_2.1_ComfyUI_repackaged",
             "file": "split_files/clip_vision/clip_vision_h.safetensors", "target": "clip_vision"},
        ],
        "size_gb": 22.9,
        "vram_gb": 15,
        "license": "Apache-2.0",
        "commercial_ok": True,
        "best_for": "Bild-zu-Video der Vorgängergeneration — nur noch, wenn Wan 2.2 nicht passt",
        "description": (
            "Das große 14B-Modell aus der Wan-2.1-Reihe in fp8. Belebt ein Standbild "
            "ordentlich, ist aber inzwischen von Wan 2.2 I2V A14B überholt — dort ist die "
            "Bewegung sauberer und die Anatomie stabiler. Vorteil hier: nur ein Modell statt "
            "zwei Experten, also 10 GB weniger Download und kein Modellwechsel mitten im "
            "Lauf. Braucht als einziges I2V-Modell zusätzlich CLIP-Vision, das das Startbild "
            "beschreibt."
        ),
        "pros": [
            "Ein Modell statt zwei Experten — kein Wechsel mitten im Lauf",
            "10 GB weniger Download als Wan 2.2 I2V",
            "Apache-2.0",
        ],
        "cons": [
            "Von Wan 2.2 I2V A14B in Bewegung und Anatomie geschlagen",
            "~15 GB VRAM: keinerlei Reserve, Offload-Risiko",
            "22,9 GB Download",
            "Sehr langsam — viele Minuten pro Clip",
            "Braucht zwingend ein Startbild",
        ],
    },
]

# ------------------------------------------------------------------ 3D

MODEL_3D: list[dict[str, Any]] = [
    {
        "id": "trellis2-4b",
        "name": "TRELLIS.2-4B (PBR-Texturen)",
        "kind": "3d",
        "family": "trellis2",
        "workflow": "trellis2",
        # Snapshot: die Pipeline laedt ueber pipeline.json mehrere Teilmodelle.
        # Ohne die 1024er-Varianten, die auf 16 GB ohnehin nicht laufen.
        "files": [{
            "repo": "microsoft/TRELLIS.2-4B", "snapshot": True, "target": "trellis2_bf16",
            "check": "ckpts/slat_flow_img2shape_dit_1_3B_512_bf16.safetensors",
            "allow_patterns": ["*.json", "*.safetensors"],
        }, {
            # Den Sparse-Structure-Decoder holt pipeline.json aus dem ersten TRELLIS
            # (MIT). Liegt er daneben in ckpts/, verweist der Worker lokal darauf.
            "repo": "microsoft/TRELLIS-image-large", "snapshot": True, "target": "trellis2_bf16",
            "check": "ckpts/ss_dec_conv3d_16l8_fp16.safetensors",
            "allow_patterns": ["ckpts/ss_dec_conv3d_16l8_fp16.*"],
        }],
        "size_gb": 16.2,
        "vram_gb": 14,
        "license": "MIT",
        "commercial_ok": True,
        "best_for": "Meshes MIT Texturen — Albedo, Normal, Roughness/Metallic",
        "description": (
            "Microsofts aktuelles Bild-zu-3D-Modell und das einzige hier, das echte "
            "PBR-Materialien liefert: Albedo, Normal und Roughness/Metallic als Bitmaps, "
            "nicht nur Vertex-Farben. Damit ist ein Asset ohne manuelles Texturieren "
            "spielfertig. Läuft in einem eigenen Worker mit sechs selbst kompilierten "
            "CUDA-Extensions; MIT-Lizenz, also uneingeschränkt kommerziell nutzbar."
        ),
        "pros": [
            "Vollständige PBR-Texturen statt nur Geometrie — spart den Texturier-Schritt",
            "MIT-Lizenz, keine regionalen Einschränkungen",
            "Deutlich bessere Mesh-Qualität als TripoSG",
            "Texturauflösung bis 4096² einstellbar",
        ],
        "cons": [
            "~14 GB VRAM bei 512³ — auf 16 GB kaum Reserve, 1024³ ist nicht drin",
            "16,2 GB Download plus ~7 GB venv mit kompilierten Extensions",
            "Braucht Visual Studio 2022 Build Tools; mit VS 18 scheitert die Kompilierung",
            "Langsamer als TripoSG",
        ],
    },
    {
        "id": "hunyuan3d-2.1",
        "name": "Hunyuan3D 2.1 (ComfyUI)",
        "kind": "3d",
        "family": "hunyuan3d",
        "workflow": None,
        "files": [{"repo": "Comfy-Org/hunyuan3D_2.1_repackaged",
                   "file": "hunyuan_3d_v2.1.safetensors", "target": "checkpoints"}],
        "size_gb": 6.86,
        "vram_gb": 12,
        "license": "Tencent Hunyuan Community License",
        "commercial_ok": False,
        "best_for": "Beste Mesh-Qualität lokal — aber Lizenz für die EU prüfen",
        "description": (
            "Neueste Hunyuan3D-Version im ComfyUI-Format. Die nötigen Nodes sind in dieser "
            "ComfyUI-Installation vorhanden, es braucht also keinen separaten Worker-Prozess — "
            "nur der Workflow-Builder in NVAI-open fehlt noch."
        ),
        "pros": [
            "Beste lokal erreichbare Mesh-Qualität",
            "Nodes bereits nativ vorhanden — kein Zusatz-Setup",
            "GLB-Export direkt nach Unity",
        ],
        "cons": [
            "Workflow-Builder in NVAI-open fehlt noch",
            "Tencent-Lizenz mit regionalen Einschränkungen — für die EU kritisch",
            "Nicht für ein kommerzielles Spiel ohne Lizenzprüfung",
        ],
    },
    {
        "id": "triposg",
        "name": "TripoSG",
        "kind": "3d",
        "family": "triposg",
        "workflow": "triposg",
        # Snapshot statt Einzeldateien: der Worker nutzt from_pretrained() und
        # braucht die komplette Repo-Struktur inklusive config.json.
        "files": [{
            "repo": "VAST-AI/TripoSG", "snapshot": True, "target": "triposg",
            # Auf die Gewichte pruefen, nicht auf die config.json: die ist nach
            # wenigen Sekunden da, waehrend das 5-GB-Modell noch laedt.
            "check": "transformer/diffusion_pytorch_model.safetensors",
            "allow_patterns": ["*.json", "*.safetensors", "*.txt", "*.md"],
        }],
        "size_gb": 7.39,
        "vram_gb": 10,
        "license": "MIT",
        "commercial_ok": True,
        "best_for": "Bild zu Mesh mit sauberer Lizenz — die kommerzielle Wahl",
        "description": (
            "Qualitativ auf Augenhöhe mit Hunyuan3D, aber unter MIT-Lizenz: uneingeschränkt "
            "kommerziell nutzbar, keine regionalen Klauseln. Für ein verkauftes Spiel aus der "
            "EU heraus die unproblematischere Wahl. Läuft in einem eigenen Worker-Prozess "
            "neben ComfyUI, nicht darin. Liefert GLB-Meshes aus einem einzelnen Bild."
        ),
        "pros": [
            "MIT-Lizenz: keinerlei Einschränkung, auch nicht regional",
            "Mesh-Qualität nahe Hunyuan3D",
            "~10 GB VRAM, passt gut auf die Karte",
            "GLB-Export geht direkt nach Unity oder Blender",
        ],
        "cons": [
            "Eigener Worker-Prozess mit eigenem venv (~7 GB zusätzliche Abhängigkeiten)",
            "Nur Geometrie, keine Texturen — die kommen aus einem separaten Schritt",
            "Topologie ist Rohmaterial und braucht Retopo für Game-Assets",
        ],
    },
    {
        "id": "trellis-image-large",
        "name": "TRELLIS image-large (Microsoft)",
        "kind": "3d",
        "family": "trellis",
        "workflow": None,
        "files": [
            {"repo": "microsoft/TRELLIS-image-large",
             "file": "ckpts/slat_flow_img_dit_L_64l8p2_fp16.safetensors",
             "target": "diffusion_models", "as": "trellis_slat_flow.safetensors"},
            {"repo": "microsoft/TRELLIS-image-large",
             "file": "ckpts/slat_dec_mesh_swin8_B_64l8m256c_fp16.safetensors",
             "target": "diffusion_models", "as": "trellis_slat_dec_mesh.safetensors"},
            {"repo": "microsoft/TRELLIS-image-large",
             "file": "ckpts/slat_enc_swin8_B_64l8_fp16.safetensors",
             "target": "diffusion_models", "as": "trellis_slat_enc.safetensors"},
            {"repo": "microsoft/TRELLIS-image-large",
             "file": "ckpts/ss_dec_conv3d_16l8_fp16.safetensors",
             "target": "diffusion_models", "as": "trellis_ss_dec.safetensors"},
        ],
        "size_gb": 1.58,
        "vram_gb": 8,
        "license": "MIT",
        "commercial_ok": True,
        "best_for": "Schnell, winzig, MIT — gut für Masse und Prototypen",
        "description": (
            "Microsofts Bild-zu-3D-Modell unter MIT-Lizenz. Erzeugt Mesh, Gaussian Splats und "
            "Radiance Fields aus einem Bild. Mit gut 1,5 GB extrem kompakt und schnell, "
            "qualitativ etwas unter TripoSG und Hunyuan3D — aber für viele Assets in kurzer "
            "Zeit die praktischste Wahl."
        ),
        "pros": [
            "MIT-Lizenz, uneingeschränkt kommerziell",
            "Sehr klein (1,6 GB) und schnell",
            "Liefert auch Gaussian Splats, nicht nur Meshes",
        ],
        "cons": [
            "Noch nicht nutzbar: braucht einen eigenen Worker-Prozess",
            "Gröber als TripoSG und Hunyuan3D",
            "Installation der Abhängigkeiten (nvdiffrast) ist auf Windows aufwendig",
        ],
    },
    {
        "id": "instantmesh",
        "name": "InstantMesh (Apache-2.0)",
        "kind": "3d",
        "family": "instantmesh",
        "workflow": None,
        "files": [{"repo": "TencentARC/InstantMesh", "file": "instant_mesh_large.ckpt",
                   "target": "checkpoints"}],
        "size_gb": 1.41,
        "vram_gb": 8,
        "license": "Apache-2.0",
        "commercial_ok": True,
        "best_for": "Kleinste kommerzielle Option, sehr schnell",
        "description": (
            "Erzeugt über Mehransichten-Diffusion ein Mesh aus einem Bild. Apache-2.0 und mit "
            "1,4 GB die schlankeste Option hier. Qualitativ hinter TripoSG, aber für einfache "
            "Props oft ausreichend."
        ),
        "pros": [
            "Apache-2.0, keine Einschränkungen",
            "Nur 1,4 GB, sehr schnell",
        ],
        "cons": [
            "Noch nicht nutzbar: braucht einen eigenen Worker-Prozess",
            "Deutlich gröbere Meshes als TripoSG oder Hunyuan3D",
            "Bei komplexen Formen unzuverlässig",
        ],
    },
    {
        "id": "hunyuan3d-2",
        "name": "Hunyuan3D 2.0 (ComfyUI)",
        "kind": "3d",
        "family": "hunyuan3d",
        # Nodes sind vorhanden, der Builder in workflows.py fehlt aber noch.
        "workflow": None,
        "files": [{"repo": "Comfy-Org/hunyuan3D_2.0_repackaged",
                   "file": "split_files/hunyuan3d-dit-v2_fp16.safetensors", "target": "checkpoints"}],
        "size_gb": 4.59,
        "vram_gb": 10,
        "license": "Tencent Hunyuan Community License",
        "commercial_ok": False,
        "best_for": "Bild zu 3D-Mesh — direkt in ComfyUI, ohne Zusatz-Worker",
        "description": (
            "Erzeugt aus einem einzelnen Bild ein 3D-Mesh und exportiert als GLB. Läuft "
            "nativ in dieser ComfyUI-Version, es braucht also keinen separaten Worker-Prozess. "
            "Liefert die Geometrie; Texturierung ist ein eigener Schritt."
        ),
        "pros": [
            "Beste Mesh-Qualität, die lokal auf 16 GB erreichbar ist",
            "Nativ unterstützt — kein Dependency-Hell",
            "GLB-Export geht direkt nach Unity",
        ],
        "cons": [
            "Tencent-Lizenz mit regionalen Einschränkungen — für die EU kritisch prüfen",
            "Nur Geometrie; Textur ist ein separater Durchlauf",
            "Topologie ist Rohmaterial und braucht Retopo",
        ],
    },
    {
        "id": "hunyuan3d-2-mv-turbo",
        "name": "Hunyuan3D 2.0 Multiview Turbo",
        "kind": "3d",
        "family": "hunyuan3d",
        # Nodes sind vorhanden, der Builder in workflows.py fehlt aber noch.
        "workflow": None,
        "files": [{"repo": "Comfy-Org/hunyuan3D_2.0_repackaged",
                   "file": "split_files/hunyuan3d-dit-v2-mv-turbo_fp16.safetensors", "target": "checkpoints"}],
        "size_gb": 4.59,
        "vram_gb": 10,
        "license": "Tencent Hunyuan Community License",
        "commercial_ok": False,
        "best_for": "Schneller, und nutzt mehrere Ansichten desselben Objekts",
        "description": (
            "Turbo-Variante mit weniger Steps. Kann mehrere Ansichten eines Objekts "
            "verrechnen, was Rückseiten deutlich plausibler macht — nützlich, wenn du "
            "vorher Front/Seite/Rücken als Bilder generiert hast."
        ),
        "pros": [
            "Schneller als die Standardvariante",
            "Mehransichten liefern glaubwürdigere Rückseiten",
        ],
        "cons": [
            "Dieselbe Tencent-Lizenzfrage",
            "Turbo kostet etwas Detailtreue",
        ],
    },
]

# ------------------------------------------------------- CONTROLNET
#
# Zusatzmodelle, die kein Bild erzeugen, sondern eine Form vorgeben. Sie erscheinen
# nicht als eigener Modus, sondern als Auswahl beim Bild-Generieren.
#
# Bewusst die Comfy-Org-Repacks: die Originale unter stabilityai/ sind gated und
# ohne hinterlegten HF-Token nicht ladbar. Auf der GPU landen die fp32-Gewichte als
# fp16, also rund 4,3 GB statt der 8,7 GB Dateigroesse.

CONTROLNET_MODELS: list[dict[str, Any]] = [
    {
        "id": "sd35-controlnet-depth",
        "name": "SD 3.5 ControlNet — Tiefe",
        "kind": "controlnet",
        "family": "sd3",
        "workflow": "controlnet",
        "files": [{"repo": "Comfy-Org/stable-diffusion-3.5-controlnets_ComfyUI_repackaged",
                   "file": "split_files/controlnet/sd3.5_large_controlnet_depth.safetensors",
                   "target": "controlnet"}],
        "size_gb": 8.66,
        "vram_gb": 4.3,
        "license": "Stability AI Community License",
        "commercial_ok": True,
        "best_for": "Fahrzeuge und Bauten: Silhouette und Proportion aus einer Vorlage erzwingen",
        "description": (
            "Nimmt eine Tiefenkarte als Vorgabe und zwingt das Bild in deren Form. Genau "
            "das Mittel gegen verbogene Panzer und Flugzeuge: statt zu hoffen, dass das "
            "Modell einen Panzer IV richtig rät, gibst du die Silhouette vor.\n\n"
            "Die Tiefenkarte kann aus Blender kommen, aus einem groben Blockout oder aus "
            "einer Dreiseitenansicht. Übergib sie als Referenzbild mit "
            "`preprocess=\"none\"` — NVAI-open verarbeitet sie dann unverändert weiter.\n\n"
            "Nur für SD 3.5 Large. Auf 16 GB wird es eng: vorher VRAM leeren."
        ),
        "pros": [
            "Der wirksamste Hebel gegen deformierte Fahrzeuge",
            "Kommerziell nutzbar, nicht gated",
            "Lässt am Ende los (`controlnet_end`), Details bleiben frei",
        ],
        "cons": [
            "8,7 GB Download",
            "Zusätzlich ~4,3 GB VRAM neben dem Bildmodell — auf 16 GB knapp",
            "Braucht eine Tiefenkarte; NVAI-open erzeugt selbst keine",
            "Nur SD 3.5, nicht für FLUX oder Chroma",
        ],
    },
    {
        "id": "sd35-controlnet-canny",
        "name": "SD 3.5 ControlNet — Kanten",
        "kind": "controlnet",
        "family": "sd3",
        "workflow": "controlnet",
        "files": [{"repo": "Comfy-Org/stable-diffusion-3.5-controlnets_ComfyUI_repackaged",
                   "file": "split_files/controlnet/sd3.5_large_controlnet_canny.safetensors",
                   "target": "controlnet"}],
        "size_gb": 8.66,
        "vram_gb": 4.3,
        "license": "Stability AI Community License",
        "commercial_ok": True,
        "best_for": "Vorlage ist eine Zeichnung, Blaupause oder ein Foto",
        "description": (
            "Führt das Bild an Kanten entlang. Praktisch, wenn deine Vorlage bereits ein "
            "Strichbild ist — Blaupause, technische Zeichnung, Konzeptskizze. Aus einem "
            "Foto holt NVAI-open die Kanten selbst heraus (`preprocess=\"canny\"`), dafür "
            "braucht es kein weiteres Modell.\n\n"
            "Kanten sind strenger als Tiefe: das Ergebnis folgt der Vorlage sehr genau. "
            "Für Silhouettentreue gut, für freie Interpretation zu eng."
        ),
        "pros": [
            "Kantenerkennung ist eingebaut — kein zusätzlicher Download",
            "Sehr genaue Übernahme der Vorlage",
            "Kommerziell nutzbar, nicht gated",
        ],
        "cons": [
            "8,7 GB Download",
            "Zusätzlich ~4,3 GB VRAM — auf 16 GB knapp",
            "Strenger als Tiefe: wenig Spielraum für das Modell",
            "Nur SD 3.5",
        ],
    },
]

# ---------------------------------------------------------------- LORAS

def _lora(repo: str, file: str, **fields: Any) -> dict[str, Any]:
    """Empfohlene LoRA als fester Katalogeintrag. Die ID folgt derselben Regel wie beim Laden aus der
    Suche (registry.register_custom), damit eine schon geladene LoRA als dieser Eintrag erscheint
    und nicht doppelt."""
    def slug(text: str) -> str:
        return re.sub(r"[^\w.-]+", "_", text.lower()).strip("_") or "lora"

    entry: dict[str, Any] = {
        "id": f"lora-{slug(repo.split('/')[-1])}-{slug(PurePosixPath(file).stem)}",
        "kind": "lora", "family": "ltx2", "workflow": None,
        "files": [{"repo": repo, "file": file, "target": "loras"}],
        "vram_gb": 0, "trigger": "", "source_url": f"https://huggingface.co/{repo}",
        "pros": [], "cons": [],
    }
    entry.update(fields)
    return entry


_NO_LICENSE = ("Keine Lizenzangabe im Repo: vor einer kommerziellen Nutzung beim Autor nachfragen.")
_GATED_LORA = ("LTX-2 Community License. Repo gated — die Lizenz auf Hugging Face eigens akzeptieren "
               "(eigene Freigabe neben LTX-2.5).")

# Für LTX-2.5 empfohlene LoRAs (Nutzerwunsch 24.10.2026), auf der Generieren-Seite aufklappbar unter
# dem Videomodell. features: strength = empfohlene Stärke, use = wozu sie gehört (start_image,
# end_image, audio_input, motion_speed), recommended_for = Modellfamilien. LTX-2.3-LoRAs laufen laut
# Lightricks meist auch auf LTX-2.5 (Modellkarte Lightricks/LTX-2.5).
LORA_MODELS: list[dict[str, Any]] = [
    _lora("Lightricks/LTX-2.5-22b-LoRA-Cinemagraph", "ltx-2.5-22b-lora-cinemagraph-0.9.safetensors",
          name="Cinemagraph (LTX-2.5, Lightricks)", size_gb=0.20,
          license="LTX-2 Community License", commercial_ok=True, warning=_GATED_LORA,
          trigger="CINEMAGRAPH_MOTION",
          best_for="Lebendes Standbild: ein Element bewegt sich, der Rest steht still",
          description=("Offizielle LoRA von Lightricks für LTX-2.5. Aus einem Startbild wird ein "
                       "Cinemagraph: ein Element bewegt sich (Wasser, Rauch, Haare, Licht), alles "
                       "andere bleibt stehen. Wirkt nur zusammen mit „Schleife“, die NVAI-open beim "
                       "Aktivieren mit einschaltet; daraus wird ein nahtloser Loop, etwa für Menü- und "
                       "Ladebildschirme. Trigger CINEMAGRAPH_MOTION in den Prompt, Stärke 1,0 bis 1,2. "
                       "Gemessen (König vor flackernden Fackeln, 4 s): mit Schleife bewegten sich 6 % "
                       "des Bildes, das Gesicht stand still; Schleife ohne LoRA 28 %; ohne Schleife "
                       "82–84 %, auch mit Stärke 1,2, weil die Kamera heranfuhr."),
          features={"strength": 1.0, "use": "loop", "recommended_for": ["ltx25"],
                    "tested": "Auf LTX-2.5 getestet: wirkt nur mit „Schleife“ (6 % statt 28 % des Bildes "
                              "in Bewegung, Gesicht still)"}),
    _lora("Lightricks/LTX-2.5-22b-LoRA-Slow-Motion-Control",
          "ltx-2.5-22b-lora-slow-motion-control-1.0.safetensors",
          name="Slow Motion Control (LTX-2.5, Lightricks)", size_gb=0.65,
          license="LTX-2 Community License", commercial_ok=True, warning=_GATED_LORA,
          best_for="Zeitlupe 2× bis 40× bei gleicher Abspielrate",
          description=("Offizielle LoRA von Lightricks für LTX-2.5. Mit Startbild und der "
                       "Einstellung „Zeitlupe“ (0,5 = 2×, 0,2 = 5×, 0,1 = 10× langsamer) läuft die "
                       "Bewegung langsamer ab, abgespielt wird weiter mit 24 fps. Kein Trigger-Wort, "
                       "und „slow motion“ nicht in den Prompt schreiben. Stärke 1,0. Gemessen mit "
                       "Lightricks' Einstellungen (Welle an Felsen, 1920 × 1088, 5 s, 0,2): Die Gischt sank "
                       "über die ganzen 5 s statt in rund 1,5 s, die Tropfen blieben scharf. Ohne LoRA stand "
                       "die Gischt als milchiger Schleier fast still. Mit 1280 × 704 und 0,25 war die Wirkung "
                       "schwächer."),
          features={"strength": 1.0, "use": "motion_speed", "recommended_for": ["ltx25"],
                    "tested": "Auf LTX-2.5 getestet (1080p, Zeitlupe 0,2): Gischt sinkt über 5 s statt in "
                              "1,5 s, Tropfen scharf; ohne LoRA nur ein milchiger, stehender Schleier"}),
    _lora("joyfox/LTX-2.3-Transition-LORA", "ltx2.3-transition.safetensors",
          name="Transition (LTX-2.3, joyfox)", size_gb=0.39,
          license="Apache-2.0", commercial_ok=True,
          best_for="Übergänge und Verwandlungen zwischen Start- und Endbild",
          description=("Für LTX-2.3 trainiert, auf Übergänge zwischen erstem und letztem Bild: "
                       "Verwandlungen, Szenen- und Stilwechsel. Hilft laut Autor auch bei Text und "
                       "Startbild. Stärke 1,0. Mit LTX-2.5 in NVAI-open getestet (Dorfplatz von Tag zu "
                       "Nacht, Start- und Endbild): kaum ein Unterschied zu ohne LoRA."),
          features={"strength": 1.0, "use": "end_image", "recommended_for": ["ltx25"],
                    "tested": "Auf LTX-2.5 getestet: bei Tag zu Nacht kaum ein Unterschied zu ohne LoRA"}),
    _lora("vrgamedevgirl84/LTX_2.3_Crisp_Enhance_Style_LoRa", "LTX2.3_Crisp_Enhance.safetensors",
          name="Crisp Enhance (LTX-2.3, vrgamedevgirl84)", size_gb=0.71,
          license="keine Angabe", commercial_ok=False, warning=_NO_LICENSE,
          best_for="Schärfer: mehr Mikrodetail, Kanten und Kontrast",
          description=("Für LTX-2.3. Hebt Schärfe, Kanten und Kontrast an. Mit LTX-2.3 in NVAI-open "
                       "getestet: deutlich schärfer, änderte aber den Bildaufbau."),
          features={"strength": 0.8, "recommended_for": ["ltx25"]}),
    _lora("vrgamedevgirl84/LTX_2.3_Fantasy_Anime_Style_LoRa", "Fantasy_Anime.safetensors",
          name="Fantasy Anime (LTX-2.3, vrgamedevgirl84)", size_gb=0.35,
          license="keine Angabe", commercial_ok=False, warning=_NO_LICENSE, trigger="f4nt4sy4n1m6",
          best_for="Fantasy-Anime mit Cel-Shading",
          description=("Für LTX-2.3. Fantasy-Anime-Illustration mit Cel-Shading; laut Autor ohne "
                       "fremde Figuren trainiert. Trigger f4nt4sy4n1m6, Stärke 1,0. Mit LTX-2.5 in "
                       "NVAI-open getestet: deutlicher Anime-Look mit Cel-Shading."),
          features={"strength": 1.0, "recommended_for": ["ltx25"],
                    "tested": "Auf LTX-2.5 getestet: deutlicher Anime-Look"}),
    _lora("vrgamedevgirl84/LTX_2.3_Fantasy_Painterly_Style_LoRa", "Fantasy_Painterly.safetensors",
          name="Fantasy Painterly (LTX-2.3, vrgamedevgirl84)", size_gb=0.35,
          license="keine Angabe", commercial_ok=False, warning=_NO_LICENSE, trigger="D4rkP41nt3r",
          best_for="Gemalte Fantasy-Szenen mit sichtbaren Pinselstrichen",
          description=("Für LTX-2.3. Fantasy wie in Öl gemalt: Pinselstriche, Farbschichten, "
                       "leuchtendes Licht. Trigger D4rkP41nt3r. Mit LTX-2.5 in NVAI-open getestet: "
                       "deutlich gemalt, dunklere Farben."),
          features={"strength": 1.0, "recommended_for": ["ltx25"],
                    "tested": "Auf LTX-2.5 getestet: deutlich gemalt"}),
    _lora("vrgamedevgirl84/LTX_2.3_Clay_Mation_Style_LoRa", "Claymation.safetensors",
          name="Claymation (LTX-2.3, vrgamedevgirl84)", size_gb=0.35,
          license="keine Angabe", commercial_ok=False, warning=_NO_LICENSE, trigger="claymation style",
          best_for="Knetfiguren und Stop-Motion-Dioramen",
          description=("Für LTX-2.3. Figuren und Orte wie aus Knete geformt, mit Fingerabdrücken und "
                       "Miniatur-Kulissen. Trigger claymation style. Mit LTX-2.5 in NVAI-open getestet: "
                       "nur angedeutet (Filz- und Miniatur-Look), auch mit Stärke 1,4."),
          features={"strength": 1.0, "recommended_for": ["ltx25"],
                    "tested": "Auf LTX-2.5 getestet: nur angedeutet, auch mit Stärke 1,4"}),
    _lora("vrgamedevgirl84/LTX_2.3_Paper_Cut_Out_Style_LoRa", "PaperCutOutStyle.safetensors",
          name="Paper Cut-Out (LTX-2.3, vrgamedevgirl84)", size_gb=0.35,
          license="keine Angabe", commercial_ok=False, warning=_NO_LICENSE, trigger="Pap3rCut0u7",
          best_for="Papierschnitt-Dioramen wie aus einem Bilderbuch",
          description=("Für LTX-2.3. Alles wirkt aus Papierlagen geschnitten und gefaltet. Trigger "
                       "Pap3rCut0u7. Mit LTX-2.5 in NVAI-open getestet: bei Stärke 1,0 kaum zu sehen, "
                       "bei 1,5 ein flacher Papierschnitt-Look."),
          features={"strength": 1.5, "recommended_for": ["ltx25"],
                    "tested": "Auf LTX-2.5 getestet: erst mit Stärke 1,5 deutlich"}),
    _lora("vrgamedevgirl84/LTX_2.3_Cinematic_Sci-fi-Cyberpunk_Style_LoRa",
          "Cinematic_sci-fi-cyberpunk.safetensors",
          name="Sci-fi Cyberpunk (LTX-2.3, vrgamedevgirl84)", size_gb=0.35,
          license="keine Angabe", commercial_ok=False, warning=_NO_LICENSE, trigger="C6b4rP8nk",
          best_for="Neon-Noir und Cyberpunk-Städte",
          description=("Für LTX-2.3. Realistischer Cyberpunk-Look: Neonlicht, nasse Straßen, "
                       "Hightech. Trigger C6b4rP8nk."),
          features={"strength": 1.0, "recommended_for": ["ltx25"]}),
    _lora("fal/ltx2.3-audio-reactive-lora", "ltx2.3_audio_reactive_lora_v2.safetensors",
          name="Audio Reactive (LTX-2.3, fal)", size_gb=1.35,
          license="LTX-2 Community License", commercial_ok=True,
          best_for="Visualizer und Musikvideos, die auf den Takt reagieren",
          description=("Für LTX-2.3, Fassung 2. Formen, Partikel und Licht pulsieren im Takt eines "
                       "vorgegebenen Tons. Am besten mit Startbild und „Ton vorgeben“, Stärke 1,0 bis "
                       "1,5, 5 bis 15 Sekunden. Mit LTX-2.5 in NVAI-open getestet: Schon ohne LoRA "
                       "pulsierte der Visualizer zum vorgegebenen Ton; mit LoRA folgte die Helligkeit der "
                       "Lautstärke etwas enger (Korrelation 0,23 statt 0,09), das Bild wurde weicher."),
          features={"strength": 1.0, "use": "audio_input", "recommended_for": ["ltx25"],
                    "tested": "Auf LTX-2.5 getestet: Das Bild folgt dem Ton etwas enger; LTX-2.5 pulsiert auch ohne"}),
]


# Schärfen und Vergrößern beim Restaurieren (seit 0.5.11, jobs._restore). SeedVR2 von ByteDance ist ein
# Ein-Schritt-Diffusionsmodell für Bild- und Videorestaurierung; ComfyUI rechnet es nativ (Vorlage
# utility_seedvr2_7b_int8_upscale_image.json). Es erzeugt nichts selbst, sondern bessert ein Bild nach:
# Rauschen, Unschärfe und Korn weg, Auflösung hoch. Eigene Art "upscale", damit es nicht als Bildmodell
# auftaucht.
SEEDVR2_VAE = {"repo": "Comfy-Org/SeedVR2", "file": "vae/seedvr2_ema_vae_fp16.safetensors", "target": "vae"}
SEEDVR2_LICENSE = "Apache-2.0"
SEEDVR2_PROS = [
    "Apache-2.0, kommerziell frei",
    "Ein Schritt: bessert Rauschen, Korn und Unschärfe nach und vergrößert dabei",
    "Läuft nativ in ComfyUI, ohne Erweiterung",
]
SEEDVR2_CONS = [
    "Repariert keine Kratzer, Risse oder Flecken – das macht „Schäden entfernen“ mit FLUX 3",
    "Erfindet bei starker Vergrößerung Feindetail (Haut, Stoff), das so nicht im Original war",
]
UPSCALE_MODELS: list[dict[str, Any]] = [
    {
        "id": "seedvr2-7b-nvfp4",
        "name": "SeedVR2 7B (NVFP4, Schärfen und Vergrößern)",
        "kind": "upscale",
        "family": "seedvr2",
        "workflow": "seedvr2",
        "files": [
            {"repo": "Comfy-Org/SeedVR2", "file": "diffusion_models/seedvr2_7b_nvfp4.safetensors",
             "target": "diffusion_models"},
            SEEDVR2_VAE,
        ],
        "size_gb": 5.3,
        "model_gb": 4.76,
        "vram_gb": 8,
        "license": SEEDVR2_LICENSE,
        "commercial_ok": True,
        "best_for": "Alte Fotos nach dem Restaurieren schärfen, entrauschen und vergrößern",
        "features": {"scales": [1, 2, 4], "scale": 2, "max_pixels": 16_000_000},
        "description": (
            "SeedVR2 von ByteDance (Apache-2.0): ein Diffusionsmodell, das Bilder und Videos in einem "
            "einzigen Schritt restauriert. Es nimmt Rauschen, Filmkorn, Unschärfe und Kompressionsspuren "
            "heraus und vergrößert dabei, ohne den Bildinhalt neu zu erfinden wie ein Bildgenerator.\n\n"
            "In NVAI-open ist es der letzte Schritt von „Foto restaurieren“: Erst entfernt FLUX 3 Kratzer "
            "und Flecken, dann färbt es auf Wunsch ein, dann schärft und vergrößert SeedVR2. Es geht auch "
            "allein, etwa für einen kleinen, verrauschten Scan.\n\n"
            "Die NVFP4-Fassung rechnet auf RTX 50 in Hardware; für ältere Karten gibt es INT8."
        ),
        "pros": SEEDVR2_PROS,
        "cons": SEEDVR2_CONS,
    },
    {
        "id": "seedvr2-7b-int8",
        "name": "SeedVR2 7B (INT8, für RTX 20/30/40)",
        "kind": "upscale",
        "family": "seedvr2",
        "workflow": "seedvr2",
        "files": [
            {"repo": "Comfy-Org/SeedVR2", "file": "diffusion_models/seedvr2_7b_int8_convrot.safetensors",
             "target": "diffusion_models"},
            SEEDVR2_VAE,
        ],
        "size_gb": 8.8,
        "model_gb": 8.33,
        "vram_gb": 11,
        "license": SEEDVR2_LICENSE,
        "commercial_ok": True,
        "best_for": "SeedVR2 auf Karten ohne FP4 (RTX 20/30/40)",
        "features": {"scales": [1, 2, 4], "scale": 2, "max_pixels": 16_000_000},
        "description": (
            "Dasselbe Modell wie `seedvr2-7b-nvfp4` in Comfy-Orgs INT8-Fassung (ConvRot), die ab RTX 20 "
            "in Hardware rechnet; so steht es auch in ComfyUIs Vorlage. Auf dieser Karte ungemessen."
        ),
        "pros": SEEDVR2_PROS,
        "cons": SEEDVR2_CONS + ["Auf RTX 50 ist die NVFP4-Fassung die richtige"],
    },
    {
        "id": "seedvr2-3b-int8",
        "name": "SeedVR2 3B (INT8, klein)",
        "kind": "upscale",
        "family": "seedvr2",
        "workflow": "seedvr2",
        "files": [
            {"repo": "Comfy-Org/SeedVR2", "file": "diffusion_models/seedvr2_3b_int8_convrot.safetensors",
             "target": "diffusion_models"},
            SEEDVR2_VAE,
        ],
        "size_gb": 4.0,
        "model_gb": 3.46,
        "vram_gb": 6,
        "license": SEEDVR2_LICENSE,
        "commercial_ok": True,
        "best_for": "SeedVR2 für Karten mit 8 GB",
        "features": {"scales": [1, 2, 4], "scale": 2, "max_pixels": 16_000_000},
        "description": (
            "Die kleine Fassung mit 3 Mrd. Parametern (INT8, 3,5 GB). Laut ByteDance etwas weniger "
            "Detail als 7B, dafür passt sie auch in 8 GB Grafikspeicher. Ungemessen."
        ),
        "pros": SEEDVR2_PROS,
        "cons": SEEDVR2_CONS + ["Laut Hersteller weniger Detail als 7B"],
    },
    {
        "id": "seedvr2-3b-nvfp4",
        "name": "SeedVR2 3B (NVFP4, klein)",
        "kind": "upscale",
        "family": "seedvr2",
        "workflow": "seedvr2",
        "files": [
            {"repo": "Comfy-Org/SeedVR2", "file": "diffusion_models/seedvr2_3b_nvfp4.safetensors",
             "target": "diffusion_models"},
            SEEDVR2_VAE,
        ],
        "size_gb": 2.5,
        "model_gb": 2.0,
        "vram_gb": 6,
        "license": SEEDVR2_LICENSE,
        "commercial_ok": True,
        "best_for": "SeedVR2 klein für RTX 50",
        "features": {"scales": [1, 2, 4], "scale": 2, "max_pixels": 16_000_000},
        "description": (
            "Die kleine Fassung mit 3 Mrd. Parametern in NVFP4 (2,0 GB) für RTX 50. Gemessen 28.10. an einem "
            "VHS-Testclip (100 Bilder auf 1440 × 1080): nicht schneller als 7B, weil der VAE die Zeit bestimmt "
            "(3B 247 s, 7B 188 s); für Video deshalb 7B nehmen, 3B nur bei knappem Grafikspeicher."
        ),
        "pros": SEEDVR2_PROS,
        "cons": SEEDVR2_CONS + ["Laut Hersteller weniger Detail als 7B", "Gemessen nicht schneller als 7B"],
    },
]


# ------------------------------------------------------------ Fassungen für AMD Radeon (seit 0.5.12)
# NVFP4 rechnet nur RTX 50 in Hardware, auf AMD wird es Schicht für Schicht entpackt. RDNA4 (Radeon RX 9000, gfx1200/
# gfx1201) rechnet FP8 in Hardware: ComfyUI schaltet die FP8-Wege dort ab ROCm 6.4 und torch 2.7 selbst ein, und
# comfy-kitchen bringt eigene WMMA-Kernel mit (HIP-Backend, gfx1200/gfx1201 in seiner Zielliste). Für int8_convrot
# berichten Nutzer auf der RX 9070 XT schwarze Bilder, die mit der fp8_scaled-Fassung verschwanden. Deshalb nimmt
# NVAI-open auf RDNA4 die FP8-Dateien derselben Repos und bf16, wo es kein FP8 gibt und die Datei in 16 GB passt.
# Ungetestet auf echter AMD-Hardware (hier steckt eine RTX 5060 Ti); Text-Encoder wie in den INT8-Fassungen, außer wo
# Comfy-Org eine FP8-Datei anbietet.

def _variant(models: list[dict[str, Any]], source_id: str, new_id: str, swap: dict[str, tuple[str, str]],
             **fields: Any) -> None:
    """Kopie von `source_id` mit anderen Dateien (`swap`: alter Dateiname → (Repo, neuer Dateiname)) direkt
    hinter der Vorlage einfügen."""
    import copy
    index = next(i for i, e in enumerate(models) if e["id"] == source_id)
    entry = copy.deepcopy(models[index])
    for f in entry["files"]:
        if f["file"] in swap:
            f["repo"], f["file"] = swap[f["file"]]
    entry.update(id=new_id, **fields)
    models.insert(index + 1, entry)


_AMD_NOTE = ("Auf AMD noch ungetestet (Rückmeldungen über „Problem melden“ helfen). Auf NVIDIA-Karten ist die "
             "NVFP4- bzw. INT8-Fassung die bessere Wahl.")
_KREA_TE_FP8 = ("Comfy-Org/Krea-2", "text_encoders/qwen3vl_4b_fp8_scaled.safetensors")

_variant(
    IMAGE_MODELS, "qwen-image-2512-int8", "qwen-image-2512-fp8",
    {"qwen-image-2512-int8-tensorwise.safetensors":
        ("Comfy-Org/Qwen-Image_ComfyUI", "split_files/diffusion_models/qwen_image_2512_fp8_e4m3fn.safetensors")},
    name="Qwen-Image-2512 (FP8, für AMD Radeon)", size_gb=30.1, model_gb=20.43, vram_gb=16,
    best_for="Qwen-Image-2512 auf AMD Radeon RX 9000 (FP8 in Hardware)",
    description=(
        "Dasselbe Modell wie `qwen-image-2512-nvfp4`, in Comfy-Orgs FP8-Fassung (e4m3fn, 20,4 GB). Radeon RX 9000 "
        "(RDNA4) rechnet FP8 in Hardware; auf 16 GB lädt ComfyUI einen Teil aus dem Arbeitsspeicher nach. Prompt und "
        "Einstellungen wie bei der NVFP4-Fassung (50 Schritte, cfg 4).\n\n" + _AMD_NOTE),
    pros=["FP8 rechnet auf Radeon RX 9000 in Hardware", "Apache-2.0"],
    cons=["20,4 GB: auf 16 GB lädt ComfyUI Teile nach", "Auf AMD ungetestet"],
)
_variant(
    IMAGE_MODELS, "flux3-klein-int8", "flux3-klein-bf16",
    {"diffusion_models/flux3-image-klein-int8-convrot.safetensors":
        ("black-forest-labs/flux-3-image-klein-comfy", "diffusion_models/flux3-image-klein-bf16.safetensors"),
     "text_encoders/qwen3vl_4b_int8_convrot.safetensors": _KREA_TE_FP8},
    name="FLUX 3 Image Klein (bf16, für AMD Radeon)", size_gb=23.4, model_gb=11.1, vram_gb=14,
    best_for="FLUX 3 auf AMD Radeon (bf16, passt in 16 GB)",
    description=(
        "Dasselbe Modell wie `flux3-klein-nvfp4`, in BFLs voller bf16-Fassung (11,1 GB). Eine FP8-Fassung gibt es "
        "nicht; bf16 rechnet auf jeder Radeon ohne Sonderkernel und passt in 16 GB. Der Text-Encoder Qwen3-VL-4B "
        "kommt in FP8 aus Comfy-Orgs Krea-2-Repo (dieselben Gewichte wie bei FLUX 3, mit Krea 2 geteilt), der "
        "Upsampler wie bei der INT8-Fassung.\n\nRepo gesperrt: Lizenz auf Hugging Face annehmen und Token "
        "hinterlegen.\n\n" + _AMD_NOTE),
    pros=["Volle Genauigkeit, passt in 16 GB", "Keine Sonderkernel nötig"],
    cons=["Doppelt so groß wie INT8", "Repo gesperrt: Lizenz auf Hugging Face annehmen und Token hinterlegen",
          "Auf AMD ungetestet"],
)
_variant(
    IMAGE_MODELS, "krea2-turbo-int8", "krea2-turbo-fp8",
    {"diffusion_models/krea2_turbo_int8_convrot.safetensors":
        ("Comfy-Org/Krea-2", "diffusion_models/krea2_turbo_fp8_scaled.safetensors"),
     "text_encoders/qwen3vl_4b_int8_convrot.safetensors": _KREA_TE_FP8},
    name="Krea 2 Turbo (FP8, für AMD Radeon)", size_gb=18.6, model_gb=13.14, vram_gb=16,
    best_for="Krea 2 auf AMD Radeon RX 9000 (FP8 in Hardware)",
    description=(
        "Dasselbe Modell wie `krea2-turbo-nvfp4`, in Comfy-Orgs FP8-Fassung (fp8_scaled, 13,1 GB), Text-Encoder "
        "ebenfalls in FP8. Radeon RX 9000 (RDNA4) rechnet FP8 in Hardware, und es passt in 16 GB. Prompt-Hinweise "
        "wie bei der NVFP4-Fassung (Bildausschnitt nennen).\n\nLizenz: Krea 2 Community License — siehe "
        "Warnhinweis.\n\n" + _AMD_NOTE),
    pros=["FP8 rechnet auf Radeon RX 9000 in Hardware", "Passt in 16 GB"],
    cons=["Community-Lizenz: kommerziell nur unter 1 Mio. US-$ Umsatz, Prüfpflicht, kündbar", "Auf AMD ungetestet"],
)
_variant(
    IMAGE_MODELS, "moss-image-sft-int8", "moss-image-sft-bf16",
    {"diffusion_models/moss_image_sft_int8_convrot.safetensors":
        ("Comfy-Org/MOSS-Image", "diffusion_models/moss_image_sft_bf16.safetensors")},
    name="MOSS-Image SFT (bf16, für AMD Radeon)", size_gb=17.75, model_gb=10.16, vram_gb=14,
    best_for="MOSS-Image auf AMD Radeon (bf16, passt in 16 GB)",
    description=(
        "Dasselbe Modell wie `moss-image-sft-int8`, in Comfy-Orgs bf16-Fassung (10,2 GB): rechnet auf jeder Radeon "
        "ohne Sonderkernel und passt in 16 GB. Schrift und Layout im Bild unter Apache-2.0; Einstellungen wie bei "
        "der INT8-Fassung (50 Schritte, cfg 3).\n\n" + _AMD_NOTE),
    pros=["Apache-2.0, ohne Umsatzgrenze verkaufbar", "Volle Genauigkeit, passt in 16 GB"],
    cons=["Fast doppelt so groß wie INT8", "Auf AMD ungetestet"],
)
_variant(
    UPSCALE_MODELS, "seedvr2-7b-int8", "seedvr2-7b-fp8",
    {"diffusion_models/seedvr2_7b_int8_convrot.safetensors":
        ("Comfy-Org/SeedVR2", "diffusion_models/seedvr2_7b_fp8_e4m3fn.safetensors")},
    name="SeedVR2 7B (FP8, für AMD Radeon)", size_gb=8.7, model_gb=8.24, vram_gb=11,
    best_for="Schärfen und Vergrößern auf AMD Radeon RX 9000 (FP8 in Hardware)",
    description=(
        "Dasselbe Modell wie `seedvr2-7b-nvfp4`, in Comfy-Orgs FP8-Fassung (e4m3fn, 8,2 GB). Radeon RX 9000 (RDNA4) "
        "rechnet FP8 in Hardware.\n\n" + _AMD_NOTE),
    pros=["FP8 rechnet auf Radeon RX 9000 in Hardware", "Apache-2.0"],
    cons=["Auf AMD ungetestet"],
)


# Zwischenbilder (seit 0.5.16, VHS „Takt glätten“): ComfyUI 0.42.1 rechnet RIFE und FILM im Kern (FrameInterpolate,
# Vorlage utility_video_frame_interpolation.json). Eigene Art, damit es nie als Modell zum Aufbessern gewählt wird.
INTERPOLATE_MODELS: list[dict[str, Any]] = [
    {
        "id": "rife-4.26",
        "name": "RIFE 4.26 (Zwischenbilder)",
        "kind": "interpolate",
        "family": "rife",
        "workflow": "interpolate",
        "files": [
            {"repo": "Comfy-Org/Frame-Interpolation", "file": "frame_interpolation/rife_v4.26.safetensors",
             "target": "frame_interpolation"},
        ],
        "size_gb": 0.02,
        "model_gb": 0.02,
        "vram_gb": 2,
        "license": "MIT",
        "commercial_ok": True,
        "best_for": "VHS-Aufnahmen mit 30 Bildern/s aus einem 50-Hz-Band ruckelfrei auf 50 Bilder/s bringen",
        "description": (
            "RIFE (Practical-RIFE von hzwer, MIT) rechnet Zwischenbilder aus dem Bewegungsfluss zweier Nachbarbilder. "
            "Im VHS-Bereich glättet es Aufnahmen von Wandlern, die ein 50-Hz-Band mit 30 Bildern/s aufnehmen: Die "
            "Bilder liegen dort 40, 40 und 20 ms auseinander, Schwenks ruckeln. Mit den fehlenden Zwischenbildern "
            "entsteht wieder ein gleichmäßiger Takt von 50 Bildern/s; drei von fünf Bildern bleiben echte.\n\n"
            "Gemessen am echten Band (20 s, 960 × 720): Schwenkschritte vorher 1,29 / 1,40 / 0,48 Pixel, nachher "
            "0,48 bis 0,62, in Gesichtern keine sichtbaren Fehler."
        ),
        "pros": ["MIT, kommerziell frei", "23 MB, rechnet im ComfyUI-Kern ohne Erweiterung",
                 "Drei von fünf Bildern bleiben echte Bilder"],
        "cons": ["Zwischenbilder sind gerechnet: bei schnellen Bewegungen und Verdeckungen können Kanten wabern"],
    },
]


ALL_MODELS: list[dict[str, Any]] = (
    IMAGE_MODELS + AUDIO_MODELS + VIDEO_MODELS + MODEL_3D + CONTROLNET_MODELS + LORA_MODELS
    + UPSCALE_MODELS + INTERPOLATE_MODELS
)

KIND_LABELS = {"image": "Bild", "audio": "Audio", "video": "Video", "3d": "3D",
               "controlnet": "ControlNet", "upscale": "Hochskalieren", "interpolate": "Zwischenbilder"}


# Empfehlung nach Grafikkarte (registry.gpu_advice). RTX 50 rechnet NVFP4 in Hardware;
# ältere Karten entpacken es Schicht für Schicht und sind deutlich langsamer — dort
# INT8-Fassungen, die ab RTX 20 nativ laufen.
# LTX-2.5 ist das empfohlene Videomodell (Nutzerwunsch 24.10.2026).
RECOMMENDED_FP4 = ["qwen-image-2512-nvfp4", "flux3-klein-nvfp4", "krea2-turbo-nvfp4", "moss-image-sft-int8",
                   "ltx25-distilled-nvfp4", "seedvr2-7b-nvfp4"]
RECOMMENDED_OLDER = ["qwen-image-2512-int8", "flux3-klein-int8", "krea2-turbo-int8", "moss-image-sft-int8",
                     "z-image-int8", "ltx25-distilled-int8", "seedvr2-7b-int8"]
# Radeon RX 9000 (RDNA4) ab 16 GB: FP8 in Hardware, bf16 wo es kein FP8 gibt (siehe „Fassungen für AMD Radeon“).
# Z-Image in bf16 (12,3 GB) statt INT8; LTX-2.5 gibt es offiziell nur in bf16 (42 GB), INT8 und NVFP4 -- INT8 bleibt.
RECOMMENDED_AMD_RDNA4 = ["qwen-image-2512-fp8", "flux3-klein-bf16", "krea2-turbo-fp8", "moss-image-sft-bf16",
                         "z-image", "ltx25-distilled-int8", "seedvr2-7b-fp8"]

# Repos, deren Lizenz auf Hugging Face erst angenommen werden muss (Stand 26.10.2026, alle mit Sofortfreigabe).
# registry prüft je Repo, ob der hinterlegte Token Zugriff hat; die Oberfläche verlinkt die Anleitung.
GATED_REPOS = {
    "black-forest-labs/flux-3-image-klein-comfy",
    "Lightricks/LTX-2.5",
    "Lightricks/LTX-2.5-22b-IC-LoRA-Pixel-Spatial-Upscaler",
    "Lightricks/LTX-2.5-22b-LoRA-Cinemagraph",
    "Lightricks/LTX-2.5-22b-LoRA-Slow-Motion-Control",
}
# Bebilderte Anleitung (Konto, Lizenz annehmen, Token) im öffentlichen Repo.
HF_GUIDE_URL = {"de": "https://github.com/Mantux775/NVAI-open/blob/main/docs/de/HUGGINGFACE.md",
                "en": "https://github.com/Mantux775/NVAI-open/blob/main/docs/HUGGINGFACE.md"}
