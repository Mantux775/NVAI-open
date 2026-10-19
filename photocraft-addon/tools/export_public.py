"""Writes the public source folder of the add-on (target in the NVAI-open repository: photocraft-addon/).

    python tools/export_public.py <target>

Copies only what belongs in the public repository: bridge, panel, PhotoCraftKit, MacApp, tools,
tests, golden, contract, docs, scripts, requirements.lock, pyproject.toml, READMEs and
THIRD_PARTY.md – no venv, build folders, caches, settings.json, logs or internal notes.

Afterwards every exported text file is checked for personal paths (the private development
folder, /Users/<name>, C:\\Users\\<name>), the local user and computer name, e-mail addresses,
IPv4 addresses and token-like hex strings. If anything is found, the export fails and lists it –
nothing may leak.

An existing target is only replaced if it is empty or holds an earlier export (bridge/ and
PhotoCraftKit/ in it), so a mistyped path cannot wipe out anything else.
"""
from __future__ import annotations

import getpass
import os
import re
import shutil
import socket
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# (Quelle, Muster) – Ordner werden rekursiv mit den Mustern übernommen.
INCLUDE: list[tuple[str, tuple[str, ...]]] = [
    ("bridge", ("*.py",)),
    ("panel", ("*.html", "*.css", "*.js", "*.ico")),
    ("PhotoCraftKit/Package.swift", ()),
    ("PhotoCraftKit/Sources", ("*.swift",)),
    ("PhotoCraftKit/Tests", ("*.swift", "*.json")),
    ("MacApp/Package.swift", ()),
    ("MacApp/Sources", ("*.swift",)),
    ("MacApp/Resources", ("*.plist", "*.strings")),
    ("MacApp/tools", ("*.swift",)),
    ("MacApp/build-app.sh", ()),
    ("tools", ("*.py",)),
    ("tests", ("*.py",)),
    ("golden", ("*.json",)),
    ("contract", ("*.json",)),
    ("docs/mac-port.md", ()),
    ("docs/windows-installer.md", ()),
    ("scripts", ("*.ps1",)),
    ("requirements.lock", ()),
    ("pyproject.toml", ()),
    (".gitignore", ()),
    ("README.md", ()),
    ("README.de.md", ()),
    ("THIRD_PARTY.md", ()),
]
SKIP_DIRS = {"__pycache__", ".build", ".build-swift6", "build", ".venv", "dist", ".pytest_cache"}
BINARY_SUFFIXES = {".ico", ".png", ".icns"}


def files_to_export() -> list[Path]:
    out: list[Path] = []
    for source, patterns in INCLUDE:
        path = ROOT / source
        if path.is_file():
            out.append(path)
            continue
        if not path.is_dir():
            raise SystemExit(f"missing in the repository: {source}")
        for pattern in patterns:
            for f in path.rglob(pattern):
                if f.is_file() and not SKIP_DIRS.intersection(f.relative_to(ROOT).parts):
                    out.append(f)
    return sorted(set(out))


def leak_patterns() -> list[tuple[str, re.Pattern[str]]]:
    personal = {getpass.getuser(), Path.home().name, socket.gethostname(), os.environ.get("COMPUTERNAME", "")}
    patterns = [
        ("private path", re.compile(r"[A-Za-z]:[\\/]+CLAUDE\b", re.IGNORECASE)),
        ("home folder", re.compile(r"/Users/(?!<|…|\.\.\.)[\w.-]+")),
        ("home folder", re.compile(r"[A-Za-z]:[\\/]+Users[\\/]+(?!Test\b|<)[\w.-]+", re.IGNORECASE)),
        ("e-mail address", re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.-]*[A-Za-z]\b")),
        ("IPv4 address", re.compile(r"\b(?!127\.0\.0\.1\b|0\.)(?:\d{1,3}\.){3}\d{1,3}\b")),
        ("token-like hex", re.compile(r"\b[0-9a-f]{40,}\b")),
    ]
    for word in sorted(w for w in personal if w and len(w) >= 3):
        patterns.append(("user or computer name", re.compile(rf"\b{re.escape(word)}\b", re.IGNORECASE)))
    return patterns


def check(target: Path) -> list[str]:
    findings = []
    patterns = leak_patterns()
    for f in sorted(target.rglob("*")):
        if not f.is_file() or f.suffix in BINARY_SUFFIXES:
            continue
        rel = f.relative_to(target).as_posix()
        text = f.read_text(encoding="utf-8")
        for number, line in enumerate(text.splitlines(), 1):
            for label, pattern in patterns:
                if label == "token-like hex" and rel == "requirements.lock":
                    continue  # Paket-Prüfsummen (sha256) gehören dorthin
                for match in pattern.finditer(line):
                    findings.append(f"{rel}:{number}: {label}: {match.group(0)}")
    return findings


def export(target: Path) -> list[Path]:
    if target.exists() and any(target.iterdir()):
        if not ((target / "bridge").is_dir() and (target / "PhotoCraftKit").is_dir()):
            raise SystemExit(f"{target} is not empty and holds no earlier export – refusing to replace it.")
        shutil.rmtree(target)
    target.mkdir(parents=True, exist_ok=True)
    written = []
    for f in files_to_export():
        dest = target / f.relative_to(ROOT)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(f, dest)
        written.append(dest)
    return written


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print(__doc__)
        return 2
    target = Path(argv[0]).resolve()
    if (target == ROOT or ROOT in target.parents) and (ROOT / "dist") not in target.parents:
        raise SystemExit("The target must lie outside this repository (or below dist/).")
    written = export(target)
    findings = check(target)
    if findings:
        print("Possible personal data – export unusable until fixed:", file=sys.stderr)
        print("\n".join(f"  {x}" for x in findings), file=sys.stderr)
        return 1
    size = sum(p.stat().st_size for p in written)
    print(f"{target}: {len(written)} files, {size / 1024:.0f} KB, no personal data found")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
