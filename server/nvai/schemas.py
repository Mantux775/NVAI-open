"""Pydantic-Schemas fuer die REST-API. Werden vom MCP-Server wiederverwendet."""
from __future__ import annotations

from typing import Annotated, Any, Literal

from pydantic import BaseModel, Field

JobStatus = Literal["queued", "running", "done", "error", "cancelled"]
JobKind = Literal["txt2img", "img2img", "txt2audio", "txt2video", "img2video", "img23d", "download",
                  "expand_prompt"]
AssetKind = Literal["image", "audio", "video", "mesh", "upload"]
# "controlnet" ist ein Zusatzmodell, kein eigenstaendiger Generator -- es taucht
# deshalb nicht als eigener Modus auf, sondern nur als Auswahl beim Bild.
ModelKind = Literal["image", "audio", "video", "3d", "controlnet", "lora"]


class LoraRef(BaseModel):
    model_id: str = Field(..., description="LoRA aus list_models(kind='lora')")
    strength: float = Field(1.0, ge=-2.0, le=3.0, description="Staerke; 0,6-1,0 ist ueblich")


# ------------------------------------------------------------ Anfragen

class GenerateImageRequest(BaseModel):
    prompt: str = Field(..., description="Positiver Prompt")
    negative_prompt: str = Field(
        "", description="Negativer Prompt. Wirkt nur bei Modellen mit CFG > 1 -- "
                        "features.negative_prompt in /api/models sagt es je Modell"
    )
    model_id: str | None = Field(None, description="Modell aus der Registry; None = aktives")
    width: int = Field(1024, ge=256, le=2560, multiple_of=8)
    height: int = Field(1024, ge=256, le=2560, multiple_of=8)
    steps: int | None = Field(None, ge=1, le=150)
    cfg: float | None = Field(None, ge=0.0, le=30.0)
    seed: int | None = None
    batch_size: int = Field(1, ge=1, le=8)
    sampler: str | None = None
    scheduler: str | None = None

    # --- Bild als Ausgangspunkt (img2img) ---
    image_asset_id: str | None = Field(
        None, description="Vorhandenes Bild als Ausgangspunkt statt Rauschen"
    )
    denoise: float = Field(
        1.0, ge=0.0, le=1.0,
        description="Nur mit image_asset_id: wie stark ueberarbeitet wird. "
                    "0.3 = behutsam, 0.6 = deutlich, 1.0 = das Bild wird verworfen",
    )
    mask_asset_id: str | None = Field(
        None,
        description="Nur mit image_asset_id: Maske, weiss = neu erzeugen, schwarz = behalten. "
                    "Graustufen gehen stufenlos ueber. Macht aus Bild-zu-Bild ein Inpainting; "
                    "mit denoise 1.0 entsteht im weissen Bereich voellig neuer Inhalt",
    )
    outpaint: list[Annotated[int, Field(ge=0, le=1024)]] | None = Field(
        None, min_length=4, max_length=4,
        description="Nur mit image_asset_id: Bild ueber den Rand hinaus erweitern (Outpainting), "
                    "[links, oben, rechts, unten] in Pixeln, je 0-1024. Breite und Hoehe ergeben "
                    "sich aus Bild plus Rand; den Rest setzt der Server. Der Prompt beschreibt das "
                    "ganze erweiterte Bild. Nahtlos mit Modellen mit Referenzbildern (FLUX 3); "
                    "Maskenmodelle (Qwen-Image-2512) lassen oft eine Kante am alten Bildrand",
    )

    # --- FLUX 3: Prompt-Upsampler und Referenzbilder ---
    upsample_prompt: bool | None = Field(
        None, description="Nur FLUX 3: den Prompt vorher vom mitgelieferten Upsampler zur vollen "
                          "Bildbeschreibung ausbauen lassen. None = Modellstandard (an)"
    )
    reference_asset_ids: list[str] = Field(
        default_factory=list, max_length=10,
        description="Nur FLUX 3 und Qwen-Image 2.1: bis zu 10 Bild-Assets als Referenz -- zum "
                    "Bearbeiten, fuer gleichbleibende Figuren oder zum Kombinieren. Im Prompt "
                    "als 'the first image', 'the second image' ansprechen (Qwen-Image 2.1: "
                    "'<image1>', '<image2>')",
    )

    # --- Zweiter Durchgang (Hires-Fix) ---
    hires: bool = Field(
        False, description="Zweiter Sampling-Durchgang auf hochskaliertem Latent. "
                           "Rechnet Haende, Gesichter und Details neu"
    )
    hires_scale: float = Field(
        1.25, ge=1.05, le=2.0,
        description="Vergroesserungsfaktor. 1.25 ist auf 16 GB die sichere Stufe",
    )
    hires_denoise: float = Field(0.45, ge=0.1, le=1.0, description="Staerke des zweiten Durchgangs")
    hires_steps: int | None = Field(
        None, ge=1, le=150, description="Schritte im zweiten Durchgang; None = die Haelfte"
    )

    # --- Skip Layer Guidance (nur SD3) ---
    slg: bool = Field(
        False, description="SkipLayerGuidanceSD3: Stabilitys Eingriff fuer stabilere Anatomie. "
                           "Wirkt nur bei SD3-Modellen, kostet ~7 Prozent Laufzeit"
    )
    slg_scale: float = Field(3.0, ge=0.0, le=10.0)
    slg_layers: str = Field("7, 8, 9", description="Zu ueberspringende Bloecke")
    slg_start: float = Field(0.01, ge=0.0, le=1.0)
    slg_end: float = Field(0.15, ge=0.0, le=1.0)

    # --- ControlNet: Form aus einem Referenzbild erzwingen ---
    controlnet_model_id: str | None = Field(
        None, description="ControlNet-Eintrag aus dem Katalog, z. B. sd35-controlnet-depth"
    )
    controlnet_image_asset_id: str | None = Field(
        None, description="Referenzbild fuer das ControlNet (Skizze, Blaupause, Foto)"
    )
    controlnet_strength: float = Field(0.7, ge=0.0, le=2.0)
    controlnet_start: float = Field(0.0, ge=0.0, le=1.0)
    controlnet_end: float = Field(
        0.8, ge=0.0, le=1.0,
        description="Ab wann das ControlNet loslaesst. Frueher loslassen = mehr Freiheit im Detail",
    )
    controlnet_preprocess: Literal["none", "canny"] = Field(
        "none",
        description="Referenzbild vorverarbeiten. 'canny' erzeugt Kanten aus Foto oder "
                    "Skizze. 'none' nimmt das Bild unveraendert -- richtig fuer eine "
                    "fertige Tiefenkarte, etwa aus Blender oder einem Blockout",
    )
    controlnet_canny_low: float = Field(0.4, ge=0.01, le=0.99)
    controlnet_canny_high: float = Field(0.8, ge=0.01, le=0.99)

    loras: list[LoraRef] = Field(
        default_factory=list, max_length=8,
        description="LoRAs (kind 'lora' in list_models), die zum Modell passen; je mit Staerke",
    )


class GenerateAudioRequest(BaseModel):
    prompt: str = Field(..., description="Klangbeschreibung (SFX) oder Genre-Tags (Musik)")
    negative_prompt: str = Field("", description="Was vermieden werden soll")
    lyrics: str = Field("", description="Nur ACE-Step: Songtext. Leer = instrumental")
    model_id: str | None = None
    seconds: float = Field(10.0, gt=0, le=300, description="Laenge in Sekunden")
    steps: int | None = Field(None, ge=1, le=200)
    cfg: float | None = Field(None, ge=0.0, le=30.0)
    seed: int | None = None
    # Nur ACE-Step 1.5
    bpm: int | None = Field(None, ge=40, le=240)
    time_signature: Literal["2", "3", "4", "6"] | None = Field(
        None, description="Time signature: 2 = 2/4, 3 = 3/4, 4 = 4/4, 6 = 6/8. Empty = 4/4")
    key_scale: str | None = Field(
        None, pattern=r"^(C|C#|Db|D|D#|Eb|E|F|F#|Gb|G|G#|Ab|A|A#|Bb|B) (major|minor)$",
        description='Key, e.g. "Bb major". Empty = C major')
    language: str = "en"


class GenerateVideoRequest(BaseModel):
    prompt: str
    negative_prompt: str = Field(
        "", description="Leer = modellspezifischer Standard-Negativprompt"
    )
    model_id: str | None = None
    # Bis 1920: LTX-2.5 rechnet 1080p (features.sizes des Modells); die anderen Modelle bleiben
    # bei ihren eigenen Formaten.
    width: int = Field(832, ge=256, le=1920, multiple_of=16)
    height: int = Field(480, ge=256, le=1920, multiple_of=16)
    frames: int = Field(49, ge=9, le=481,
                        description="Anzahl Frames; Wan 4n+1, LTX 8n+1 (481 = 20 s bei 24 fps)")
    fps: int = Field(16, ge=1, le=60)
    steps: int | None = Field(None, ge=1, le=100)
    cfg: float | None = Field(None, ge=0.0, le=30.0)
    seed: int | None = None
    image_asset_id: str | None = Field(
        None, description="Fuer Bild-zu-Video: Asset-ID des Startbilds"
    )

    loras: list[LoraRef] = Field(
        default_factory=list, max_length=8,
        description="LoRAs (kind 'lora' in list_models), die zum Modell passen; je mit Staerke",
    )

    # LTX-2.5 (features des Modells: end_image, loop, dfr, temporal_upscale, auto_duration,
    # audio_input, motion_speed). Andere Modelle lehnen die Felder mit einer Meldung ab.
    end_image_asset_id: str | None = Field(
        None, description="LTX-2.5: Endbild (letzter Frame); mit image_asset_id ein Uebergang")
    loop: bool = Field(False, description="LTX-2.5: Schleife -- das Startbild ist auch das Endbild")
    quality: Literal["standard", "full", "dfr"] = Field(
        "standard", description="LTX-2.5: dfr = Diffusion Fidelity Rendering, mehr Detail, langsamer; "
                                "full = Versuch, eine Stufe in voller Aufloesung (gemessen nicht "
                                "durchgehend schaerfer, 56 % laenger)")
    temporal_upscale: bool = Field(
        False, description="LTX-2.5 mit quality=dfr: doppelte Bildrate bei gleicher Dauer (24 -> 48 fps)")
    auto_duration: bool = Field(
        False, description="LTX-2.5: Laenge aus dem Prompt vorhersagen; frames gilt dann nicht")
    audio_asset_id: str | None = Field(
        None, description="LTX-2.5: Ton vorgeben (Asset-ID einer Audiodatei). Das Bild folgt dem Ton, "
                          "die Laenge auch (hoechstens 20 s)")
    motion_speed: float = Field(
        1.0, gt=0.0, le=1.0, description="LTX-2.5: Zeitlupe, 1 = Echtzeit, 0.5 = 2x, 0.2 = 5x, 0.1 = 10x "
                                          "langsamer; verlaesslich mit der Slow-Motion-LoRA")
    crf: float | None = Field(
        None, ge=0.0, le=51.0, description="LTX-2.5: H.264-Qualitaet des MP4 (CRF), kleiner = besser und "
                                            "groessere Datei; leer = workflows.VIDEO_CRF")
    extend_asset_id: str | None = Field(
        None, description="LTX-2.5: ein vorhandenes Video fortsetzen (seit 0.5.10). Sein letzter Frame wird "
                          "Startbild, Format und Bildrate kommen von ihm; das neue Stueck wird samt Ton "
                          "angehaengt. Ergebnis: das verlaengerte Video und das neue Stueck einzeln")


ExpandTarget = Literal["image", "video", "video_sound", "video_multishot", "video_start", "sfx", "music",
                       "music_sa3", "3d"]


class ExpandPromptRequest(BaseModel):
    prompt: str = Field(..., min_length=1, description="Knapper Prompt, der ausgebaut werden soll")
    target: ExpandTarget = Field(
        "image",
        description="Wofuer: image (Bildbeschreibung), video (Wan, LTX-Video), video_sound "
                    "(LTX-2.5, mit Ton), video_multishot (LTX-2.5, 2-4 Einstellungen mit Schnitten "
                    "und Ton), video_start (nur Bewegung, liest das Startbild in "
                    "reference_asset_ids mit), sfx (Stable Audio), music (ACE-Step-Tags), "
                    "3d (Bild fuer ein Mesh: ein Objekt, kein Boden, kein Schatten)",
    )
    width: int = Field(1024, ge=256, le=2048, multiple_of=8,
                       description="Geplantes Format -- der Upsampler richtet den Bildaufbau danach")
    height: int = Field(1024, ge=256, le=2048, multiple_of=8)
    reference_asset_ids: list[str] = Field(
        default_factory=list, max_length=10,
        description="Optional: Bilder, die der Upsampler mitliest (Bearbeiten mit FLUX 3, "
                    "Startbild bei video_start)",
    )


class ExpandPromptResult(BaseModel):
    prompt: str = Field(..., description="Der eingegebene Prompt")
    expanded: str = Field(..., description="Der ausgebaute Prompt, fuer jedes Modell des Ziels")
    seconds: float = Field(..., description="Dauer inklusive Warten auf die GPU")


class ProblemReportRequest(BaseModel):
    description: str = Field("", max_length=4000, description="Kurze Fehlerbeschreibung des Nutzers")


class ProblemReportSummary(BaseModel):
    version: str
    os: str
    graphics: str
    driver: str
    last_error: str | None = None
    time: str


class ProblemReport(BaseModel):
    filename: str = Field(..., description="Vorschlag fuer den Dateinamen, nvai-report-<Zeit>.txt")
    text: str = Field(..., description="Der anonymisierte Bericht")
    created_at: float
    summary: ProblemReportSummary
    issues_url: str = Field(..., description="Wo neue Issues angelegt werden (GitHub)")


# ------------------------------------------------------------ Ergebnis

class Generate3DRequest(BaseModel):
    image_asset_id: str = Field(..., description="Asset-ID des Quellbilds (Bild oder Upload)")
    model_id: str | None = None
    steps: int = Field(50, ge=1, le=200, description="Nur TripoSG")
    guidance: float = Field(7.0, ge=0.0, le=20.0, description="Nur TripoSG")
    seed: int | None = None
    faces: int = Field(
        -1, description="Zielanzahl Faces nach Reduktion; -1 = volles Mesh (nur TripoSG)"
    )
    remove_background: bool = Field(
        True, description="Hintergrund automatisch freistellen, wenn kein Alphakanal da ist"
    )
    project_front: bool = Field(
        False, description="Vorderseite aus dem Bild: das freigestellte Quellbild auf die zur Kamera "
                           "zeigenden, sichtbaren Flaechen projizieren, damit Schrift lesbar bleibt "
                           "(seit 0.5.10). Der Rest bekommt Farben aus dem weichgezeichneten Bild "
                           "(TripoSG) bzw. behaelt seine Textur (TRELLIS.2)"
    )
    # Nur TRELLIS.2
    resolution: int = Field(
        512, description="Voxel-Aufloesung. 1024 braucht deutlich mehr als 16 GB VRAM."
    )
    texture_size: int = Field(2048, ge=512, le=4096, description="Nur TRELLIS.2: Texturaufloesung")
    background_mode: Literal["birefnet", "flood", "alpha"] = Field(
        "birefnet",
        description="Wie freigestellt wird. birefnet = Segmentierungsmodell (sauberste "
                    "Kanten, verhindert Hintergrund-Artefakte im Mesh); flood = schneller "
                    "Randfarben-Fuellalgorithmus; alpha = Bild bringt Alphakanal mit.",
    )
    clean_specks: bool = Field(
        True,
        description="Nur TRELLIS.2: die schwarzen Nadeln entfernen. Verworfen werden "
                    "kleine UND langgestreckte Teilkoerper; kompakte Kleinteile wie "
                    "Augen oder Beschlaege bleiben erhalten.",
    )
    speck_ratio: float = Field(
        0.02, ge=0.0, le=0.5,
        description="Ab welchem Flaechenanteil der groessten Komponente ein Teil als "
                    "'klein' gilt. Groesser = aggressiver.",
    )


class Job(BaseModel):
    id: str
    kind: JobKind
    status: JobStatus
    progress: float = 0.0
    stage: str = ""
    params: dict[str, Any] = {}
    asset_ids: list[str] = []
    error: str | None = None
    created_at: float
    started_at: float | None = None
    finished_at: float | None = None


class Asset(BaseModel):
    id: str
    job_id: str | None
    kind: AssetKind
    filename: str
    url: str
    thumb_url: str | None = None
    prompt: str = ""
    model_id: str = ""
    meta: dict[str, Any] = {}
    created_at: float


# -------------------------------------------------------------- Modelle

class ModelFile(BaseModel):
    repo: str
    file: str
    target: str
    installed: bool = False
    local_path: str | None = None
    size_gb: float | None = None
    # Name der Zusatzfunktion, die diese Datei freischaltet (z. B. "dfr"); None = Pflichtdatei
    optional: str | None = None


class ModelInfo(BaseModel):
    id: str
    name: str
    kind: ModelKind
    family: str
    workflow: str | None = None
    files: list[ModelFile] = []
    size_gb: float
    vram_gb: float = 0
    license: str
    commercial_ok: bool
    # Gesetzt, wenn vor dem Einsatz etwas zu beachten ist (z. B. Lizenzausschluss).
    # Das Frontend zeigt den Text als rotes Ausrufezeichen am Modell.
    warning: str = ""
    best_for: str = ""
    description: str = ""
    pros: list[str] = []
    cons: list[str] = []
    installed: bool = False
    partially_installed: bool = False
    disk_gb: float = 0
    runnable: bool = False
    favorite: bool = False
    # Passt das Modell auf die erkannte Karte? "ja" | "knapp" | "nein" | "unklar"
    fits_vram: str = "unklar"
    # Fuer diese Kartengeneration empfohlen (RTX 50: NVFP4, sonst INT8) -- registry.gpu_advice
    recommended: bool = False
    # Hinweis, wenn das Format auf dieser Karte nicht in Hardware rechnet; sonst leer
    gpu_note: str = ""
    # Zensiert oder nicht (Bild und Video): "uncensored" | "partial" | "censored", None = unbekannt.
    # Mit Beleg und Quelle -- siehe content.py
    content: str | None = None
    content_note: str = ""
    content_source: str = ""
    # Was das Modell beim Generieren kann und wie man es anspricht -- Grundlage fuer die
    # Bedienelemente im Frontend und fuer Claude ueber list_models. Siehe
    # registry.features_for.
    features: dict[str, Any] = {}
    # Generatoren: welche LoRA-Basen sie nehmen (leer = keine). LoRAs: ihre Basis steht in
    # family, dazu Trigger-Woerter und die Quelle.
    lora_bases: list[str] = []
    trigger: str = ""
    source_url: str = ""


class DownloadRequest(BaseModel):
    model_id: str | None = Field(None, description="Eintrag aus dem Katalog")
    repo: str | None = Field(None, description="Freies HF-Repo, falls nicht im Katalog")
    file: str | None = None
    target: str = "checkpoints"
    kind: ModelKind = "image"
    family: str = "sdxl"
    workflow: str | None = "sdxl"
    # Aus der Pruefung (GET /api/models/inspect), damit der Katalog sie zeigt
    license: str | None = None
    size_gb: float | None = None
    # LoRAs: Trigger-Woerter und Herkunft (Hugging Face oder Civitai)
    trigger: str = ""
    source_url: str | None = None
    url: str | None = Field(None, description="Direkter Download (Civitai) statt repo+file")
    clean: bool = Field(
        False, description="Alten/unvollstaendigen Stand vorher loeschen und frisch laden"
    )


class DeleteResult(BaseModel):
    model_id: str
    removed: list[str] = []
    freed_gb: float = 0
    failed: list[str] = []


class VersionInfo(BaseModel):
    """GET /api/version -- ohne Token abrufbar."""
    name: str
    version: str
    api: int = Field(description="Vertragsversion; steigt nur bei brechenden Aenderungen")
    features: list[str] = Field(
        description="Anfragefelder, die dieser Server kennt: mask, references, upsampler ..."
    )
    comfyui: str | None = Field(None, description="Installierte ComfyUI-Version")
    auth: Literal["token", "local"] = Field(
        description="token: andere Geraete brauchen X-NVAI-Token; local: nur dieser Rechner"
    )
    authorized: bool = Field(description="Kaeme diese Anfrage mit ihrem Token durch?")
    instance: str = Field(
        "", description="Kennung dieser Installation (Hash des Programmordners). Der Starter "
                        "erkennt daran, ob das NVAI-open auf dem Port sein eigenes ist."
    )
