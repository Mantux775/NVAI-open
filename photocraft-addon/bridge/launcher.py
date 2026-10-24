"""Programme starten: PhotoCraft mit Steuerkanal und NVAI-open."""
from __future__ import annotations

import logging
import os
import socket
import subprocess
import time
from pathlib import Path
from urllib.parse import urlparse

from . import config, winutil
from .i18n import t

log = logging.getLogger(__name__)

CREATE_NEW_PROCESS_GROUP = 0x00000200
DETACHED_PROCESS = 0x00000008
CREATE_NEW_CONSOLE = 0x00000010
CREATE_NO_WINDOW = 0x08000000
SW_SHOWMINNOACTIVE = 7


class LaunchError(RuntimeError):
    pass


def port_open(port: int, timeout: float = 0.3) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=timeout):
            return True
    except OSError:
        return False


def photocraft_pids() -> list[int]:
    """Alle laufenden PhotoCraft-Prozesse (mit und ohne Steuerkanal)."""
    try:
        raw = subprocess.run(
            ["tasklist", "/FI", "IMAGENAME eq photocraft.exe", "/FO", "CSV", "/NH"],
            capture_output=True, timeout=5, creationflags=CREATE_NO_WINDOW,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    # tasklist schreibt in der OEM-Codepage. Ohne Treffer kommt eine übersetzte Meldung
    # („… ausgeführt“) – mit text=True scheiterte deren „ü“, stdout wurde None und
    # /api/state brach ab, solange kein PhotoCraft lief.
    out = (raw or b"").decode("oem", errors="replace")
    pids = []
    for line in out.splitlines():
        parts = [p.strip().strip('"') for p in line.split(",")]
        if len(parts) > 1 and parts[0].lower() == "photocraft.exe" and parts[1].isdigit():
            pids.append(int(parts[1]))
    return pids


def photocraft_install() -> dict[str, object]:
    """Ist PhotoCraft installiert, in welcher Version, und ist die älter als die getestete?"""
    exe = config.photocraft_exe()
    version = winutil.file_version(exe) if exe else None
    return {
        "installed": exe is not None,
        "exe": str(exe) if exe else None,
        "version": version,
        "outdated": bool(version) and config.version_older(version, config.PHOTOCRAFT_TESTED_VERSION),
        "tested_version": config.PHOTOCRAFT_TESTED_VERSION,
        "download_url": config.PHOTOCRAFT_DOWNLOAD_URL,
    }


def photocraft_command(exe: Path) -> list[str]:
    return [
        str(exe),
        "--control", str(config.PHOTOCRAFT_PORT),
        "--control-token-file", str(config.TOKEN_FILE),
        "--automation-read-root", str(config.EXCHANGE_DIR),
        "--automation-write-root", str(config.EXCHANGE_DIR),
    ]


def start_photocraft(force: bool = False, wait: float = 25.0) -> str:
    """PhotoCraft mit Steuerkanal starten. Gibt eine Statusmeldung zurück.

    Ein PhotoCraft ohne Steuerkanal lässt sich nachträglich nicht anbinden. Läuft eines, wird
    ohne ``force`` nichts gestartet – zwei Fenster nebeneinander wären verwirrend, und
    ungespeicherte Arbeit gehört zuerst gesichert.
    """
    if port_open(config.PHOTOCRAFT_PORT):
        return t("PhotoCraft mit NVAI-open-Anbindung läuft bereits.", "PhotoCraft with NVAI-open connection is already running.")
    exe = config.photocraft_exe()
    if exe is None:
        raise LaunchError(t(
            f"PhotoCraft ist nicht installiert. Download: {config.PHOTOCRAFT_DOWNLOAD_URL} – dort unter "
            "„Assets“ die Datei …-windows-x64.msi. Ein portables PhotoCraft in settings.json als "
            "„photocraft_exe“ eintragen.",
            f"PhotoCraft is not installed. Download: {config.PHOTOCRAFT_DOWNLOAD_URL} – under \"Assets\" "
            "pick the file …-windows-x64.msi. For a portable PhotoCraft, put its path into settings.json "
            "as \"photocraft_exe\".",
        ))
    if photocraft_pids() and not force:
        raise LaunchError(t(
            "PhotoCraft läuft bereits ohne NVAI-open-Anbindung. Bitte dort speichern und "
            "schließen – dann PhotoCraft hier neu starten.",
            "PhotoCraft is already running without the NVAI-open connection. Please save and close it "
            "there – then start PhotoCraft again from here.",
        ))
    config.ensure_dirs()
    env = dict(os.environ)
    # Diese Variablen würden die Startparameter überlagern oder die Instanz verbiegen.
    for key in ("PHOTOCRAFT_CONTROL_TOKEN", "PHOTOCRAFT_CONTROL_PORT", "PHOTOCRAFT_CONFIG_DIR"):
        env.pop(key, None)
    command = photocraft_command(exe)
    log.info("starte PhotoCraft: %s", command)
    subprocess.Popen(
        command, cwd=str(exe.parent), env=env, close_fds=True,
        creationflags=DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP,
    )
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        if port_open(config.PHOTOCRAFT_PORT) and config.TOKEN_FILE.exists():
            return t("PhotoCraft wurde mit NVAI-open-Anbindung gestartet.", "PhotoCraft was started with the NVAI-open connection.")
        time.sleep(0.4)
    raise LaunchError(t("PhotoCraft wurde gestartet, meldet sich aber nicht am Steuerkanal.",
                        "PhotoCraft was started but does not answer on the control channel."))


def nvai_running() -> bool:
    return port_open(urlparse(config.NVAI_URL).port or 80)


# Bis NVAI-open nach einem Start antwortet, zeigt das Panel „NVAI-open startet …“ statt des Startknopfs.
NVAI_START_PATIENCE = 120.0
_nvai_started_at: float | None = None


def nvai_starter() -> tuple[str, Path] | None:
    """Womit sich NVAI-open hier starten lässt: ``("setup", nvai-start.cmd)`` aus der Installation,
    ``("dev", scripts\\start.ps1)`` aus dem Entwicklungsordner – oder None."""
    install = config.nvai_setup()
    if install and install.start_script.is_file():
        return "setup", install.start_script
    dev = config.NVAI_ROOT / "scripts" / "start.ps1"
    if dev.is_file():
        return "dev", dev
    return None


def nvai_start_pending() -> bool:
    """Wurde NVAI-open eben gestartet und darf noch hochfahren?"""
    return _nvai_started_at is not None and time.monotonic() - _nvai_started_at < NVAI_START_PATIENCE


def _run_setup_start(script: Path) -> None:
    """``nvai-start.cmd`` ohne Konsolenfenster ausführen und sein Ende abwarten (kehrt sofort zurück)."""
    cmd = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32" / "cmd.exe"
    # /s mit doppelten Anführungszeichen: cmd nimmt den Pfad wörtlich, auch mit Leerzeichen, & oder ( ).
    # Deshalb eine fertige Befehlszeile – list2cmdline würde die inneren Anführungszeichen maskieren.
    proc = subprocess.Popen(
        f'"{cmd}" /d /s /c ""{script}""', cwd=str(script.parent), creationflags=CREATE_NO_WINDOW,
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        code = proc.wait(timeout=30)
    except subprocess.TimeoutExpired:
        log.warning("nvai-start.cmd läuft nach 30 s noch – NVAI-open startet vermutlich trotzdem")
        return
    if code != 0:
        raise LaunchError(t(f"NVAI-open ließ sich nicht starten: {script.name} endete mit Code {code}.",
                            f"NVAI-open could not be started: {script.name} ended with code {code}."))


def start_nvai() -> str:
    """NVAI-open starten: über ``nvai-start.cmd`` des Setups (ohne Fenster) oder im
    Entwicklungsstand über ``scripts\\start.ps1`` in einem minimierten Konsolenfenster. Dieses
    Fenster zeigt die Serverausgabe; wer es schließt, beendet NVAI-open.

    Bereit ist NVAI-open erst, wenn ``/api/version`` antwortet – das zeigt der Status.
    """
    global _nvai_started_at
    if not config.nvai_is_local():
        raise LaunchError(t(f"NVAI-open läuft auf einem anderen Rechner ({config.NVAI_URL}) und muss dort "
                            "gestartet werden.",
                            f"NVAI-open runs on another computer ({config.NVAI_URL}) and has to be started there."))
    if nvai_running():
        return t("NVAI-open läuft bereits.", "NVAI-open is already running.")
    starter = nvai_starter()
    if starter is None:
        raise LaunchError(t("NVAI-open ist auf diesem PC nicht installiert. Bitte zuerst das NVAI-open-Setup ausführen.",
                            "NVAI-open is not installed on this PC. Please run the NVAI-open setup first."))
    kind, script = starter
    log.info("starte NVAI-open: %s", script)
    if kind == "setup":
        _run_setup_start(script)
    else:
        info = subprocess.STARTUPINFO()
        info.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        info.wShowWindow = SW_SHOWMINNOACTIVE
        subprocess.Popen(
            ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-NoExit", "-File", str(script)],
            cwd=str(script.parent.parent), startupinfo=info, creationflags=CREATE_NEW_CONSOLE,
        )
    _nvai_started_at = time.monotonic()
    return t("NVAI-open wird gestartet …", "NVAI-open is starting …")
