"""Stellt den Ordner ``addon\\`` für das NV-AI-Setup zusammen (docs/windows-installer.md).

    python tools/build_addon.py [Ziel] [--check]        Standard-Ziel: dist/addon

Inhalt: bridge\\ (nur Quelltext), panel\\ (mit icon.ico), requirements.lock und addon.ini mit
Version und Startbefehl für das Setup-Skript. Einen vorhandenen Zielordner ersetzt das Skript nur,
wenn er von ihm stammt (addon.ini darin). Ein vertippter Pfad löscht so nichts Fremdes.

``--check`` installiert danach wie das Setup ein venv aus dem Lock (braucht uv), lädt die Brücke
daraus und entfernt das venv wieder. Das prüft, dass der Ordner für sich allein läuft.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from bridge import __version__  # noqa: E402
from bridge.winutil import APP_ID  # noqa: E402

DEFAULT_TARGET = ROOT / "dist" / "addon"
MARKER = "addon.ini"
PYTHON = "3.12"
ICON = Path("panel") / "icon.ico"

# Nur ASCII in den Werten: Inno Setup liest die Datei mit ReadIni in der ANSI-Codepage.
INI = """\
; Erzeugt von tools/build_addon.py. Angaben für das NV-AI-Setup, siehe docs/windows-installer.md.
; Pfade relativ zum Add-on-Ordner. Installieren:
;   uv venv --python {python} .venv
;   uv pip sync --python .venv\\Scripts\\python.exe --require-hashes {requirements}
[addon]
version={version}
python={python}
requirements={requirements}
run=.venv\\Scripts\\pythonw.exe
parameters=-m bridge --launch
workdir=.
icon={icon}
appusermodelid={app_id}
"""


def _normalize(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def check_lock(lock: str) -> list[str]:
    """Probleme im Lock: fehlende Abhängigkeiten aus pyproject.toml, Pakete ohne Prüfsumme."""
    deps = tomllib.loads((ROOT / "pyproject.toml").read_text(encoding="utf-8"))["project"]["dependencies"]
    pinned = re.findall(r"^([A-Za-z0-9][A-Za-z0-9._-]*)==\S+((?:[ \t]*\\\r?\n[ \t]+--hash=sha256:[0-9a-f]{64})*)",
                        lock, re.MULTILINE)
    names = {_normalize(name) for name, _ in pinned}
    problems = [f"{dep} fehlt im Lock" for dep in deps
                if _normalize(re.match(r"[A-Za-z0-9._-]+", dep).group()) not in names]
    problems += [f"{name} ohne Prüfsumme" for name, hashes in pinned if not hashes]
    return problems


def build(target: Path) -> list[Path]:
    """Ordner neu aufbauen; gibt die geschriebenen Dateien zurück."""
    lock = (ROOT / "requirements.lock").read_text(encoding="utf-8")
    problems = check_lock(lock)
    if problems:
        raise SystemExit("requirements.lock passt nicht: " + "; ".join(problems))
    if not (ROOT / ICON).is_file():
        raise SystemExit(f"{ICON} fehlt – erst python tools/make_icon.py ausführen.")
    if target.exists():
        if not (target / MARKER).is_file():
            raise SystemExit(f"{target} gibt es schon und stammt nicht von diesem Skript (keine {MARKER}).")
        shutil.rmtree(target)
    target.mkdir(parents=True)
    shutil.copytree(ROOT / "bridge", target / "bridge", ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    shutil.copytree(ROOT / "panel", target / "panel")
    shutil.copy2(ROOT / "requirements.lock", target / "requirements.lock")
    (target / MARKER).write_text(
        INI.format(version=__version__, python=PYTHON, requirements="requirements.lock", icon=ICON, app_id=APP_ID),
        encoding="utf-8", newline="\r\n",
    )
    return sorted(p for p in target.rglob("*") if p.is_file())


def check(target: Path) -> None:
    """Wie das Setup installieren, die Brücke aus dem Ordner laden, venv wieder entfernen."""
    venv = target / ".venv"
    python = venv / "Scripts" / "python.exe"
    env = {k: v for k, v in os.environ.items() if k not in ("VIRTUAL_ENV", "PYTHONPATH", "PYTHONHOME")}
    try:
        subprocess.run(["uv", "venv", "--quiet", "--python", PYTHON, str(venv)], check=True, env=env)
        subprocess.run(["uv", "pip", "sync", "--quiet", "--python", str(python), "--require-hashes",
                        str(target / "requirements.lock")], check=True, env=env)
        with tempfile.TemporaryDirectory() as data:
            # Eigener Datenordner, damit die Probe nichts beim Nutzer anlegt, und kein __pycache__
            # im Add-on. Gestartet wie von der Verknüpfung: Arbeitsordner ist der Add-on-Ordner.
            env = dict(env, ARTCRAFT_LOCALAI_DATA=data, PYTHONDONTWRITEBYTECODE="1", PYTHONIOENCODING="utf-8")
            probe = ("import pathlib, bridge, bridge.server, bridge.window; from bridge import config; "
                     "assert config.ROOT == pathlib.Path.cwd(), config.ROOT; assert config.ICON_FILE.is_file(); "
                     "print('Brücke', bridge.__version__, 'lädt aus', config.ROOT)")
            subprocess.run([str(python), "-c", probe], check=True, cwd=target, env=env)
            subprocess.run([str(python), "-m", "bridge", "--help"], check=True, cwd=target, env=env,
                           stdout=subprocess.DEVNULL)
    finally:
        shutil.rmtree(venv, ignore_errors=True)


def main(argv: list[str]) -> int:
    args = [a for a in argv if a != "--check"]
    target = Path(args[0]).resolve() if args else DEFAULT_TARGET
    files = build(target)
    size = sum(p.stat().st_size for p in files)
    print(f"Add-on {__version__}: {target} ({len(files)} Dateien, {size / 1024:.0f} KB)", flush=True)
    if "--check" in argv:
        check(target)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
