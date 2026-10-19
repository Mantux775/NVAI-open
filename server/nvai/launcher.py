"""Starter der installierten Windows-Fassung (Startmenue, nvai-start.cmd).

    pythonw -m nvai.launcher            # NV-AI starten, falls es nicht laeuft
    pythonw -m nvai.launcher --open     # danach die Weboberflaeche oeffnen
    pythonw -m nvai.launcher --stop     # NV-AI samt ComfyUI beenden

Kehrt zurueck, sobald NV-AI antwortet; der Server laeuft losgeloest weiter.
Die Einstellungen schreibt das Setup nach HKCU\\Software\\NV-AI (DataDir,
ModelDir, Port). Fehlt der Schluessel -- etwa im Entwicklungsbaum --, gelten die
Vorgaben aus config.py. Fehler zeigt ein Meldungsfenster, denn unter pythonw
gibt es keine Konsole.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
import webbrowser
from pathlib import Path

from .config import instance_id

REG_KEY = r"Software\NV-AI"
START_TIMEOUT = 90.0


def _de() -> bool:
    """Deutsch, wenn die Windows-Oberflaeche deutsch ist -- der Starter hat keine Anfrage,
    deren Sprache er uebernehmen koennte."""
    try:
        import ctypes
        return (ctypes.windll.kernel32.GetUserDefaultUILanguage() & 0x3FF) == 0x07
    except (AttributeError, OSError):
        import locale
        return (locale.getlocale()[0] or "").lower().startswith(("de", "german"))


def _t(de: str, en: str) -> str:
    return de if _de() else en


def _registry() -> dict[str, object]:
    try:
        import winreg
    except ImportError:
        return {}
    values: dict[str, object] = {}
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, REG_KEY) as key:
            for name in ("DataDir", "ModelDir", "Port"):
                try:
                    values[name] = winreg.QueryValueEx(key, name)[0]
                except OSError:
                    pass
    except OSError:
        pass
    return values


def _environment() -> tuple[dict[str, str], int]:
    """Umgebung fuer den Server: Registry vor Vorgabe, gesetzte Variablen vor beidem."""
    env = dict(os.environ)
    reg = _registry()
    for var, name in (("NVAI_DATA_DIR", "DataDir"), ("NVAI_MODEL_DIR", "ModelDir"),
                      ("NVAI_PORT", "Port")):
        if not env.get(var) and reg.get(name):
            env[var] = str(reg[name])
    return env, int(env.get("NVAI_PORT") or 8100)


def _version(port: int) -> dict | None:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/version", timeout=2) as r:
            return json.loads(r.read())
    except (OSError, ValueError):
        return None


def _port_busy(port: int) -> bool:
    import socket
    with socket.socket() as s:
        s.settimeout(0.5)
        return s.connect_ex(("127.0.0.1", port)) == 0


def _message(text: str, error: bool = True) -> None:
    if sys.stderr is not None:
        print(text, file=sys.stderr)
    try:
        import ctypes
        ctypes.windll.user32.MessageBoxW(None, text, "NV-AI", 0x10 if error else 0x40)
    except (AttributeError, OSError):
        pass


def _pythonw() -> str:
    exe = Path(sys.executable)
    windowless = exe.with_name("pythonw.exe")
    return str(windowless if windowless.exists() else exe)


def _own_instance() -> str:
    return instance_id(Path(__file__).resolve().parents[2])


def _foreign_nvai(port: int) -> str:
    return _t(f"Auf Port {port} läuft bereits ein anderes NV-AI – etwa eine zweite Installation "
              f"oder die Entwicklungsfassung.\nBitte jenes zuerst beenden oder in "
              f"HKCU\\{REG_KEY} unter „Port“ einen anderen Port eintragen.",
              f"Another NV-AI is already running on port {port} – for example a second "
              f"installation or the development version.\nPlease quit it first or set another "
              f"port under \"Port\" in HKCU\\{REG_KEY}.")


def start(open_browser: bool) -> int:
    env, port = _environment()
    info = _version(port)
    if info is None and _port_busy(port):
        _message(_t(f"Port {port} ist belegt, aber dort antwortet kein NV-AI.\n"
                    f"Anderes Programm beenden oder in HKCU\\{REG_KEY} einen anderen Port eintragen.",
                    f"Port {port} is in use, but no NV-AI answers there.\n"
                    f"Quit the other program or set another port in HKCU\\{REG_KEY}."))
        return 1
    if info is not None and info.get("name") != "NV-AI":
        _message(_t(f"Auf Port {port} läuft ein anderer Dienst ({info.get('name')}).",
                    f"Another service is running on port {port} ({info.get('name')})."))
        return 1
    # Ein NV-AI auf dem Port ist nur dann unseres, wenn die Kennung passt. Sonst haette
    # die Startmenue-Verknuepfung die Oberflaeche eines fremden NV-AI geoeffnet.
    if info is not None and info.get("instance") != _own_instance():
        _message(_foreign_nvai(port))
        return 1
    if info is None:
        server_dir = Path(__file__).resolve().parents[1]
        flags = 0
        for name in ("DETACHED_PROCESS", "CREATE_NEW_PROCESS_GROUP", "CREATE_NO_WINDOW"):
            flags |= getattr(subprocess, name, 0)
        subprocess.Popen([_pythonw(), "-m", "nvai.serve"], cwd=str(server_dir), env=env,
                         creationflags=flags, close_fds=True,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + START_TIMEOUT
        while (info := _version(port)) is None:
            if time.monotonic() > deadline:
                data_dir = env.get("NVAI_DATA_DIR") or str(server_dir.parent / "data")
                _message(_t(f"NV-AI ist nach {START_TIMEOUT:.0f} s nicht erreichbar.\n"
                            f"Protokoll: {Path(data_dir) / 'nvai-server.log'}",
                            f"NV-AI is not reachable after {START_TIMEOUT:.0f} s.\n"
                            f"Log: {Path(data_dir) / 'nvai-server.log'}"))
                return 1
            time.sleep(0.5)
    if open_browser:
        webbrowser.open(f"http://127.0.0.1:{port}/")
    return 0


def stop() -> int:
    _, port = _environment()
    info = _version(port)
    if info is None:
        return 0
    # Nur das eigene NV-AI beenden -- am 2026-10-19 beendete „NV-AI beenden“ einer
    # Testinstallation die Entwicklungsfassung, die auf demselben Port lief.
    if info.get("instance") != _own_instance():
        _message(_foreign_nvai(port) + _t("\nEs wurde nicht beendet.", "\nIt was not stopped."),
                 error=False)
        return 1
    req = urllib.request.Request(f"http://127.0.0.1:{port}/api/shutdown", method="POST")
    try:
        urllib.request.urlopen(req, timeout=5).close()
    except (OSError, urllib.error.HTTPError) as e:
        _message(_t(f"NV-AI ließ sich nicht beenden: {e}", f"NV-AI could not be stopped: {e}"))
        return 1
    deadline = time.monotonic() + 30
    while _port_busy(port) and time.monotonic() < deadline:
        time.sleep(0.5)
    return 0


def main(argv: list[str]) -> int:
    if "--stop" in argv:
        return stop()
    return start(open_browser="--open" in argv)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
