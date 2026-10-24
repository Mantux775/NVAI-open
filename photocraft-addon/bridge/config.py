"""Pfade, Ports und Adressen.

Reihenfolge: Umgebungsvariable vor ``settings.json`` im Datenordner vor dem, was die Installer
eintragen (NVAI-open-Setup, PhotoCraft-MSI), vor dem Standardwert. In ``settings.json`` gehört vor
allem ein entferntes NVAI-open, etwa über Tailscale, oder ein portables PhotoCraft:

    {"nvai_url": "http://pc-name:8100", "nvai_token": "…", "photocraft_exe": "D:/PhotoCraft/photocraft.exe"}
"""
from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

from . import i18n, winutil

ROOT = Path(__file__).resolve().parent.parent
PANEL_DIR = ROOT / "panel"
ICON_FILE = PANEL_DIR / "icon.ico"

# Laufzeitdaten liegen unter %LOCALAPPDATA%. Der Ordner ist nur für den angemeldeten Nutzer
# lesbar – wichtig für das Steuer-Token, mit dem sich PhotoCraft vollständig fernsteuern lässt.
DATA_DIR = Path(
    os.environ.get("ARTCRAFT_LOCALAI_DATA")
    or Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "ArtCraft-LocalAI"
)
# Der einzige Ordner, in dem PhotoCraft per Fernsteuerung Dateien lesen und schreiben darf
# (--automation-read-root / --automation-write-root). Alles andere verweigert PhotoCraft.
EXCHANGE_DIR = DATA_DIR / "exchange"
JOBS_DIR = EXCHANGE_DIR / "jobs"
TOKEN_FILE = DATA_DIR / "photocraft-control.token"
LOG_DIR = DATA_DIR / "logs"
PANEL_STATE_FILE = DATA_DIR / "panel.json"
WEBVIEW_DIR = DATA_DIR / "webview"
SETTINGS_FILE = DATA_DIR / "settings.json"


def _load_settings() -> dict:
    try:
        data = json.loads(SETTINGS_FILE.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


_settings = _load_settings()
i18n.set_choice(os.environ.get("ARTCRAFT_LANGUAGE") or _settings.get("language"))


def save_settings(**changes: object) -> None:
    """Einträge in settings.json ändern und den Rest (etwa den Token) unverändert lassen."""
    data = {**_load_settings(), **changes}
    ensure_dirs()
    tmp = SETTINGS_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
    tmp.replace(SETTINGS_FILE)
    _settings.update(changes)

PHOTOCRAFT_PORT = int(os.environ.get("ARTCRAFT_PHOTOCRAFT_PORT", "47821"))
# Neueste Veröffentlichung. Die Seite getartcraft.com/apps/photocraft verlinkte im Oktober 2026
# noch 0.7.0, während 0.10.0 aktuell war.
PHOTOCRAFT_DOWNLOAD_URL = "https://github.com/storytold/photocraft/releases/latest"
# Mit dieser Version ist der Steuerkanal vermessen (docs/mac-port.md). Ältere bekommen einen Hinweis.
PHOTOCRAFT_TESTED_VERSION = "0.10.0"


def photocraft_exe() -> Path | None:
    """Das PhotoCraft, das die Brücke startet – oder None, wenn keines installiert ist.

    Wird bei jedem Aufruf neu ermittelt: Wer PhotoCraft nachinstalliert, muss die Brücke nicht
    neu starten.
    """
    explicit = os.environ.get("PHOTOCRAFT_EXE") or _settings.get("photocraft_exe")
    if explicit:
        path = Path(explicit)
        return path if path.is_file() else None
    # Der PhotoCraft-MSI (auch über den ArtCraft Launcher) trägt sich unter App Paths ein.
    default = Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "PhotoCraft" / "photocraft.exe"
    for candidate in (winutil.app_path("photocraft.exe"), default):
        if candidate and candidate.is_file():
            return candidate
    return None


def version_older(version: str, reference: str) -> bool:
    """„0.7.0“ ist älter als „0.10.0“: Stellen als Zahlen vergleichen, fehlende zählen als 0."""
    a = [int(p) for p in re.findall(r"\d+", version)[:3]]
    b = [int(p) for p in re.findall(r"\d+", reference)[:3]]
    if not a or not b:
        return False
    width = max(len(a), len(b))
    return a + [0] * (width - len(a)) < b + [0] * (width - len(b))


BRIDGE_HOST = "127.0.0.1"
BRIDGE_PORT = int(os.environ.get("ARTCRAFT_BRIDGE_PORT", "8120"))

# Als Add-on des NVAI-open-Setups installiert? tools/build_addon.py legt addon.ini neben bridge\ an.
ADDON = (ROOT / "addon.ini").is_file()

def _dev_nvai_root() -> Path:
    """Entwicklungsordner von NVAI-open: im öffentlichen Repository der Ordner darüber (dieser liegt
    dort als photocraft-addon/ in NVAI-open), sonst der Nachbarordner „NV-AI“ (so heißt der private
    Entwicklungsordner weiterhin)."""
    for candidate in (ROOT.parent, ROOT.parent / "NV-AI"):
        if (candidate / "scripts" / "start.ps1").is_file():
            return candidate
    return ROOT.parent / "NV-AI"


# Entwicklungsordner von NVAI-open (Startskript, openapi.json für die Vertragstests). Ausdrücklich
# gesetzt hat er Vorrang vor dem Setup – dann wird an NVAI-open selbst entwickelt.
NVAI_ROOT_EXPLICIT = bool(os.environ.get("NVAI_ROOT") or _settings.get("nvai_root"))
NVAI_ROOT = Path(os.environ.get("NVAI_ROOT") or _settings.get("nvai_root") or _dev_nvai_root())

# Eintrag des NVAI-open-Setups (pro Nutzer).
NVAI_REGISTRY_KEY = r"Software\NV-AI"
NVAI_DEFAULT_PORT = 8100


@dataclass(frozen=True)
class NVAIInstall:
    """Ein per Setup installiertes NVAI-open."""

    install_dir: Path
    version: str
    data_dir: Path | None
    port: int

    @property
    def start_script(self) -> Path:
        """Startet NVAI-open ohne Fenster, falls es nicht läuft, und kehrt sofort zurück."""
        return self.install_dir / "nvai-start.cmd"


def nvai_install() -> NVAIInstall | None:
    """Was das NVAI-open-Setup unter HKCU\\Software\\NV-AI einträgt – oder None (etwa im
    Entwicklungsstand ohne Setup)."""
    values = winutil.registry_values(NVAI_REGISTRY_KEY, "HKCU") or {}
    install_dir = values.get("InstallDir")
    if not isinstance(install_dir, str) or not install_dir.strip():
        return None
    port = values.get("Port")
    data_dir = values.get("DataDir")
    return NVAIInstall(
        install_dir=Path(install_dir.strip()),
        version=str(values.get("Version") or ""),
        data_dir=Path(data_dir) if isinstance(data_dir, str) and data_dir.strip() else None,
        port=port if isinstance(port, int) and 0 < port < 65536 else NVAI_DEFAULT_PORT,
    )


def nvai_setup() -> NVAIInstall | None:
    """Das per Setup installierte NVAI-open, zu dem diese Brücke gehört – oder None.

    Das Add-on gehört immer zum Setup. Aus dem Repository gestartet bleibt die Brücke beim
    NVAI-open-Entwicklungsordner, wenn es ihn gibt: Auf dem Entwicklungsrechner liegt daneben eine
    Testinstallation des Setups mit eigenem Port.
    """
    if NVAI_ROOT_EXPLICIT or (not ADDON and (NVAI_ROOT / "scripts" / "start.ps1").is_file()):
        return None
    return nvai_install()


def resolve_nvai_url(install: NVAIInstall | None) -> str:
    """Umgebung, dann settings.json, dann der Port aus dem Setup, sonst 127.0.0.1:8100."""
    port = install.port if install else NVAI_DEFAULT_PORT
    return (os.environ.get("NVAI_URL") or _settings.get("nvai_url") or f"http://127.0.0.1:{port}").rstrip("/")


NVAI_URL = resolve_nvai_url(nvai_setup())


def load_nvai_token() -> str | None:
    """Token frisch einlesen – „Erneut prüfen“ im Panel übernimmt so eine geänderte settings.json."""
    return os.environ.get("NVAI_TOKEN") or _load_settings().get("nvai_token") or None


# Wird als Header X-NVAI-Token mitgeschickt. NVAI-open verlangt ihn für Anfragen von anderen
# Rechnern; von 127.0.0.1 aus nie. /api/health und /api/version gehen immer ohne.
NVAI_TOKEN = os.environ.get("NVAI_TOKEN") or _settings.get("nvai_token") or None


def nvai_is_local() -> bool:
    """Läuft NVAI-open auf diesem Rechner? Nur dann darf die Brücke es selbst starten."""
    return (urlparse(NVAI_URL).hostname or "").lower() in ("127.0.0.1", "localhost", "::1")

# Wie lange Auftragsordner (Ausschnitte, Masken, Ergebnisse) aufbewahrt werden.
KEEP_JOBS_DAYS = float(os.environ.get("ARTCRAFT_KEEP_JOBS_DAYS", "3"))


def ensure_dirs() -> None:
    for d in (DATA_DIR, EXCHANGE_DIR, JOBS_DIR, LOG_DIR):
        d.mkdir(parents=True, exist_ok=True)
