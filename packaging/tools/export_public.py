"""Copies the public parts of this repository into a separate folder for NVAI-open.

    python packaging/tools/export_public.py <target folder> [--addon <exported add-on folder>]

Only allow-listed paths are copied; build output, caches, virtual environments, local data
and everything private (other projects, notes, signing material) stay behind. The target
folder is emptied first, except for its .git directory, so the export can be repeated.
Afterwards run the leak check (packaging/tools/check_public.py) on the target.
"""
from __future__ import annotations

import shutil
import sys
from pathlib import Path

SRC = Path(__file__).resolve().parents[2]

# (source, target) relative paths; folders are copied recursively.
INCLUDE = [
    ("server/nvai", "server/nvai"),
    ("server/workers", "server/workers"),
    ("server/pyproject.toml", "server/pyproject.toml"),
    ("server/openapi.json", "server/openapi.json"),
    ("frontend/src", "frontend/src"),
    ("frontend/index.html", "frontend/index.html"),
    ("frontend/package.json", "frontend/package.json"),
    ("frontend/package-lock.json", "frontend/package-lock.json"),
    ("frontend/tsconfig.json", "frontend/tsconfig.json"),
    ("frontend/vite.config.ts", "frontend/vite.config.ts"),
    ("scripts", "scripts"),
    ("packaging/windows", "packaging/windows"),
    ("packaging/tools", "packaging/tools"),
    ("packaging/assets", "packaging/assets"),
    ("mac/NVAIMac", "mac/NVAIMac"),
    ("docs", "docs"),
    ("LICENSE", "LICENSE"),
    # The public README and .gitignore differ from the private ones of this repository.
    ("packaging/public/README.md", "README.md"),
    ("packaging/public/gitignore", ".gitignore"),
    ("packaging/public/gitattributes", ".gitattributes"),
]
# Never copied, wherever they appear.
SKIP_DIRS = {"__pycache__", ".venv", "node_modules", "dist", "build", "dd", "SourcePackages",
             "release", ".build", ".swiftpm", "xcuserdata", ".git", "data", ".pytest_cache"}
SKIP_SUFFIXES = {".pyc", ".pyo", ".log", ".p12", ".p8", ".cer", ".mobileprovision",
                 ".tsbuildinfo", ".DS_Store"}
SKIP_NAMES = {".DS_Store", "settings.json", "Thumbs.db"}


def _ignore(directory: str, names: list[str]) -> set[str]:
    out = set()
    for n in names:
        p = Path(directory) / n
        if (p.is_dir() and (n in SKIP_DIRS or n.endswith(".egg-info") or n.endswith(".xcodeproj"))) \
                or (p.is_file() and (p.suffix in SKIP_SUFFIXES or n in SKIP_NAMES)):
            out.add(n)
    return out


def main(argv: list[str]) -> int:
    target = Path(argv[0]).resolve()
    if target == SRC or SRC in target.parents:
        raise SystemExit("The target must be outside this repository.")
    target.mkdir(parents=True, exist_ok=True)
    for child in target.iterdir():
        if child.name == ".git":
            continue
        shutil.rmtree(child) if child.is_dir() else child.unlink()
    for src_rel, dst_rel in INCLUDE:
        src, dst = SRC / src_rel, target / dst_rel
        if not src.exists():
            print(f"missing, skipped: {src_rel}")
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        if src.is_dir():
            shutil.copytree(src, dst, ignore=_ignore)
        else:
            shutil.copy2(src, dst)
    if "--addon" in argv:
        addon = Path(argv[argv.index("--addon") + 1])
        shutil.copytree(addon, target / "photocraft-addon", ignore=_ignore)
    files = sum(1 for p in target.rglob("*") if p.is_file() and ".git" not in p.parts)
    print(f"exported {files} files to {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
