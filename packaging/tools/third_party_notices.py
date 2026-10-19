"""Builds THIRD_PARTY_NOTICES.txt for the Windows setup and the repository.

    python packaging/tools/third_party_notices.py <output file> [--addon-licenses <file>]

The notices are generated from what is actually shipped, not maintained by hand:
- npm packages bundled into frontend/dist (runtime dependencies of frontend/package.json,
  followed recursively through node_modules, plus three.js as peer dependency of
  model-viewer), each with its full license text from node_modules;
- uv (bundled as tools/uv.exe), license texts from packaging/windows/licenses/uv;
- ComfyUI (GPL-3.0, its complete source is shipped in external/comfyui together with its
  LICENSE file);
- the FLUX 3 prompt-upsampler system prompts in server/nvai/flux3_pup_prompts.json, taken
  from Black Forest Labs' Apache-2.0 inference code;
- optionally a text file with the notices of the PhotoCraft add-on (--addon-licenses).
Python packages are not shipped: the setup downloads them from PyPI and the PyTorch index;
their exact versions are listed in packaging/windows/locks.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
FRONTEND = REPO / "frontend"
LICENSE_NAMES = ("LICENSE", "LICENSE.md", "LICENSE.txt", "LICENCE", "license", "LICENSE-MIT")


def _license_text(pkg_dir: Path) -> str:
    text = "(No license file in the package; license field: see package.json.)"
    for name in LICENSE_NAMES:
        f = pkg_dir / name
        if f.exists():
            text = f.read_text(encoding="utf-8", errors="replace").strip()
            break
    # Apache-2.0 section 4(d): a NOTICE file has to travel with the code.
    for name in ("NOTICE", "NOTICE.md", "NOTICE.txt"):
        f = pkg_dir / name
        if f.exists():
            text += "\n\nNOTICE:\n" + f.read_text(encoding="utf-8", errors="replace").strip()
            break
    return text


def npm_packages() -> list[tuple[str, str, str, str]]:
    """(name, version, license, text) for all bundled runtime packages."""
    nm = FRONTEND / "node_modules"
    seen: dict[str, tuple[str, str, str, str]] = {}

    def walk(name: str) -> None:
        if name in seen:
            return
        pkg = nm.joinpath(*name.split("/"))
        meta_file = pkg / "package.json"
        if not meta_file.exists():
            return
        meta = json.loads(meta_file.read_text(encoding="utf-8"))
        if name.startswith("@types/"):
            return                           # type definitions are not bundled
        license_ = meta.get("license") or "see license text"
        seen[name] = (name, meta.get("version", "?"), license_, _license_text(pkg))
        for dep in (meta.get("dependencies") or {}):
            walk(dep)
        for dep in (meta.get("peerDependencies") or {}):
            walk(dep)                        # e.g. three.js for model-viewer

    for dep in json.loads((FRONTEND / "package.json").read_text(encoding="utf-8"))["dependencies"]:
        walk(dep)
    return sorted(seen.values())


def main(argv: list[str]) -> int:
    out = Path(argv[0])
    addon = None
    if "--addon-licenses" in argv:
        addon = Path(argv[argv.index("--addon-licenses") + 1])
    uv_dir = REPO / "packaging" / "windows" / "licenses" / "uv"
    parts = [
        "NV-AI - Third-Party Notices",
        "==========================",
        "",
        "NV-AI itself is licensed under the MIT License (see LICENSE). It ships or uses the",
        "following third-party components, each under its own license.",
        "",
        "ComfyUI - GNU General Public License v3.0",
        "  https://github.com/comfyanonymous/ComfyUI",
        "  The complete source code is included in external\\comfyui together with its LICENSE",
        "  file. NV-AI runs ComfyUI as a separate program and talks to it over HTTP.",
        "",
        "uv - MIT or Apache-2.0 (at your option)",
        "  https://github.com/astral-sh/uv - bundled as tools\\uv.exe, license texts below.",
        "",
        "TripoSG - MIT (optional 3D component)",
        "  https://github.com/VAST-AI-Research/TripoSG - source in external\\triposg together",
        "  with its LICENSE and NOTICE files. Its Python environment is downloaded during setup",
        "  (it includes pymeshlab, GPL-3.0, installed from PyPI - not shipped with the setup).",
        "",
        "Python (python-build-standalone) - Python Software Foundation License",
        "  Downloaded by uv during setup into python\\, license included there.",
        "",
        "Python packages (PyTorch, FastAPI, uvicorn, Pillow, huggingface_hub and others)",
        "  Downloaded from PyPI and the PyTorch index during setup, not shipped with the setup.",
        "  Exact versions: locks\\server.lock and locks\\comfyui.lock. Each package's license is",
        "  in its *.dist-info folder after installation.",
        "",
        "FLUX 3 prompt-upsampler system prompts - Apache-2.0",
        "  server\\nvai\\flux3_pup_prompts.json and the planning logic in",
        "  server\\nvai\\flux3_prompt.py are derived from Black Forest Labs' FLUX 3 inference",
        "  code (Apache License 2.0). Copyright Black Forest Labs.",
        "",
        "Microsoft Edge WebView2 Runtime (PhotoCraft add-on only)",
        "  Downloaded from Microsoft during setup if missing; subject to Microsoft's license.",
        "  The add-on's Python packages (pywebview with the WebView2 SDK, pythonnet and others)",
        "  are installed from PyPI during setup; they are listed in the add-on section below.",
        "",
        "NV-AI for Mac",
        "  The Swift packages of the Mac app (flux-2-swift-mlx, mlx-swift, ml-stable-diffusion,",
        "  swift-transformers and others) are listed with their full license texts in",
        "  mac/NVAIMac/Resources/Third-Party-Notices.txt, shown in the app under Licenses.",
        "",
        "Models",
        "  NV-AI contains no model weights. Models are downloaded from Hugging Face on request;",
        "  each model has its own license, shown in NV-AI's model list (for example Apache-2.0",
        "  for Qwen-Image-2512, FLUX Kommunity License v1.0 for FLUX 3 Image Klein).",
        "",
        "Web interface (bundled npm packages)",
    ]
    packages = npm_packages()
    for name, version, license_, _ in packages:
        parts.append(f"  {name} {version} - {license_}")
    parts += ["", "", "License texts", "=============", ""]
    for name in ("LICENSE-MIT", "LICENSE-APACHE"):
        f = uv_dir / name
        if f.exists():
            parts += [f"--- uv: {name} ---", f.read_text(encoding="utf-8").strip(), ""]
    for name, version, _, text in packages:
        parts += [f"--- {name} {version} ---", text, ""]
    if addon and addon.exists():
        parts += ["", "PhotoCraft add-on", "=================", "",
                  addon.read_text(encoding="utf-8").strip(), ""]
    out.write_text("\n".join(parts) + "\n", encoding="utf-8")
    print(f"{out}: {len(packages)} npm packages")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
