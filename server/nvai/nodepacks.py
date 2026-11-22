"""ComfyUI-Knoten, die NVAI-open bei Bedarf von GitHub nachlaedt, statt sie mitzuliefern (seit 0.5.36).

Nutzer 22.11.2026: „lade das knotenpaket bei bedarf von github nach“. Layout-To-Render (IC-LoRA fuer LTX-2.5) braucht
die Knoten LTXICLoRALoaderModelOnly und LTXAddVideoICLoRAGuide aus Lightricks' ComfyUI-LTXVideo. Das Paket steht unter
der LTX-2 Community License, nicht MIT, deshalb liegt es weder im Setup noch im oeffentlichen Repo: Der erste
Layout-To-Render-Auftrag laedt die noetigen Dateien vom festen Commit, prueft jede gegen ihre SHA-256 und legt sie mit
der Lizenzdatei nach custom_nodes/nvai_ltxv_iclora. Nur diese Dateien, mit eigener __init__.py: Das ganze Paket laedt
beim Start Module, die colour-science, kornia, openimageio und diffusers brauchen, die im ComfyUI-venv fehlen.
"""
from __future__ import annotations

import hashlib
import shutil
from pathlib import Path

import httpx

from . import config
from .i18n import t

LTXV_REPO = "Lightricks/ComfyUI-LTXVideo"
LTXV_COMMIT = "ced6bad92b82f90028e1e1fd5a37527302550fc5"  # 12.11.2026
LTXV_FILES = {
    "iclora.py": "5737824a18438b6b5782836f1c606e47caa175d9efa93f56c4cbf9f91b5c72e5",
    "iclora_attention.py": "830248fb9e978bdcf61c4fc37f1ce4bf71ec37df40623890e7329594e096c0c9",
    "latents.py": "09c52b496ac183527682c77fd038eccbaca6894c75a33ea0c4bb0fdc2073bc16",
    "nodes_registry.py": "2e7d02a6d94faceb4e2d8fed0e0b9a7085dccec84d1c1e90ba4383705bf57982",
    "tiled_fusion_plan.py": "2a0358d011b875fcd7225859b8771caa7133f36b02ce2c47eeec82f6c2f84421",
    "LICENSE": "7c8ef302fa1444a3a5650c2dfa09c6927a52b233202431023abb32519f354397",
}
LTXV_DIR = "nvai_ltxv_iclora"
LTXV_NODES = ("LTXAddVideoICLoRAGuide", "LTXICLoRALoaderModelOnly")
INIT = f'''# NVAI-open: nur die IC-LoRA-Knoten aus Lightricks' ComfyUI-LTXVideo (Commit {LTXV_COMMIT[:7]}), bei Bedarf von
# GitHub geladen (server/nvai/nodepacks.py). Die Dateien dieses Ordners ausser dieser stehen unter der LTX-2 Community
# License (LICENSE).
from . import iclora  # noqa: F401  (traegt die Knoten in nodes_registry ein)
from .nodes_registry import NODE_CLASS_MAPPINGS as _ALL, NODE_DISPLAY_NAME_MAPPINGS as _NAMES

_KEEP = {LTXV_NODES!r}
NODE_CLASS_MAPPINGS = {{k: v for k, v in _ALL.items() if k in _KEEP}}
NODE_DISPLAY_NAME_MAPPINGS = {{k: v for k, v in _NAMES.items() if k in _KEEP}}
'''


def ltxv_dir() -> Path:
    return config.COMFY_ROOT / "custom_nodes" / LTXV_DIR


def ltxv_installed() -> bool:
    d = ltxv_dir()
    if not (d / "__init__.py").exists():
        return False
    for name, sha in LTXV_FILES.items():
        f = d / name
        if not f.exists() or hashlib.sha256(f.read_bytes()).hexdigest() != sha:
            return False
    return True


async def ensure_ltxv_iclora() -> bool:
    """Legt die Knoten ab, wenn sie fehlen oder nicht dem festen Stand entsprechen. True = neu abgelegt, ComfyUI muss
    dann neu starten, um sie zu laden."""
    if ltxv_installed():
        return False
    dest = ltxv_dir()
    tmp = dest.with_name(dest.name + ".new")
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True)
    try:
        async with httpx.AsyncClient(follow_redirects=True, timeout=httpx.Timeout(60.0, connect=30.0)) as client:
            for name, sha in LTXV_FILES.items():
                r = await client.get(f"https://raw.githubusercontent.com/{LTXV_REPO}/{LTXV_COMMIT}/{name}")
                r.raise_for_status()
                if hashlib.sha256(r.content).hexdigest() != sha:
                    raise RuntimeError(t(f"{LTXV_REPO}: {name} hat nicht die erwartete Prüfsumme",
                                         f"{LTXV_REPO}: {name} does not have the expected checksum"))
                (tmp / name).write_bytes(r.content)
        (tmp / "__init__.py").write_text(INIT, encoding="utf-8")
        shutil.rmtree(dest, ignore_errors=True)
        tmp.rename(dest)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return True
