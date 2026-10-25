"""Modell-Registry: Katalog, Download, Loeschen, aktives Modell je Kategorie.

Ein Modell besteht aus 1..n Dateien (moderne Video-Modelle sind in Diffusion-Model,
Text-Encoder und VAE aufgeteilt). Installiert = alle Pflichtdateien liegen lokal; optionale
schalten nur Zusatzfunktionen frei (siehe is_installed).
"""
from __future__ import annotations

import json
import logging
import os
import re
import threading
import contextlib
import time
from pathlib import Path
from typing import Any, Callable

from huggingface_hub import hf_hub_download, snapshot_download

from . import catalog, config, content, gpu, i18n, loras, workflows
from .catalog import ALL_MODELS
from .i18n import t

try:
    from .catalog_en import EN as _EN, SIZE_LABELS as _SIZE_LABELS
except ImportError:   # die englischen Texte fehlen noch -- dann bleibt alles deutsch
    _EN, _SIZE_LABELS = {}, {}
from .schemas import ModelFile, ModelInfo

log = logging.getLogger(__name__)

_USER_CATALOG = config.DATA_DIR / "custom_models.json"
_ACTIVE_FILE = config.DATA_DIR / "active_models.json"
_FAVORITES_FILE = config.DATA_DIR / "favorites.json"
_state_lock = threading.RLock()


# ----------------------------------------------------------- Favoriten

def get_favorites() -> set[str]:
    if _FAVORITES_FILE.exists():
        try:
            return set(json.loads(_FAVORITES_FILE.read_text(encoding="utf-8")))
        except (json.JSONDecodeError, TypeError):
            return set()
    return set()


def set_favorite(model_id: str, value: bool) -> bool:
    """Markiert ein Modell als Favorit. Gibt den neuen Zustand zurueck."""
    with _state_lock:
        favs = get_favorites()
        if value:
            favs.add(model_id)
        else:
            favs.discard(model_id)
        config.ensure_dirs()
        _FAVORITES_FILE.write_text(json.dumps(sorted(favs), indent=2), encoding="utf-8")
        return value


# ------------------------------------------------------------- Katalog

def _load_user_catalog() -> list[dict[str, Any]]:
    if _USER_CATALOG.exists():
        try:
            return json.loads(_USER_CATALOG.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            return []
    return []


def _save_user_catalog(entries: list[dict[str, Any]]) -> None:
    config.ensure_dirs()
    _USER_CATALOG.write_text(json.dumps(entries, indent=2), encoding="utf-8")


_CATALOG_IDS = {e["id"] for e in ALL_MODELS}


def all_entries() -> list[dict[str, Any]]:
    # Ein Nutzereintrag mit der ID eines festen Eintrags (etwa eine empfohlene LoRA, die vorher
    # ueber die Suche geladen wurde) tritt hinter den festen zurueck -- sonst stuende sie doppelt da.
    return ALL_MODELS + [e for e in _load_user_catalog() if e["id"] not in _CATALOG_IDS]


def get_entry(model_id: str) -> dict[str, Any] | None:
    for e in all_entries():
        if e["id"] == model_id:
            return e
    return None


def file_path(f: dict[str, Any]) -> Path:
    """Zielpfad einer Modelldatei bzw. eines Snapshot-Ordners.

    Normalfall: ComfyUI sucht flach in models/<target>/, der Repo-Unterordner
    wird also abgeschnitten. Mit "as" laesst sich der Zielname erzwingen.

    Snapshot-Modus (`"snapshot": True`): das ganze Repo landet als Ordner unter
    data/models/<target>/ -- noetig fuer Worker, die from_pretrained() nutzen.
    """
    if f.get("snapshot"):
        return config.MODELS_DIR / f["target"]
    name = f.get("as") or Path(f["file"]).name
    return config.COMFY_MODEL_DIR / f["target"] / name


def _file_installed(f: dict[str, Any]) -> bool:
    p = file_path(f)
    if f.get("snapshot"):
        # Ein Ordner allein sagt nichts -- die Marker-Datei entscheidet.
        return (p / f.get("check", "config.json")).exists()
    return p.exists()


def _size_gb(p: Path) -> float:
    if p.is_dir():
        total = sum(f.stat().st_size for f in p.rglob("*") if f.is_file())
    elif p.is_file():
        total = p.stat().st_size
    else:
        return 0.0
    return round(total / 1024**3, 2)


def entry_files(entry: dict[str, Any]) -> list[ModelFile]:
    out = []
    for f in entry["files"]:
        p = file_path(f)
        installed = _file_installed(f)
        out.append(ModelFile(
            repo=f["repo"], file=f.get("file") or f"{f['target']}/ (ganzes Repo)",
            target=f["target"],
            installed=installed, local_path=str(p) if installed else None,
            size_gb=_size_gb(p) if installed else None,
            optional=f.get("optional"),
        ))
    return out


def is_installed(entry: dict[str, Any]) -> bool:
    """Alle Pflichtdateien da. Optionale ("optional": Name der Funktion) schalten nur eine
    Zusatzfunktion frei, etwa das Detail-IC-LoRA fuer DFR bei LTX-2.5 -- das liegt in einem eigenen
    Repo mit eigener Freigabe auf Hugging Face; ohne sie soll das Modell trotzdem laufen."""
    return all(_file_installed(f) for f in entry["files"] if not f.get("optional"))


def optional_status(entry: dict[str, Any]) -> dict[str, bool]:
    """Je Zusatzfunktion: sind ihre optionalen Dateien da?"""
    out: dict[str, bool] = {}
    for f in entry["files"]:
        if f.get("optional"):
            out[f["optional"]] = out.get(f["optional"], True) and _file_installed(f)
    return out


def features_for(entry: dict[str, Any]) -> dict[str, Any]:
    """Was ein Modell beim Generieren kann -- abgeleitet aus seinem Workflow, ergaenzt um
    die Angaben im Katalogeintrag ("features").

    Schluessel:
      steps, cfg          Standardwerte des Workflows
      negative_prompt     wirkt der negative Prompt? Nur bei CFG > 1
      default_negative    greift, wenn keiner angegeben ist
      upsampler           baut ein Prompt-Upsampler den Prompt vorher aus (FLUX 3)
      references          wie viele Referenzbilder es nimmt (0 = keine)
      reference_kind      "style": Referenzen geben nur den Stil vor (Krea 2); sonst wird bearbeitet
      missing             Zusatzfunktion -> Hugging-Face-Seite, solange ihre optionalen Dateien fehlen
      bbox                Platzierung per Bounding-Box-Tabelle im Prompt
      img2img             Startbild + denoise
      mask                Inpainting mit mask_asset_id (laeuft ueber den Startbild-Pfad)
      hires               zweiter Durchgang sinnvoll
      text_rendering      Schrift im Bild gelingt
      sizes               zusaetzliche, fuer dieses Modell empfohlene Formate
      prompt_hint         Kurzanleitung zum Prompt, deutsch
      placeholder         Beispielprompt
    """
    wf = entry.get("workflow")
    if entry.get("kind") != "image" or wf not in workflows.IMAGE_WORKFLOWS:
        feats = dict(entry.get("features") or {})
        # Zusatzfunktionen mit optionalen Dateien gelten nur, wenn die Dateien da sind; sonst steht
        # unter "missing" die Seite, auf der die Freigabe bzw. der Download wartet.
        for name, ok in optional_status(entry).items():
            feats[name] = bool(feats.get(name, True)) and ok
            if not ok:
                repo = next(f["repo"] for f in entry["files"] if f.get("optional") == name)
                feats.setdefault("missing", {})[name] = f"https://huggingface.co/{repo}"
        if i18n.lang() != "de" and feats.get("sizes"):
            feats["sizes"] = [s | {"label": _SIZE_LABELS.get(s.get("label", ""), s.get("label", ""))}
                              for s in feats["sizes"]]
        return feats
    d = workflows.defaults_for(wf)
    base: dict[str, Any] = {
        "steps": d["steps"], "cfg": d["cfg"], "negative_prompt": d["cfg"] > 1.0,
        "default_negative": workflows.DEFAULT_NEGATIVES.get(wf, ""),
        "upsampler": False, "references": 0, "bbox": False,
        "img2img": True, "hires": True, "text_rendering": False, "sizes": [],
        "prompt_hint": "", "placeholder": "",
    }
    merged = base | (entry.get("features") or {})
    # Zusatzfunktionen mit optionalen Dateien (seit 0.5.10: Stil-Referenz fuer Krea 2) gelten erst,
    # wenn die Dateien da sind; "with_optional" sagt, was sie freischalten. Fehlen sie, steht unter
    # "missing" die Seite, von der sie kommen (Laden: das Modell unter "Modelle" erneut laden).
    extra = merged.pop("with_optional", {})
    for name, ok in optional_status(entry).items():
        merged[name] = ok
        if ok:
            merged |= extra.get(name, {})
        else:
            repo = next(f["repo"] for f in entry["files"] if f.get("optional") == name)
            merged.setdefault("missing", {})[name] = f"https://huggingface.co/{repo}"
    # Masken (Inpainting): True laeuft ueber denselben Startbild-Pfad wie Bild-zu-Bild.
    # "reference" (seit 0.5.6): Bearbeitungsmodelle wie FLUX 3 fuellen ueber ein grau markiertes
    # Referenzbild, NVAI-open richtet das Ergebnis aus (jobs._prepare_inpaint_reference). Getestet mit
    # FLUX 3; die anderen Bearbeitungsmodelle stehen im Katalog ausdruecklich auf False.
    merged.setdefault("mask", "reference" if merged.get("references") else bool(merged.get("img2img")))
    # Outpainting: "reference" (Bearbeitungsmodell, nahtlos), "mask" (Qwen u. a., oft mit
    # Kante am alten Bildrand) oder None. Siehe jobs._prepare_outpaint.
    merged.setdefault("outpaint", "reference" if merged.get("references") else
                      "mask" if merged.get("mask") else None)
    if i18n.lang() != "de" and merged.get("sizes"):
        merged["sizes"] = [s | {"label": _SIZE_LABELS.get(s.get("label", ""), s.get("label", ""))}
                           for s in merged["sizes"]]
    return merged


def _custom_texts(entry: dict[str, Any]) -> dict[str, Any]:
    """Texte eines selbst hinzugefuegten Modells -- erst bei der Ausgabe in der Sprache der
    Anfrage erzeugt, damit sie nicht in der Sprache der Registrierung haengen bleiben."""
    repo = entry["files"][0]["repo"]
    manual = entry.get("best_for") == "manuell hinzugefügt"
    texts: dict[str, Any] = {
        "best_for": t("manuell hinzugefügt", "added manually") if manual
        else t("von Hugging Face hinzugefügt", "added from Hugging Face"),
        "description": t(f"Aus der Suche hinzugefügt: https://huggingface.co/{repo}\n\n"
                         "Die Lizenz bitte im Repo prüfen, bevor Bilder veröffentlicht werden.",
                         f"Added from the search: https://huggingface.co/{repo}\n\n"
                         "Please check the license in the repo before publishing images."),
        "cons": [t("Nicht von NVAI-open getestet; die Lizenz steht nur im Repo",
                   "Not tested by NVAI-open; the license is only stated in the repo")],
    }
    if entry.get("kind") == "lora":
        base = loras.BASES.get(entry["family"], entry["family"])
        source = entry.get("source_url") or f"https://huggingface.co/{repo}"
        texts.update({
            "best_for": t(f"LoRA für {base}", f"LoRA for {base}"),
            "description": t(f"LoRA für {base}, hinzugefügt aus {source}\n\nDie Lizenz bitte dort "
                             "prüfen, bevor Ergebnisse veröffentlicht werden.",
                             f"LoRA for {base}, added from {source}\n\nPlease check the license "
                             "there before publishing results."),
            "cons": [t("Nicht von NVAI-open getestet; die Lizenz steht nur an der Quelle",
                       "Not tested by NVAI-open; the license is only stated at the source")],
        })
    if entry.get("license") == "siehe Repo":
        texts["license"] = t("siehe Repo", "see repo")
    if entry.get("family") == "sd15":
        texts["features"] = (entry.get("features") or {}) | {"prompt_hint": t(
            "SD 1.5 ist auf 512 × 512 trainiert; größere Formate erzeugen doppelte Motive.",
            "SD 1.5 is trained on 512 × 512; larger sizes produce duplicated subjects.")}
    return texts


def display_name(entry: dict[str, Any]) -> str:
    """Modellname in der Sprache der Anfrage -- fuer Meldungen, Fortschritt und Asset-Meta."""
    return localized(entry)["name"]


def localized(entry: dict[str, Any]) -> dict[str, Any]:
    """Katalogeintrag in der Sprache der Anfrage. catalog.py ist die deutsche Quelle,
    catalog_en.py liefert die englischen Texte; was dort fehlt, bleibt deutsch."""
    if entry.get("custom"):
        return entry | _custom_texts(entry)
    if i18n.lang() == "de":
        return entry
    over = _EN.get(entry["id"])
    if not over:
        return entry
    out = dict(entry)
    for key in ("name", "best_for", "description", "pros", "cons", "warning", "license"):
        if key in over:
            out[key] = over[key]
    if "features" in over:
        out["features"] = (entry.get("features") or {}) | over["features"]
    return out


def installed_files() -> set[Path]:
    """Alle Dateien, die ein vollstaendig installiertes Modell braucht (aufgeloeste Pfade)."""
    keep: set[Path] = set()
    upsampler_in_use = False
    for e in all_entries():
        if is_installed(e):
            for f in e["files"]:
                with contextlib.suppress(OSError):
                    keep.add(file_path(f).resolve())
                upsampler_in_use |= "prompt_upsampler" in f.get("file", "")
    if upsampler_in_use:
        # Die Upsampler-Fassungen sind austauschbar (jobs.prompt_upsampler waehlt nach Karte); die
        # kleine w4a8 gehoert im Katalog zu flux3-klein-int8 und waere sonst ein "Rest".
        for e in all_entries():
            for f in e["files"]:
                if "prompt_upsampler" in f.get("file", "") and _file_installed(f):
                    with contextlib.suppress(OSError):
                        keep.add(file_path(f).resolve())
    return keep


def own_leftovers(entry: dict[str, Any], shared: set[Path]) -> list[Path]:
    """Was von einem nicht vollstaendigen Modell wirklich ihm allein gehoert: vorhandene Dateien,
    die kein installiertes Modell braucht, und Download-Fragmente (*.incomplete).

    Geteilte Dateien (Text-Encoder, VAE eines installierten Modells) zaehlen nicht. Vorher galt
    jedes Modell mit irgendeiner vorhandenen Datei als "unvollstaendig"; das Aufraeumen durfte die
    geteilten Dateien zu Recht nicht loeschen, meldete aber trotzdem "aufgeraeumt" -- und beim
    naechsten Mal dieselben Modelle wieder (Nutzermeldung 23.10.2026).
    """
    out: list[Path] = []
    for f in entry["files"]:
        p = file_path(f)
        with contextlib.suppress(OSError):
            if _file_installed(f) and p.resolve() not in shared:
                out.append(p)
        if not f.get("snapshot") and p.parent.exists():
            out.extend(p.parent.glob(f"{p.stem}*.incomplete"))
    return out


def to_info(entry: dict[str, Any], favorites: set[str] | None = None,
            shared: set[Path] | None = None) -> ModelInfo:
    files = entry_files(entry)
    installed = all(f.installed for f in files if not f.optional)
    partial = False
    if not installed:
        partial = bool(own_leftovers(entry, installed_files() if shared is None else shared))
    favs = get_favorites() if favorites is None else favorites
    text = localized(entry)
    return ModelInfo(
        favorite=entry["id"] in favs,
        id=entry["id"],
        name=text["name"],
        kind=entry["kind"],
        family=entry["family"],
        workflow=entry.get("workflow"),
        files=files,
        size_gb=entry["size_gb"],
        vram_gb=entry.get("vram_gb", 0),
        license=text["license"],
        commercial_ok=entry["commercial_ok"] or (
            bool(entry.get("custom")) and commercial_from_license(entry.get("license"))),
        warning=text.get("warning", ""),
        best_for=text.get("best_for", ""),
        description=text.get("description", ""),
        pros=text.get("pros", []),
        cons=text.get("cons", []),
        installed=installed,
        partially_installed=partial,
        disk_gb=round(sum(f.size_gb or 0 for f in files), 2),
        runnable=installed and entry.get("workflow") is not None,
        fits_vram=gpu.fits(entry.get("vram_gb", 0)),
        features=features_for(text),
        lora_bases=list(loras.bases_for(entry)),
        trigger=entry.get("trigger", ""),
        source_url=entry.get("source_url", ""),
        **gpu_advice(entry),
        **content.lookup(entry["id"]),
    )


def _precision(entry: dict[str, Any]) -> str | None:
    """Rechenformat des Hauptmodells, aus den Dateinamen: nvfp4, fp8 oder int8."""
    names = " ".join(f["file"].lower() for f in entry.get("files", [])
                     if f.get("target") in ("diffusion_models", "checkpoints"))
    for fmt in ("nvfp4", "fp8", "int8"):
        if fmt in names:
            return fmt
    return None


def gpu_advice(entry: dict[str, Any]) -> dict[str, Any]:
    """Empfehlung und Hinweis fuer die erkannte Karte.

    RTX 50 (compute capability ab 10) rechnet NVFP4 in Hardware. Aeltere Karten laden
    NVFP4 zwar, entpacken es aber Schicht fuer Schicht nach bf16 (comfy/ops.py) -- das
    spart Speicher, kostet aber Tempo. FP8 rechnet erst ab RTX 40 (8.9) in Hardware.
    INT8 laeuft ab RTX 20 (7.5) ueberall nativ.
    """
    info = gpu.detect()
    if info and info.get("vendor") == "amd":
        return _amd_advice(entry, info)
    cc = info.get("compute_cap") if info else None
    if cc is None:
        return {"recommended": False, "gpu_note": ""}
    fp4 = cc >= 10.0
    picks = list(catalog.RECOMMENDED_FP4 if fp4 else catalog.RECOMMENDED_OLDER)
    slow = not fp4 and (info.get("pcie_gbps") or 99.0) <= SLOW_PCIE_GBPS
    swap = _slow_bus_swap(info) if slow else {}
    picks = [swap.get(i, i) for i in picks]
    note = ""
    fmt = _precision(entry)
    link = f"PCIe {info.get('pcie_gen')} x{info.get('pcie_width')}, {_dec(info.get('pcie_gbps'))} GB/s"
    link_en = f"PCIe {info.get('pcie_gen')} x{info.get('pcie_width')}, {info.get('pcie_gbps')} GB/s"
    if fmt == "nvfp4" and not fp4 and entry["id"] in swap.values():
        note = t(f"{info['name']} hat keine FP4-Einheiten und hängt an einem langsamen Anschluss ({link}). "
                 "Die INT8-Fassung passt nicht in den Grafikspeicher und müsste bei jedem Schritt über den "
                 "Anschluss nachgeladen werden; diese NVFP4-Fassung passt hinein und ist hier schneller "
                 "(gemessen: RTX 4060 am Riser, Krea 2 46 statt 82 s).",
                 f"{info['name']} has no FP4 units and sits on a slow connection ({link_en}). The INT8 "
                 "version does not fit into the graphics memory and would be streamed over the connection "
                 "at every step; this NVFP4 version fits and is faster here (measured: RTX 4060 on a "
                 "riser, Krea 2 46 instead of 82 s).")
    elif fmt == "nvfp4" and not fp4:
        note = t(f"{info['name']} hat keine FP4-Einheiten: das Modell läuft, aber langsamer als auf RTX 50. "
                 "Gedacht sind hier die INT8-Fassungen; gemessen waren sie auch dann schneller, wenn sie "
                 "nicht ganz in den Grafikspeicher passten (Krea 2 mit 8 GB: 13 statt 25 s, "
                 "Qwen-Image-2512 mit 16 GB: 119 statt 214 s).",
                 f"{info['name']} has no FP4 units: the model runs, but slower than on RTX 50. The INT8 "
                 "versions are meant for this card; measured, they were faster even when they did not fit "
                 "completely into the graphics memory (Krea 2 with 8 GB: 13 instead of 25 s, "
                 "Qwen-Image-2512 with 16 GB: 119 instead of 214 s).")
    elif fmt == "int8" and entry["id"] in swap:
        note = t(f"Passt nicht in die {_dec(info.get('vram_total_gb'))} GB von {info['name']}, und der "
                 f"Anschluss ist langsam ({link}): Die NVFP4-Fassung ist hier schneller (gemessen: RTX 4060 "
                 "am Riser, Krea 2 46 statt 82 s).",
                 f"Does not fit into the {info.get('vram_total_gb')} GB of {info['name']}, and the "
                 f"connection is slow ({link_en}): the NVFP4 version is faster here (measured: RTX 4060 on "
                 "a riser, Krea 2 46 instead of 82 s).")
    elif fmt == "fp8" and cc < 8.9:
        note = t(f"{info['name']} hat keine FP8-Einheiten: das Modell wird hochgerechnet "
                 "und läuft langsamer.",
                 f"{info['name']} has no FP8 units: the model is upcast and runs slower.")
    return {"recommended": entry["id"] in picks, "gpu_note": note}


# Empfehlung nach Anschluss (gemessen 25.10.2026, Karte ohne FP4-Einheiten): INT8 war schneller, auch wenn es
# nicht ganz in den Grafikspeicher passte -- nachgestellte RTX 40 an PCIe 4.0 x8: Krea 2 mit 8 GB 13 statt
# 25 s, Qwen-Image-2512 mit 16 GB 119 statt 214 s. Nur am langsamen Anschluss (RTX 4060 am Riser, PCIe 3.0
# x4 = 3,9 GB/s) lohnte NVFP4, wenn nur diese Fassung in den Speicher passte (Krea 2: 46 statt 82 s); passte
# keine, gewann INT8 (Qwen-Image-2512: 653 statt 1095 s).
SLOW_PCIE_GBPS = 4.0


def _dec(value: Any) -> str:
    return str(value).replace(".", ",") if value is not None else "?"


def _slow_bus_swap(info: dict[str, Any]) -> dict[str, str]:
    """INT8-ID -> NVFP4-ID der Paare, bei denen nur die NVFP4-Fassung in den Grafikspeicher passt
    (catalog: model_gb = Hauptdatei in 10^9 Byte)."""
    vram = float(info.get("vram_total_mb") or 0) * 1024 * 1024 / 1e9
    by_id = {e["id"]: e for e in all_entries()}
    swap: dict[str, str] = {}
    for old_id in catalog.RECOMMENDED_OLDER:
        old = by_id.get(old_id)
        if not old or not old.get("model_gb"):
            continue
        twin = next((by_id[i] for i in catalog.RECOMMENDED_FP4
                     if i in by_id and by_id[i].get("family") == old.get("family")), None)
        if twin and twin.get("model_gb") and old["model_gb"] > vram >= twin["model_gb"]:
            swap[old_id] = twin["id"]
    return swap


def _amd_advice(entry: dict[str, Any], info: dict[str, Any]) -> dict[str, Any]:
    """AMD-Karten (ROCm, experimentell seit 0.5): dieselben Empfehlungen wie fuer
    RTX 20/30/40, dazu Hinweise auf das, was dort sicher nicht oder ungetestet laeuft."""
    if entry.get("kind") == "3d":
        return {"recommended": False, "gpu_note": t(
            "3D braucht derzeit eine NVIDIA-Karte: TripoSG und TRELLIS.2 nutzen CUDA-Erweiterungen.",
            "3D currently needs an NVIDIA card: TripoSG and TRELLIS.2 use CUDA extensions.")}
    note = t(f"Auf {info['name']} (ROCm) noch ungetestet -- Rückmeldungen auf GitHub helfen.",
             f"Not tested on {info['name']} (ROCm) yet -- feedback on GitHub helps.")
    if _precision(entry) == "nvfp4":
        note = t("NVFP4 ist ein NVIDIA-Format: auf AMD wird es Schicht für Schicht entpackt und "
                 "läuft deutlich langsamer, falls überhaupt. Besser die INT8- oder FP8-Fassung.",
                 "NVFP4 is an NVIDIA format: on AMD it is unpacked layer by layer and runs much "
                 "slower, if at all. Better use the INT8 or FP8 version.")
    return {"recommended": entry["id"] in catalog.RECOMMENDED_OLDER, "gpu_note": note}


def list_models(kind: str | None = None) -> list[ModelInfo]:
    # Favoriten einmal laden statt je Eintrag von der Platte lesen.
    favs = get_favorites()
    shared = installed_files()
    infos = [to_info(e, favs, shared) for e in all_entries()]
    if kind:
        infos = [m for m in infos if m.kind == kind]
    # Favoriten nach oben, sonst Reihenfolge des Katalogs beibehalten.
    return sorted(infos, key=lambda m: not m.favorite)


def installed_models(kind: str) -> list[ModelInfo]:
    return [m for m in list_models(kind) if m.runnable]


# ------------------------------------------------------------ Download

def hf_token() -> str | None:
    """Umgebungsvariable oder der per `hf auth login` bzw. Weboberflaeche gespeicherte Token.

    Bis 0.1 nur die Variable -- /api/health meldete dann hf_token false, obwohl der
    Download ueber den gespeicherten Token klappte.
    """
    from huggingface_hub import get_token
    return os.getenv("HF_TOKEN") or os.getenv("HUGGING_FACE_HUB_TOKEN") or get_token()


class DownloadCancelled(Exception):
    """Der Nutzer hat den Download abgebrochen. Fertige Dateien und .incomplete-Teile
    bleiben liegen: ein spaeterer Download setzt fort, "Reste loeschen" raeumt auf."""


def _progress_tqdm(on_progress: Callable[[float, str], None], prefix: str, base: float, span: float,
                   should_stop: Callable[[], bool] | None = None):
    """tqdm-Ersatz, der HF-Fortschritt in den Job-Fortschritt uebersetzt.

    Gedrosselt auf ganze Prozent -- sonst schreibt ein 16-GB-Download tausende
    SQLite-Updates und flutet den WebSocket.
    """
    from tqdm.auto import tqdm as _tqdm

    class JobTqdm(_tqdm):  # type: ignore[misc]
        _last_pct = -1

        def update(self, n: float | None = 1) -> bool | None:
            # Bei jedem Datenblock (wenige MB) nachfragen -- so endet ein Abbruch in Sekunden,
            # nicht erst nach einer 10-GB-Datei.
            if should_stop and should_stop():
                raise DownloadCancelled()
            result = super().update(n)
            total = getattr(self, "total", None)
            if total:
                pct = int(self.n * 100 / total)
                if pct != self._last_pct:
                    self._last_pct = pct
                    gb = 1024**3
                    on_progress(
                        base + span * min(self.n / total, 1.0),
                        f"{prefix}: {self.n / gb:.1f} / {total / gb:.1f} GB",
                    )
            return result

    return JobTqdm


def clean_partial(entry: dict[str, Any]) -> int:
    """Raeumt Reste einer abgebrochenen Installation weg: Zieldateien,
    .incomplete-Fragmente und den HF-Cache im Zielordner.

    Gibt die Anzahl entfernter Dateien zurueck. Wird vor einem Neuladen
    aufgerufen -- Fortsetzen ist bei kaputten Fragmenten unzuverlaessiger
    als ein sauberer Neustart.
    """
    removed = 0
    keep = in_use_snapshot(entry["id"])
    for f in entry["files"]:
        dest = file_path(f)
        if dest.exists() and not _shared_with_other_installed(entry["id"], f, keep=keep):
            try:
                dest.unlink()
                removed += 1
            except OSError:
                pass
        # Fragmente und Metadaten von huggingface_hub
        cache = dest.parent / ".cache" / "huggingface"
        if cache.exists():
            import shutil
            shutil.rmtree(cache, ignore_errors=True)
            removed += 1
        for stray in dest.parent.glob(f"{dest.stem}*.incomplete"):
            try:
                stray.unlink()
                removed += 1
            except OSError:
                pass
    return removed


def civitai_token() -> str | None:
    """Civitai-API-Schluessel des Nutzers (viele Downloads brauchen einen). Umgebung vor Datei."""
    token = os.getenv("CIVITAI_TOKEN", "").strip()
    if token:
        return token
    p = config.DATA_DIR / "civitai_token"
    try:
        return p.read_text(encoding="utf-8").strip() or None
    except OSError:
        return None


def _download_url(url: str, dest: Path, label: str, base: float, span: float,
                  on_progress: Callable[[float, str], None] | None,
                  should_stop: Callable[[], bool] | None) -> None:
    import httpx

    headers = {}
    token = civitai_token()
    if token and "civitai.com" in url:
        headers["Authorization"] = f"Bearer {token}"
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_name(dest.name + ".part")
    with httpx.stream("GET", url, headers=headers, follow_redirects=True, timeout=60) as r:
        if r.status_code in (401, 403):
            raise RuntimeError(i18n.t(
                "Civitai verlangt für diesen Download einen API-Schlüssel – unter „Modelle“ → "
                "„Civitai“ eintragen.",
                "Civitai requires an API key for this download – enter it under “Models” → “Civitai”."))
        r.raise_for_status()
        total = int(r.headers.get("content-length") or 0)
        done = 0
        last = 0.0
        with open(part, "wb") as fh:
            for chunk in r.iter_bytes(1 << 20):
                if should_stop and should_stop():
                    fh.close()
                    part.unlink(missing_ok=True)
                    raise DownloadCancelled()
                fh.write(chunk)
                done += len(chunk)
                if on_progress and total and time.monotonic() - last > 0.5:
                    last = time.monotonic()
                    on_progress(base + span * done / total,
                                f"{label}: {done / 1e9:.2f} / {total / 1e9:.2f} GB")
    part.replace(dest)


def download(
    entry: dict[str, Any],
    on_progress: Callable[[float, str], None] | None = None,
    clean: bool = False,
    should_stop: Callable[[], bool] | None = None,
) -> list[Path]:
    """Laedt alle Dateien eines Modells. Blockierend -- gehoert in einen Worker-Thread.

    clean=True raeumt vorher Reste weg und laedt alles frisch.
    """
    if clean:
        if on_progress:
            on_progress(0.0, "raeume alten Stand auf")
        clean_partial(entry)

    files = entry["files"]
    span = 1.0 / max(len(files), 1)
    paths: list[Path] = []

    for i, f in enumerate(files):
        if should_stop and should_stop():
            raise DownloadCancelled()
        dest = file_path(f)
        label = f"{i + 1}/{len(files)} " + (
            f["target"] if f.get("snapshot") else Path(f["file"]).name
        )

        if _file_installed(f):
            if on_progress:
                on_progress((i + 1) * span, f"{label}: bereits vorhanden")
            paths.append(dest)
            continue

        if on_progress:
            on_progress(i * span, f"{label}: startet")

        if f.get("optional"):
            # Optionale Dateien (eigene Freigabe auf Hugging Face, etwa das Detail-IC-LoRA von
            # LTX-2.5) duerfen fehlen: der Rest des Modells laeuft, die Funktion bleibt aus.
            try:
                paths.extend(_download_file(f, dest, label, i * span, span, on_progress, should_stop))
            except DownloadCancelled:
                raise
            except Exception as exc:  # noqa: BLE001 - Freigabe fehlt, Netz, Repo verschoben
                log.warning("optionale Datei %s uebersprungen: %s", f.get("file"), exc)
                if on_progress:
                    on_progress((i + 1) * span, i18n.t(
                        f"{label}: übersprungen – Freigabe auf https://huggingface.co/{f['repo']} fehlt",
                        f"{label}: skipped – access to https://huggingface.co/{f['repo']} is missing"))
            continue

        paths.extend(_download_file(f, dest, label, i * span, span, on_progress, should_stop))

    if on_progress:
        on_progress(1.0, "fertig")
    return paths


def _download_file(f: dict[str, Any], dest: Path, label: str, base: float, span: float,
                   on_progress: Callable[[float, str], None] | None,
                   should_stop: Callable[[], bool] | None) -> list[Path]:
    """Eine Datei bzw. ein Snapshot-Ordner eines Katalogeintrags nach `dest`."""
    # Direkte URL (Civitai): ohne huggingface_hub, gestreamt in eine .part-Datei.
    if f.get("url"):
        _download_url(f["url"], dest, label, base, span, on_progress, should_stop)
        return [dest]

    kwargs: dict[str, Any] = {}
    if on_progress:
        kwargs["tqdm_class"] = _progress_tqdm(on_progress, label, base, span, should_stop)
    token = hf_token()
    if token:
        kwargs["token"] = token

    # Snapshot: ganzes Repo als Ordner -- fuer Worker mit from_pretrained().
    if f.get("snapshot"):
        dest.mkdir(parents=True, exist_ok=True)
        snapshot_download(
            repo_id=f["repo"],
            local_dir=str(dest),
            allow_patterns=f.get("allow_patterns"),
            **kwargs,
        )
        return [dest]

    dest.parent.mkdir(parents=True, exist_ok=True)
    try:
        cached = hf_hub_download(
            repo_id=f["repo"],
            filename=f["file"],
            local_dir=str(dest.parent),
            **kwargs,
        )
    except Exception as exc:  # noqa: BLE001 - huggingface_hub meldet Sperren als eigene Fehlerklassen
        if type(exc).__name__ in ("GatedRepoError", "RepositoryNotFoundError") or " 403 " in f" {exc} ":
            raise RuntimeError(i18n.t(
                f"Kein Zugriff auf {f['repo']}: Das Repo ist gesperrt. Auf "
                f"https://huggingface.co/{f['repo']} die Lizenz akzeptieren (mit dem Konto, dessen "
                "Token in NVAI-open hinterlegt ist) und erneut laden.",
                f"No access to {f['repo']}: the repo is gated. Accept the license on "
                f"https://huggingface.co/{f['repo']} (with the account whose token is stored in "
                "NVAI-open) and download again.")) from exc
        raise
    # Repos mit Unterordnern (split_files/...) landen verschachtelt -> flach ziehen,
    # damit ComfyUI die Datei in models/<target>/ findet.
    cached_path = Path(cached)
    if cached_path.resolve() != dest.resolve():
        cached_path.replace(dest)
        _prune_empty(cached_path.parent, dest.parent)
    return [dest]


def _prune_empty(start: Path, stop: Path) -> None:
    """Raeumt leere Zwischenordner auf, die durch Repo-Unterpfade entstanden sind."""
    cur = start
    while cur != stop and cur.is_dir():
        try:
            next(cur.iterdir())
            return
        except StopIteration:
            parent = cur.parent
            cur.rmdir()
            cur = parent
        except OSError:
            return


def delete(entry: dict[str, Any], protect_ids: list[str] | None = None) -> dict[str, Any]:
    """Loescht die Modelldateien von der Platte. Der Katalogeintrag bleibt,
    damit man dasselbe Modell spaeter erneut laden kann.

    protect_ids: Modelle, deren Dateien tabu sind -- typischerweise solche, fuer
    die gerade ein Download laeuft. Sonst zieht man einem laufenden Job seine
    bereits geladenen Dateien unter den Fuessen weg.
    """
    removed, freed, failed = [], 0.0, []
    # Einmal vorab festhalten, was andere Modelle brauchen: waehrend des Loeschens
    # faellt ein Modell schon nach der ersten fehlenden Datei aus "installiert"
    # heraus und wuerde die restlichen geteilten Dateien nicht mehr schuetzen.
    keep = in_use_snapshot(entry["id"], protect_ids)
    for f in entry["files"]:
        p = file_path(f)
        if not p.exists():
            continue
        # Snapshot-Ordner am Stueck entfernen.
        if f.get("snapshot"):
            import shutil

            size = _size_gb(p)
            shutil.rmtree(p, ignore_errors=True)
            if p.exists():
                failed.append(f"{p.name}: konnte nicht vollstaendig geloescht werden")
            else:
                removed.append(p.name + "/")
                freed += size * 1024**3
            continue
        # Von mehreren Modellen geteilte Dateien (z.B. der umt5-Encoder) nicht
        # loeschen, solange ein anderes installiertes Modell sie noch braucht.
        if _shared_with_other_installed(entry["id"], f, protect_ids, keep=keep):
            failed.append(f"{p.name}: wird von einem anderen Modell benutzt")
            continue
        try:
            size = p.stat().st_size
            p.unlink()
            removed.append(p.name)
            freed += size
        except PermissionError:
            # Windows gibt eine geladene Datei nicht frei -- ComfyUI haelt sie noch.
            failed.append(f"{p.name}: in Benutzung. Erst 'VRAM leeren', dann erneut versuchen.")
        except OSError as exc:
            failed.append(f"{p.name}: {exc}")

    # Cache von huggingface_hub im Zielordner mit aufraeumen
    for f in entry["files"]:
        cache = file_path(f).parent / ".cache" / "huggingface"
        if cache.exists():
            import shutil
            shutil.rmtree(cache, ignore_errors=True)

    with _state_lock:
        active = _load_active()
        if active.get(entry["kind"]) == entry["id"] and removed:
            active.pop(entry["kind"], None)
            _save_active(active)

    return {
        "removed": removed,
        "freed_gb": round(freed / 1024**3, 2),
        "failed": failed,
    }


def in_use_snapshot(exclude: str, protect_ids: list[str] | None = None) -> set[Path]:
    """Alle Dateien, die andere Modelle brauchen -- EINMAL vor dem Loeschen erfasst.

    Wichtig, dass das ein Schnappschuss ist: waehrend eines Loeschlaufs
    verschwinden Dateien, und ein Modell gilt schon nach der ersten fehlenden
    Datei nicht mehr als installiert. Live geprueft wuerde der Schutz also
    mitten im Lauf wegfallen und die restlichen geteilten Dateien mitreissen.
    """
    protected = set(protect_ids or [])
    keep: set[Path] = set()
    for e in all_entries():
        if e["id"] == exclude:
            continue
        if not is_installed(e) and e["id"] not in protected:
            continue
        for of in e["files"]:
            with contextlib.suppress(OSError):
                keep.add(file_path(of).resolve())
    return keep


def _shared_with_other_installed(
    model_id: str, f: dict[str, Any], protect_ids: list[str] | None = None,
    keep: set[Path] | None = None,
) -> bool:
    """Braucht ein anderes Modell diese Datei?

    `keep` ist der Schnappschuss aus in_use_snapshot(); ohne ihn wird live
    geprueft, was nur ausserhalb eines laufenden Loeschvorgangs sicher ist.
    """
    target = file_path(f)
    if keep is not None:
        with contextlib.suppress(OSError):
            return target.resolve() in keep
        return False
    return target.resolve() in in_use_snapshot(model_id, protect_ids)


def _slug(text: str) -> str:
    """Teil einer Modell-ID: Emojis und Satzzeichen aus Civitai-Namen werden zu "_"."""
    return re.sub(r"[^\w.-]+", "_", text.lower()).strip("_") or "lora"


# Lizenzen, unter denen Ergebnisse verkauft werden duerfen. Civitai nennt die Freigaben als
# Liste; "Image" heisst: erzeugte Bilder duerfen kommerziell genutzt werden.
_COMMERCIAL_LICENSES = {"apache-2.0", "mit", "cc-by-4.0", "cc0-1.0", "bsd-3-clause"}


def commercial_from_license(license_: str | None) -> bool:
    text = (license_ or "").strip()
    if text.lower().startswith("civitai:"):
        return "image" in {x.strip().lower() for x in text.split(":", 1)[1].split(",")}
    return text.lower() in _COMMERCIAL_LICENSES


def register_custom(
    repo: str, file: str, target: str = "checkpoints",
    kind: str = "image", family: str = "sdxl", workflow: str | None = "sdxl",
    license_: str | None = None, size_gb: float | None = None,
    trigger: str = "", source_url: str | None = None, url: str | None = None,
) -> dict[str, Any]:
    """Nimmt ein freies HF-Repo in den Nutzer-Katalog auf (Suche oder von Hand).

    LoRAs (kind "lora") landen in loras/, family ist ihre LoRA-Basis (loras.BASES). Mit url
    (Civitai) wird direkt von dort geladen; repo ist dann nur ein Name fuer die Anzeige.
    """
    prefix = "lora" if kind == "lora" else "custom"
    model_id = f"{prefix}-{_slug(repo.split('/')[-1])}-{_slug(Path(file).stem)}"
    fixed = next((e for e in ALL_MODELS if e["id"] == model_id), None)
    if fixed is not None:   # schon im festen Katalog (empfohlene LoRA): kein zweiter Eintrag
        return fixed
    entries = _load_user_catalog()
    for e in entries:
        if e["id"] == model_id:
            return e
    entry = {
        "id": model_id,
        "name": f"{repo} / {Path(file).name}",
        "kind": kind,
        "family": family,
        "workflow": workflow,
        "files": [{"repo": repo, "file": file, "target": target}],
        "size_gb": size_gb or 0.0,
        "vram_gb": {"sdxl": 8, "sd15": 4}.get(family, 0),
        "license": license_ or "siehe Repo",
        "commercial_ok": commercial_from_license(license_),
        "best_for": "von Hugging Face hinzugefügt",
        "description": (f"Aus der Suche hinzugefügt: https://huggingface.co/{repo}\n\n"
                        "Die Lizenz bitte im Repo prüfen, bevor Bilder veröffentlicht werden."),
        "pros": [],
        "cons": ["Nicht von NVAI-open getestet; die Lizenz steht nur im Repo"],
        "custom": True,
    }
    if kind == "lora":
        source = source_url or f"https://huggingface.co/{repo}"
        entry.update({
            "workflow": None, "vram_gb": 0, "trigger": trigger, "source_url": source,
            "best_for": loras.BASES.get(family, family),
            "description": (f"LoRA für {loras.BASES.get(family, family)}, hinzugefügt aus {source}\n\n"
                            "Die Lizenz bitte dort prüfen, bevor Ergebnisse veröffentlicht werden."),
        })
        if url:
            entry["files"][0]["url"] = url
    if family == "sd15":
        from .hfsearch import SD15_SIZES
        # Der Prompt-Hinweis kommt sprachabhaengig aus _custom_texts.
        entry["features"] = {"sizes": SD15_SIZES}
    entries.append(entry)
    _save_user_catalog(entries)
    return entry


def remove_custom(model_id: str) -> bool:
    entries = _load_user_catalog()
    rest = [e for e in entries if e["id"] != model_id]
    if len(rest) == len(entries):
        return False
    _save_user_catalog(rest)
    return True


# ------------------------------------------------------- aktives Modell

def _load_active() -> dict[str, str]:
    if _ACTIVE_FILE.exists():
        try:
            return json.loads(_ACTIVE_FILE.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            return {}
    return {}


def _save_active(data: dict[str, str]) -> None:
    config.ensure_dirs()
    _ACTIVE_FILE.write_text(json.dumps(data, indent=2), encoding="utf-8")


def get_active_model(kind: str = "image") -> str | None:
    """Aktives Modell je Kategorie. Faellt auf das erste lauffaehige zurueck."""
    with _state_lock:
        active = _load_active()
        chosen = active.get(kind)
        if chosen:
            entry = get_entry(chosen)
            if entry and is_installed(entry):
                return chosen
        runnable = installed_models(kind)
        return runnable[0].id if runnable else None


def get_active_models() -> dict[str, str | None]:
    return {k: get_active_model(k) for k in ("image", "audio", "video", "3d")}


def set_active_model(model_id: str) -> str:
    entry = get_entry(model_id)
    if entry is None:
        raise ValueError(t(f"Unbekanntes Modell: {model_id}", f"Unknown model: {model_id}"))
    with _state_lock:
        active = _load_active()
        active[entry["kind"]] = model_id
        _save_active(active)
    return entry["kind"]
