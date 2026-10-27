"""Daten- und Modellordner waehlen (Weboberflaeche "Modelle" -> "Speicherorte").

Die Setup-Fassung liest beide Ordner aus HKCU\\Software\\NV-AI (DataDir, ModelDir; siehe
config._installed_settings und launcher._environment). Hier werden sie dort geaendert; sie
gelten nach einem Neustart (POST /api/restart startet ueber den Starter neu).

Vorhandene Dateien werden nicht verschoben: Ueber Laufwerksgrenzen dauert das bei 100 GB
Modellen Minuten, in denen der Server weg waere. Die Oberflaeche sagt, was zu tun ist.
Die Quelltext-Fassung nimmt NVAI_DATA_DIR und NVAI_MODEL_DIR (scripts/start.ps1).
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Any

from . import config
from .i18n import t

REG_KEY = r"Software\NV-AI"


def managed() -> bool:
    """Gehoert dieser Code zur Setup-Installation? Nur dann kann NVAI-open die Ordner selbst setzen."""
    return bool(config._INSTALLED)  # noqa: SLF001 - bewusst dieselbe Quelle wie config


def env_override() -> list[str]:
    """Gesetzte Umgebungsvariablen gehen der Registry vor -- dann hilft hier kein Speichern."""
    reg = config._INSTALLED  # noqa: SLF001
    out = []
    for var, name in (("NVAI_DATA_DIR", "DataDir"), ("NVAI_MODEL_DIR", "ModelDir")):
        value = os.getenv(var)
        # Der Starter reicht die Registry-Werte selbst als Variable weiter; das ist kein Vorrang.
        if value and str(reg.get(name) or "").lower() != value.lower():
            out.append(var)
    return out


def _free_gb(path: Path) -> float | None:
    p = path
    while not p.exists() and p.parent != p:
        p = p.parent
    try:
        return round(shutil.disk_usage(p).free / 1024 ** 3, 1)
    except OSError:
        return None


def current() -> dict[str, Any]:
    models = config.COMFY_MODEL_DIR if config.MODEL_DIR_OVERRIDE else config.COMFY_ROOT / "models"
    return {
        "data_dir": str(config.DATA_DIR),
        "models_dir": str(models),
        "models_dir_set": bool(config.MODEL_DIR_OVERRIDE),
        "data_free_gb": _free_gb(config.DATA_DIR),
        "models_free_gb": _free_gb(models),
        "managed": managed(),
        "env_override": env_override(),
        "can_restart": managed(),
    }


def check(path: str) -> dict[str, Any]:
    """Ordner anlegen (falls noetig) und Schreibrecht pruefen. Wirft ValueError mit Klartext."""
    raw = (path or "").strip().strip('"')
    if not raw:
        raise ValueError(t("Kein Ordner angegeben.", "No folder given."))
    p = Path(os.path.expandvars(os.path.expanduser(raw)))
    if not p.is_absolute():
        raise ValueError(t(f"Bitte einen vollständigen Pfad angeben (z. B. D:\\NV-AI-Modelle), nicht „{raw}“.",
                           f"Please give a full path (e.g. D:\\NV-AI-Models), not \"{raw}\"."))
    try:
        p.mkdir(parents=True, exist_ok=True)
        probe = p / f".nvai-write-test-{uuid.uuid4().hex[:8]}"
        probe.write_text("ok", encoding="utf-8")
        probe.unlink()
    except OSError as exc:
        raise ValueError(t(f"In „{p}“ kann NVAI-open nicht schreiben: {exc.strerror or exc}",
                           f"NVAI-open cannot write to \"{p}\": {exc.strerror or exc}")) from exc
    return {"path": str(p), "free_gb": _free_gb(p)}


def save(data_dir: str | None, models_dir: str | None) -> dict[str, Any]:
    if not managed():
        raise PermissionError(t(
            "Dieses NVAI-open läuft aus dem Quelltext. Die Ordner dort über NVAI_DATA_DIR und NVAI_MODEL_DIR setzen.",
            "This NVAI-open runs from source. Set the folders there with NVAI_DATA_DIR and NVAI_MODEL_DIR."))
    import winreg
    changed: dict[str, str] = {}
    with winreg.CreateKey(winreg.HKEY_CURRENT_USER, REG_KEY) as key:
        for name, value in (("DataDir", data_dir), ("ModelDir", models_dir)):
            if value:
                checked = check(value)["path"]
                winreg.SetValueEx(key, name, 0, winreg.REG_SZ, checked)
                changed[name] = checked
    return {"saved": changed, "restart_needed": bool(changed)}


def browse(initial: str | None) -> str | None:
    """Windows-Ordnerdialog auf diesem Rechner (der Server laeuft lokal). None = abgebrochen."""
    if sys.platform != "win32":
        return None
    start = (initial or "").replace("'", "''")
    title = t("Ordner für NVAI-open wählen", "Choose a folder for NVAI-open").replace("'", "''")
    script = (
        "Add-Type -AssemblyName System.Windows.Forms;"
        "$f = New-Object System.Windows.Forms.Form; $f.TopMost = $true;"
        "$d = New-Object System.Windows.Forms.FolderBrowserDialog;"
        f"$d.Description = '{title}'; $d.ShowNewFolderButton = $true;"
        f"if ('{start}' -and (Test-Path -LiteralPath '{start}')) {{ $d.SelectedPath = '{start}' }};"
        "if ($d.ShowDialog($f) -eq 'OK') { [Console]::OutputEncoding = [Text.Encoding]::UTF8; $d.SelectedPath }"
    )
    try:
        out = subprocess.run(["powershell", "-NoProfile", "-STA", "-Command", script],
                             capture_output=True, text=True, encoding="utf-8", timeout=600,
                             creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    except (OSError, subprocess.SubprocessError):
        return None
    chosen = out.stdout.strip()
    return chosen or None


def reveal(path: Path) -> None:
    """Ordner einer Datei im Explorer (Finder, Dateimanager) öffnen, die Datei markiert (Studio: „Speicherort
    öffnen“). Der Pfad kommt aus der Datenbank, nie aus der Anfrage."""
    if sys.platform == "win32":
        # explorer will /select, und den Pfad in einem Stück; als Liste würde Python den Pfad anders quoten
        subprocess.Popen(f'explorer /select,"{path}"')
    elif sys.platform == "darwin":
        subprocess.Popen(["open", "-R", str(path)])
    else:
        subprocess.Popen(["xdg-open", str(path.parent)])


def open_folder(path: Path) -> None:
    """Einen Ordner selbst öffnen (Studio: Projektordner im Material). Der Pfad ist vorher gegen die bekannten
    Projektordner geprüft."""
    if sys.platform == "win32":
        subprocess.Popen(["explorer", str(path)])
    elif sys.platform == "darwin":
        subprocess.Popen(["open", str(path)])
    else:
        subprocess.Popen(["xdg-open", str(path)])


def restart() -> None:
    """Ueber den Starter neu starten: der beendet diesen Server und startet ihn mit den
    Registry-Werten neu. Die eigenen NVAI_*-Variablen fallen weg, sonst gewaennen die alten Ordner."""
    env = {k: v for k, v in os.environ.items() if k not in ("NVAI_DATA_DIR", "NVAI_MODEL_DIR")}
    exe = Path(sys.executable)
    pythonw = exe.with_name("pythonw.exe") if exe.with_name("pythonw.exe").exists() else exe
    flags = 0
    for name in ("DETACHED_PROCESS", "CREATE_NEW_PROCESS_GROUP", "CREATE_NO_WINDOW"):
        flags |= getattr(subprocess, name, 0)
    subprocess.Popen([str(pythonw), "-m", "nvai.launcher", "--restart", "--quiet"],
                     cwd=str(config.ROOT / "server"), env=env, creationflags=flags, close_fds=True,
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
