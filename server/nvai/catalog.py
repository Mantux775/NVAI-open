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
        "id": "flux1-dev-fp8",
        "name": "FLUX.1 dev (fp8)",
        "kind": "image",
        "family": "flux",
        "workflow": "flux-dev",
        "files": [{"repo": "Comfy-Org/flux1-dev",
                   "file": "flux1-dev-fp8.safetensors", "target": "checkpoints"}],
        "size_gb": 16.06,
        "vram_gb": 12,
        "license": "FLUX.1-dev Non-Commercial License",
        "commercial_ok": False,
        "best_for": "Höchste Bildqualität — aber nur für Prototypen und Moodboards",
        "description": (
            "Qualitativ die Spitze dessen, was lokal auf 16 GB läuft: feinere Details und "
            "bessere Komposition als schnell. Die Lizenz ist allerdings ausdrücklich "
            "nicht-kommerziell. Für Concept-Phase und Moodboards in Ordnung, für Assets "
            "im verkauften Spiel nicht."
        ),
        "pros": [
            "Beste Detailtreue und Komposition dieser Auswahl",
            "Nimmt echte negative Prompts an (CFG > 1)",
            "Große LoRA-Auswahl",
        ],
        "cons": [
            "NICHT kommerziell nutzbar — kritisch für ein verkauftes Spiel",
            "20–25 Steps statt 4: deutlich langsamer als schnell",
            "16 GB Download, CPU-Offload nötig",
        ],
    },
    {
        "id": "sd35-medium",
        "name": "Stable Diffusion 3.5 Medium",
        "kind": "image",
        "family": "sd3",
        "workflow": "sd3",
        "files": [{"repo": "Comfy-Org/stable-diffusion-3.5-fp8",
                   "file": "sd3.5_medium_incl_clips_t5xxlfp8scaled.safetensors", "target": "checkpoints"}],
        "size_gb": 10.84,
        "vram_gb": 9,
        "license": "Stability AI Community License",
        "commercial_ok": True,
        "best_for": "Balance aus Prompt-Treue und Tempo; Text im Bild",
        "description": (
            "Sitzt genau zwischen SDXL und FLUX: deutlich bessere Prompt-Treue als SDXL, "
            "aber schlanker und schneller als FLUX. Kann Text im Bild brauchbar darstellen — "
            "praktisch für UI-Mockups, Schilder oder Item-Karten. Die Community License "
            "erlaubt kommerzielle Nutzung bis 1 Mio. USD Jahresumsatz."
        ),
        "pros": [
            "Gute Prompt-Treue bei nur ~9 GB VRAM",
            "Text im Bild funktioniert oft",
            "Alles in einer Datei — kein Encoder-Gefummel",
        ],
        "cons": [
            "Lizenz mit Umsatzgrenze (1 Mio. USD) — prüfen, wenn das Spiel läuft",
            "Anatomie schwächer als FLUX",
            "Kleineres LoRA-Ökosystem",
        ],
    },
    {
        "id": "sd35-large-fp8",
        "name": "Stable Diffusion 3.5 Large (fp8)",
        "kind": "image",
        "family": "sd3",
        "workflow": "sd3",
        "files": [{"repo": "Comfy-Org/stable-diffusion-3.5-fp8",
                   "file": "sd3.5_large_fp8_scaled.safetensors", "target": "checkpoints"}],
        "size_gb": 13.91,
        "vram_gb": 13,
        "license": "Stability AI Community License",
        "commercial_ok": True,
        "best_for": "Wenn SD3.5 Medium qualitativ nicht reicht",
        "description": (
            "Die 8B-Variante: sichtbar bessere Details und Komposition als Medium, dafür "
            "langsamer und mit wenig VRAM-Reserve. Sinnvoll, wenn du gezielt einzelne "
            "Hero-Assets in hoher Qualität brauchst statt Masse."
        ),
        "pros": [
            "Deutlich besser als Medium bei komplexen Szenen",
            "Kommerziell nutzbar (bis 1 Mio. USD Umsatz)",
        ],
        "cons": [
            "13 GB VRAM — kaum Reserve auf einer 16-GB-Karte",
            "Spürbar langsamer als Medium",
        ],
    },
    {
        "id": "chroma-v37",
        "name": "Chroma v37 (unlocked)",
        "kind": "image",
        "family": "chroma",
        "workflow": "chroma",
        # Chroma ist ein reines Diffusion-Model: Text-Encoder und VAE liegen
        # getrennt vor und werden ueber UNETLoader/CLIPLoader/VAELoader geladen.
        "files": [
            {"repo": "lodestones/Chroma", "file": "chroma-unlocked-v37.safetensors",
             "target": "diffusion_models"},
            {"repo": "comfyanonymous/flux_text_encoders",
             "file": "t5xxl_fp8_e4m3fn_scaled.safetensors", "target": "text_encoders"},
            {"repo": "lodestones/Chroma", "file": "ae.safetensors",
             "target": "vae", "as": "flux_ae.safetensors"},
        ],
        "size_gb": 21.69,
        "vram_gb": 13,
        "license": "Apache-2.0",
        "commercial_ok": True,
        "best_for": "FLUX-Qualität ohne Lizenzbeschränkung, ungefilterte Motive",
        "description": (
            "Aus FLUX.1 schnell weiterentwickelt und vollständig unter Apache-2.0 gestellt. "
            "Nähert sich der Qualität von FLUX dev an, ohne dessen Lizenzproblem. Für düstere "
            "oder gewalthaltige Fantasy-Motive nützlich, an denen die Stability-Modelle oft "
            "scheitern."
        ),
        "pros": [
            "FLUX-nahe Qualität unter Apache-2.0",
            "Keine inhaltlichen Filter — praktisch für Horror-/Dark-Fantasy-Art",
            "Nimmt echte negative Prompts an",
        ],
        "cons": [
            "Community-Projekt: Versionen wechseln schnell, Qualität schwankt",
            "16,6 GB Download, ~13 GB VRAM",
            "Braucht mehr Steps als FLUX schnell",
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
            "steht im Asset unter „caption“. Wiederholte Prompts nimmt NV-AI aus dem "
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
            "Nur Text-zu-Bild in NV-AI; die Edit-Variante ist nicht eingebunden",
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
        "id": "ace-step-v1-3.5b",
        "name": "ACE-Step v1 3.5B",
        "kind": "audio",
        "family": "ace",
        "workflow": "ace_step",
        "files": [{"repo": "Comfy-Org/ACE-Step_ComfyUI_repackaged",
                   "file": "all_in_one/ace_step_v1_3.5b.safetensors", "target": "checkpoints"}],
        "size_gb": 7.17,
        "vram_gb": 9,
        "license": "Apache-2.0",
        "commercial_ok": True,
        "best_for": "Vollständige Musikstücke inklusive Gesang",
        "description": (
            "Erzeugt komplette Songs aus Genre-Tags und optionalem Songtext — mit gesungenen "
            "Vocals. Für Titelmusik, Kampfthemen oder eine Taverne mit Barden-Song. Die "
            "Steuerung läuft über Tags (\"epic orchestral, choir, drums\") plus Lyrics-Feld. "
            "Apache-2.0 macht es kommerziell unbedenklich."
        ),
        "pros": [
            "Erzeugt strukturierte Musik mit Gesang — einzigartig in dieser Auswahl",
            "Apache-2.0: keine Umsatzgrenze, keine Lizenzsorgen",
            "Minutenlange Stücke möglich",
            "Tag-Steuerung ist für Spiel-Stimmungen sehr praktisch",
        ],
        "cons": [
            "Gesang klingt oft künstlich, Aussprache wackelt",
            "~9 GB VRAM und deutlich langsamer als Stable Audio",
            "Für kurze SFX überdimensioniert",
        ],
    },
    {
        "id": "ace-step-1.5-turbo",
        "name": "ACE-Step 1.5 Turbo (all-in-one)",
        "kind": "audio",
        "family": "ace15",
        "workflow": "ace_step_15",
        "files": [{"repo": "Comfy-Org/ace_step_1.5_ComfyUI_files",
                   "file": "checkpoints/ace_step_1.5_turbo_aio.safetensors", "target": "checkpoints"}],
        "size_gb": 9.34,
        "vram_gb": 11,
        "license": "Apache-2.0",
        "commercial_ok": True,
        "best_for": "Bessere Musikqualität als v1, mit mehr Steuerung",
        "description": (
            "Nachfolger von ACE-Step v1 mit sauberer Musikalität und deutlich mehr "
            "Stellschrauben: BPM, Tonart, Taktart und Sprache sind direkte Parameter statt "
            "Prompt-Andeutungen. Die Turbo-Variante braucht weniger Steps als das Basismodell."
        ),
        "pros": [
            "Hörbar besser als v1 bei Instrumentierung und Struktur",
            "BPM/Tonart/Taktart direkt steuerbar — wichtig für adaptive Spielmusik",
            "Apache-2.0",
        ],
        "cons": [
            "11 GB VRAM: neben einem Bildmodell wird es eng",
            "9,3 GB Download",
            "Neuer und weniger erprobt als v1",
        ],
    },
]

# --------------------------------------------------------------- VIDEO

VIDEO_MODELS: list[dict[str, Any]] = [
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
    {
        "id": "hunyuanvideo15-t2v-480p",
        "name": "HunyuanVideo 1.5 T2V 480p (fp8)",
        "kind": "video",
        "family": "hunyuanvideo15",
        "workflow": "hunyuan15_t2v",
        "files": [
            {"repo": "Comfy-Org/HunyuanVideo_1.5_repackaged",
             "file": "split_files/diffusion_models/"
                     "hunyuanvideo1.5_480p_t2v_cfg_distilled_fp8_scaled.safetensors",
             "target": "diffusion_models"},
            # Zwei Text-Encoder: Qwen2.5-VL versteht den Prompt, ByT5-Glyph deckt
            # Schriftzeichen ab. ComfyUI laedt sie nur ueber DualCLIPLoader zusammen.
            {"repo": "Comfy-Org/HunyuanVideo_1.5_repackaged",
             "file": "split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors",
             "target": "text_encoders"},
            {"repo": "Comfy-Org/HunyuanVideo_1.5_repackaged",
             "file": "split_files/text_encoders/byt5_small_glyphxl_fp16.safetensors",
             "target": "text_encoders"},
            {"repo": "Comfy-Org/HunyuanVideo_1.5_repackaged",
             "file": "split_files/vae/hunyuanvideo15_vae_fp16.safetensors", "target": "vae"},
        ],
        "size_gb": 19.26,
        "vram_gb": 11,
        "license": "Tencent Hunyuan Community License",
        "commercial_ok": False,
        "warning": "Lizenz gilt nicht in der EU, Großbritannien und Südkorea · sonst kommerziell bis 100 Mio. Nutzer",
        "best_for": "Ausprobieren: sehr gute Bewegung bei nur 7,8 GB Modellgröße",
        "description": (
            "NICHT KOMMERZIELL EINSETZBAR. Die Tencent Hunyuan Community License schließt "
            "kommerzielle Nutzung ohne gesonderte Lizenz aus und benennt die EU, das "
            "Vereinigte Königreich und Südkorea ausdrücklich als vom Nutzungsrecht "
            "ausgenommene Gebiete. Für ein verkauftes Spiel ist dieses Modell damit nicht "
            "verwendbar — für Moodboards, Tests und Vergleiche kannst du es fahren. Wenn "
            "ein Ergebnis ins Spiel soll, erzeuge es mit Wan (Apache-2.0) neu.\n\n"
            "Technisch ist es beeindruckend kompakt: der DiT wiegt in fp8 nur 7,8 GB und "
            "liefert trotzdem Bewegung auf Augenhöhe mit deutlich größeren Modellen. Diese "
            "Variante ist CFG-destilliert, läuft also ohne Guidance (cfg 1.0) und damit "
            "etwa doppelt so schnell — ein negativer Prompt bleibt hier folgenlos.\n\n"
            "Der Text-Encoder ist Qwen2.5-VL 7B (8,7 GB). Er wird vor dem DiT geladen und "
            "wieder verworfen; beides zusammen passt nicht gleichzeitig in 16 GB, "
            "nacheinander schon."
        ),
        "pros": [
            "Nur 7,8 GB Modellgröße bei sehr guter Bewegungsqualität",
            "CFG-destilliert: rund doppelt so schnell wie ein normales Video-Modell",
            "Prompt-Treue durch Qwen2.5-VL als Encoder spürbar besser als bei Wan",
        ],
        "cons": [
            "Lizenz gilt nicht in der EU, Großbritannien und Südkorea; Ausgaben dürfen kein anderes KI-Modell trainieren",
            "18,9 GB Download für ein Modell, das in der EU nicht genutzt werden darf",
            "negative_prompt wirkt nicht (cfg 1.0)",
            "Encoder und DiT passen nur nacheinander in den Speicher",
        ],
    },
    {
        "id": "hunyuanvideo15-i2v-720p",
        "name": "HunyuanVideo 1.5 I2V 720p (fp8)",
        "kind": "video",
        "family": "hunyuanvideo15",
        "workflow": "hunyuan15_i2v",
        "files": [
            {"repo": "Comfy-Org/HunyuanVideo_1.5_repackaged",
             "file": "split_files/diffusion_models/"
                     "hunyuanvideo1.5_720p_i2v_cfg_distilled_fp8_scaled.safetensors",
             "target": "diffusion_models"},
            # Zwei Text-Encoder: Qwen2.5-VL versteht den Prompt, ByT5-Glyph deckt
            # Schriftzeichen ab. ComfyUI laedt sie nur ueber DualCLIPLoader zusammen.
            {"repo": "Comfy-Org/HunyuanVideo_1.5_repackaged",
             "file": "split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors",
             "target": "text_encoders"},
            {"repo": "Comfy-Org/HunyuanVideo_1.5_repackaged",
             "file": "split_files/text_encoders/byt5_small_glyphxl_fp16.safetensors",
             "target": "text_encoders"},
            {"repo": "Comfy-Org/HunyuanVideo_1.5_repackaged",
             "file": "split_files/vae/hunyuanvideo15_vae_fp16.safetensors", "target": "vae"},
            {"repo": "Comfy-Org/HunyuanVideo_1.5_repackaged",
             "file": "split_files/clip_vision/sigclip_vision_patch14_384.safetensors",
             "target": "clip_vision"},
        ],
        "size_gb": 20.06,
        "vram_gb": 12,
        "license": "Tencent Hunyuan Community License",
        "commercial_ok": False,
        "warning": "Lizenz gilt nicht in der EU, Großbritannien und Südkorea · sonst kommerziell bis 100 Mio. Nutzer",
        "best_for": "Ausprobieren: 720p Bild-zu-Video für ein Drittel der Wan-2.2-Größe",
        "description": (
            "NICHT KOMMERZIELL EINSETZBAR — dieselbe Tencent-Lizenz wie die T2V-Variante, "
            "mit ausdrücklichem Ausschluss der EU. Nur zum Testen und Vergleichen nehmen; "
            "was ins Spiel soll, mit Wan 2.2 I2V A14B (Apache-2.0) neu erzeugen.\n\n"
            "Belebt ein Startbild direkt in 720p und braucht dafür nur 19,7 GB Download "
            "statt der 33 GB von Wan 2.2 I2V. Das Startbild geht über SigCLIP-Vision ins "
            "Conditioning, dessen Datei hier zusätzlich geladen wird. Ebenfalls "
            "CFG-destilliert, läuft also mit cfg 1.0."
        ),
        "pros": [
            "720p Bild-zu-Video bei nur 7,8 GB Modellgröße",
            "Nur gut halb so großer Download wie Wan 2.2 I2V A14B",
            "Kein Expertenwechsel mitten im Lauf — spürbar zügiger als Wan 2.2 I2V",
        ],
        "cons": [
            "Lizenz gilt nicht in der EU, Großbritannien und Südkorea; Ausgaben dürfen kein anderes KI-Modell trainieren",
            "negative_prompt wirkt nicht (cfg 1.0)",
            "Braucht zwingend ein Startbild",
            "Vier Dateien, davon drei große",
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
            "nur der Workflow-Builder in NV-AI fehlt noch."
        ),
        "pros": [
            "Beste lokal erreichbare Mesh-Qualität",
            "Nodes bereits nativ vorhanden — kein Zusatz-Setup",
            "GLB-Export direkt nach Unity",
        ],
        "cons": [
            "Workflow-Builder in NV-AI fehlt noch",
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
            "`preprocess=\"none\"` — NV-AI verarbeitet sie dann unverändert weiter.\n\n"
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
            "Braucht eine Tiefenkarte; NV-AI erzeugt selbst keine",
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
            "Foto holt NV-AI die Kanten selbst heraus (`preprocess=\"canny\"`), dafür "
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

ALL_MODELS: list[dict[str, Any]] = (
    IMAGE_MODELS + AUDIO_MODELS + VIDEO_MODELS + MODEL_3D + CONTROLNET_MODELS
)

KIND_LABELS = {"image": "Bild", "audio": "Audio", "video": "Video", "3d": "3D",
               "controlnet": "ControlNet"}


# Empfehlung nach Grafikkarte (registry.gpu_advice). RTX 50 rechnet NVFP4 in Hardware;
# ältere Karten entpacken es Schicht für Schicht und sind deutlich langsamer — dort
# INT8-Fassungen, die ab RTX 20 nativ laufen.
RECOMMENDED_FP4 = ["qwen-image-2512-nvfp4", "flux3-klein-nvfp4"]
RECOMMENDED_OLDER = ["flux3-klein-int8", "z-image-int8"]
