"""Zentrale Pfade und Ports. Alles relativ zum Repo-Root, damit nichts hart verdrahtet ist."""
from __future__ import annotations

import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def instance_id(root: Path) -> str:
    """Kennung einer Installation: kurzer Hash ihres Programmordners. Der Starter vergleicht
    sie mit /api/version -- sonst hielt er ein fremdes NVAI-open auf demselben Port (etwa die
    Entwicklungsfassung) fuer sein eigenes und beendete es (gemessen am 2026-10-19)."""
    import hashlib
    return hashlib.sha256(str(root).lower().encode("utf-8")).hexdigest()[:12]


INSTANCE_ID = instance_id(ROOT)


def _installed_settings() -> dict[str, object]:
    """Ordner und Port der installierten Windows-Fassung aus HKCU\\Software\\NV-AI.

    Nur, wenn dieser Code selbst die Installation ist (InstallDir == ROOT): So findet auch
    der MCP-Server, den Claude Code ohne Umgebungsvariablen startet, Daten- und Modellordner,
    und eine Entwicklungsfassung auf demselben Rechner liest die Werte der Installation nicht.
    Gesetzte Umgebungsvariablen gehen immer vor.
    """
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\NV-AI") as key:
            values: dict[str, object] = {}
            for name in ("InstallDir", "DataDir", "ModelDir", "Port"):
                try:
                    values[name] = winreg.QueryValueEx(key, name)[0]
                except OSError:
                    pass
    except (ImportError, OSError):
        return {}
    install_dir = values.get("InstallDir")
    if not install_dir or str(Path(str(install_dir)).resolve()).lower() != str(ROOT).lower():
        return {}
    return values


_INSTALLED = _installed_settings()

DATA_DIR = Path(os.getenv("NVAI_DATA_DIR") or str(_INSTALLED.get("DataDir") or ROOT / "data"))
ASSET_DIR = DATA_DIR / "assets"
UPLOAD_DIR = DATA_DIR / "uploads"
DB_PATH = DATA_DIR / "nvai.db"

COMFY_ROOT = Path(os.getenv("NVAI_COMFY_ROOT", ROOT / "external" / "comfyui"))
# Die installierte Fassung legt die Modelle (20+ GB je Stueck) in einen frei
# waehlbaren Ordner; ComfyUI bekommt ihn per --models-directory (comfy.start).
MODEL_DIR_OVERRIDE = os.getenv("NVAI_MODEL_DIR") or (str(_INSTALLED["ModelDir"]) if _INSTALLED.get("ModelDir") else None)
COMFY_MODEL_DIR = Path(MODEL_DIR_OVERRIDE) if MODEL_DIR_OVERRIDE else COMFY_ROOT / "models"

# Modelle, die NICHT von ComfyUI geladen werden, sondern von eigenen Workern
# (z.B. TripoSG). Die brauchen die komplette Repo-Struktur, keine Einzeldateien.
# Mit gewaehltem Modellordner liegen sie dort mit (eigene Unterordner wie triposg/),
# sonst landete TripoSG (7,4 GB) im Datenordner statt auf der gewaehlten Platte.
MODELS_DIR = Path(MODEL_DIR_OVERRIDE) if MODEL_DIR_OVERRIDE else DATA_DIR / "models"
COMFY_URL = os.getenv("NVAI_COMFY_URL", "http://127.0.0.1:8188")
# Zweites ComfyUI fuer die Sprachmodelle, nur wenn sie auf einer eigenen Karte liegen
# (experimentell seit 0.5, siehe gpu.separate_text_backend).
COMFY_TEXT_URL = os.getenv("NVAI_COMFY_TEXT_URL", "http://127.0.0.1:8189")

API_HOST = os.getenv("NVAI_HOST", "127.0.0.1")
API_PORT = int(os.getenv("NVAI_PORT") or _INSTALLED.get("Port") or 8100)
# Nur noetig, wenn andere Geraete den Server erreichen sollen (Mac-App,
# PhotoCraft-Bruecke, iOS-App). Ohne Token bedient er nur den eigenen Rechner,
# egal an welche Adresse er gebunden ist (main.py, Zugriffsschutz).
# Quelle: NVAI_TOKEN, sonst die Datei data/api_token -- die legt start.ps1 -Lan
# beim ersten Netzstart mit 32 Zufallsbytes an.
TOKEN_FILE = Path(os.getenv("NVAI_TOKEN_FILE", DATA_DIR / "api_token"))


def _read_token() -> str:
    token = os.getenv("NVAI_TOKEN", "").strip()
    if token:
        return token
    try:
        # utf-8-sig: von Hand mit PowerShell gespeichert, beginnt die Datei mit BOM.
        return TOKEN_FILE.read_text(encoding="utf-8-sig").strip()
    except OSError:
        return ""


API_TOKEN = _read_token()
API_URL = os.getenv("NVAI_API_URL", f"http://{API_HOST}:{API_PORT}")

# Optional: Unity-Projekt. Ist es gesetzt, koennen Assets direkt dorthin exportiert werden.
UNITY_PROJECT = os.getenv("NVAI_UNITY_PROJECT")


TRIPOSG_ROOT = Path(os.getenv("NVAI_TRIPOSG_ROOT", ROOT / "external" / "triposg"))
TRIPOSG_URL = os.getenv("NVAI_TRIPOSG_URL", "http://127.0.0.1:8200")

TRELLIS2_ROOT = Path(os.getenv("NVAI_TRELLIS2_ROOT", ROOT / "external" / "trellis2"))
TRELLIS2_URL = os.getenv("NVAI_TRELLIS2_URL", "http://127.0.0.1:8201")


def ensure_dirs() -> None:
    for d in (DATA_DIR, ASSET_DIR, UPLOAD_DIR, MODELS_DIR):
        d.mkdir(parents=True, exist_ok=True)
    if MODEL_DIR_OVERRIDE:
        COMFY_MODEL_DIR.mkdir(parents=True, exist_ok=True)
