"""DirectML-Modus fuer Radeons ohne ROCm unter Windows (RX 5000, Vega, Polaris; GitHub-Issue #3).

torch-directml gibt es nur fuer PyTorch 2.4.1, und ComfyUI hat DirectML in 0.46.0 entfernt. NVAI-open richtet dafuer
ein eigenes venv ein (``external/comfyui/.venv-directml``: PyTorch 2.4.1, torch-directml und ``nvai_directml`` aus
packaging/windows/directml) und setzt DirectML hier wieder in ComfyUI ein, vor jedem Start; ohne ``--directml``
aendert der Einsatz nichts. Anders als ComfyUIs alter Code kennt er den Speicher: nvai_directml fragt Windows nach dem
Budget des Prozesses (DXGI), Modelle werden wie unter CUDA gewechselt; mit den angenommenen 1 GB hielt ComfyUI alle
Modelle zugleich (SDXL: 13,6 GB auf einer 16-GB-Karte). Das CPU-venv bleibt fuer Audio, Text und den Rueckfall.

Die Aenderungen an ComfyUI sind Textersetzungen mit festen Ankern (jeder genau einmal). Passt ein Anker nicht (neue
ComfyUI-Fassung), bleibt ComfyUI unveraendert und NVAI-open rechnet auf dem Prozessor.
"""
from __future__ import annotations

import json
import logging
import os
from pathlib import Path
from typing import Any

from . import config

log = logging.getLogger("nvai.directml")

MARK = "NVAI-open DirectML patch v4"

# Der Einsatz ruft nur nvai_directml (packaging/windows/directml, liegt im DirectML-venv): Geraetewahl und
# Speicherzahlen aus DXGI. So bleibt der Eingriff in ComfyUI klein.
_BLOCK = '''
# {mark}: torch-directml (PyTorch 2.4.1) for Radeons without ROCm on Windows (RX 5000, Vega, Polaris). ComfyUI
# removed DirectML in 0.46.0; NVAI-open adds it back for its DirectML venv. The memory figures come from nvai_directml
# (the budget Windows gives this process, via DXGI), so models are swapped and partly loaded as on CUDA; ComfyUI's old
# code assumed 1 GB and kept every model loaded.
directml_enabled = False
directml_device = None
if getattr(args, "directml", None) is not None:
    import nvai_directml
    directml_enabled = True
    directml_device = nvai_directml.device(args.directml)
    logging.info("Using DirectML with device: {{}}".format(nvai_directml.label()))


def directml_total_memory():
    return nvai_directml.total_memory()


def directml_free_memory():
    return nvai_directml.free_memory()


def directml_sync():
    nvai_directml.sync()


def is_directml_enabled():
    return directml_enabled

'''

# (Datei, Anker, Ersatz); der Anker muss genau einmal vorkommen.
EDITS: list[tuple[str, str, str]] = [
    ("comfy/cli_args.py",
     'parser.add_argument("--force-channels-last", action="store_true", help="Force channels last format when '
     'inferencing the models.")\n',
     'parser.add_argument("--force-channels-last", action="store_true", help="Force channels last format when '
     'inferencing the models.")\n\n'
     f'# {MARK}\n'
     'parser.add_argument("--directml", type=int, nargs="?", metavar="DIRECTML_DEVICE", const=-1, '
     'help="Use torch-directml (added back by NVAI-open for Radeons without ROCm).")\n'),
    ("comfy/model_management.py",
     'if args.deterministic:\n    logging.info("Using deterministic algorithms for pytorch")\n'
     '    torch.use_deterministic_algorithms(True, warn_only=True)\n',
     'if args.deterministic:\n    logging.info("Using deterministic algorithms for pytorch")\n'
     '    torch.use_deterministic_algorithms(True, warn_only=True)\n'
     + _BLOCK.format(mark=MARK)),
    # DirectMLs Speicherfehler heisst nicht "out of memory": ohne das kein Rueckfall auf kachelweises Dekodieren
    ("comfy/model_management.py",
     "def is_oom(e):\n    if isinstance(e, OOM_EXCEPTION):\n        return True\n",
     "def is_oom(e):\n    if isinstance(e, OOM_EXCEPTION):\n        return True\n"
     "    if directml_enabled and \"not enough gpu video memory\" in str(e).lower():\n        return True\n"),
    # vor jeder Lade-Entscheidung die Warteschlange leeren, sonst zaehlen gerade freigegebene Tensoren noch als belegt
    ("comfy/model_management.py",
     "def free_memory(memory_required, device, keep_loaded=[], for_dynamic=False, pins_required=0, ram_required=0):\n"
     "    cleanup_models_gc()\n",
     "def free_memory(memory_required, device, keep_loaded=[], for_dynamic=False, pins_required=0, ram_required=0):\n"
     "    cleanup_models_gc()\n    if directml_enabled:\n        directml_sync()\n"),
    ("comfy/model_management.py",
     "def get_torch_device():\n    global cpu_state\n",
     "def get_torch_device():\n    global cpu_state\n    if directml_enabled:\n        return directml_device\n"),
    ("comfy/model_management.py",
     "        mem_total_torch = mem_total\n    else:\n        if is_intel_xpu():\n"
     "            stats = torch.xpu.memory_stats(dev)\n            mem_reserved = stats['reserved_bytes.all.current']\n",
     "        mem_total_torch = mem_total\n    else:\n        if directml_enabled:\n"
     "            mem_total = mem_total_torch = directml_total_memory()\n        elif is_intel_xpu():\n"
     "            stats = torch.xpu.memory_stats(dev)\n            mem_reserved = stats['reserved_bytes.all.current']\n"),
    ("comfy/model_management.py",
     "        mem_free_torch = mem_free_total\n    else:\n        if is_intel_xpu():\n"
     "            stats = torch.xpu.memory_stats(dev)\n            mem_active = stats['active_bytes.all.current']\n",
     "        mem_free_torch = mem_free_total\n    else:\n        if directml_enabled:\n"
     "            mem_free_total, mem_free_torch = directml_free_memory()\n        elif is_intel_xpu():\n"
     "            stats = torch.xpu.memory_stats(dev)\n            mem_active = stats['active_bytes.all.current']\n"),
    ("comfy/model_management.py",
     "    if dtype == torch.float16:\n        return True\n    if dtype == torch.bfloat16:\n        return True\n"
     "    if is_device_mps(device):\n",
     "    if dtype == torch.float16:\n        return True\n    if directml_enabled:\n        return False\n"
     "    if dtype == torch.bfloat16:\n        return True\n    if is_device_mps(device):\n"),
    ("comfy/model_management.py",
     "    if args.deterministic: #TODO: figure out why deterministic breaks non blocking from gpu to cpu (previews)\n"
     "        return False\n    return True\n",
     "    if args.deterministic: #TODO: figure out why deterministic breaks non blocking from gpu to cpu (previews)\n"
     "        return False\n    if directml_enabled:\n        return False\n    return True\n"),
    ("comfy/model_management.py",
     "    if FORCE_FP32:\n        return False\n\n    if (device is not None and is_device_mps(device)) or mps_mode():\n"
     "        return True\n",
     "    if FORCE_FP32:\n        return False\n\n    if directml_enabled:\n        return True\n\n"
     "    if (device is not None and is_device_mps(device)) or mps_mode():\n        return True\n"),
    ("comfy/model_management.py",
     "    if FORCE_FP32:\n        return False\n\n    if (device is not None and is_device_mps(device)) or mps_mode():\n"
     "        if mac_version() < (14,):\n",
     "    if FORCE_FP32:\n        return False\n\n    if directml_enabled:\n        return False\n\n"
     "    if (device is not None and is_device_mps(device)) or mps_mode():\n        if mac_version() < (14,):\n"),
    ("comfy/model_management.py",
     "def supports_fp64(device=None):\n",
     "def supports_fp64(device=None):\n    if directml_enabled:\n        return False\n"),
    ("comfy/model_management.py",
     "def supports_int8_compute(device=None):\n",
     "def supports_int8_compute(device=None):\n    if directml_enabled:\n        return False\n"),
    ("comfy/model_management.py",
     "    elif torch.cuda.is_available():\n        torch.cuda.synchronize()\n        torch.cuda.empty_cache()\n"
     "        torch.cuda.ipc_collect()\n",
     "    elif directml_enabled:\n        directml_sync()\n"
     "    elif torch.cuda.is_available():\n        torch.cuda.synchronize()\n        torch.cuda.empty_cache()\n"
     "        torch.cuda.ipc_collect()\n"),
    # Text-Encoder unter DirectML auf dem Prozessor: viele liegen in FP8 vor (umt5-xxl fuer Wan, T5 fuer LTX-Video),
    # und FP8 auf dem DirectML-Geraet beendet den Prozess hart ("Invalid or unsupported data type Float8_e4m3fn");
    # nebenbei bleibt der Grafikspeicher dem Bild- oder Videomodell.
    ("comfy/model_management.py",
     "def text_encoder_device():\n    if args.gpu_only:\n        return get_torch_device()\n",
     f"def text_encoder_device():\n    if directml_enabled:  # {MARK}: FP8 text encoders abort on DirectML\n"
     "        return torch.device(\"cpu\")\n    if args.gpu_only:\n        return get_torch_device()\n"),
    # DirectML reiht die Arbeit weit voraus ein, und jede Zwischenrechnung belegt ihren Speicher schon beim Einreihen:
    # ohne Abgleich je Teilstueck lagen bei SDXL bis zu 9 GB Aufmerksamkeits-Zwischenstaende gleichzeitig im Speicher.
    ("comfy/ldm/modules/attention.py",
     "                r1[:, i:end] = einsum('b i j, b j d -> b i d', s2, v)\n                del s2\n            break\n",
     "                r1[:, i:end] = einsum('b i j, b j d -> b i d', s2, v)\n                del s2\n"
     f"                if getattr(model_management, \"directml_enabled\", False):  # {MARK}\n"
     "                    model_management.directml_sync()\n            break\n"),
    # Unter DirectML die Schaetzung des VAE ernst nehmen: passt sie nicht, gleich kachelweise. Der ungeteilte Versuch
    # belegte bei SDXL 1024² rund 9 GB, bevor er scheiterte (oder Windows ihn in den langsamen Arbeitsspeicher schob).
    ("comfy/sd.py",
     '                if getattr(self.first_stage_model, "comfy_decode_estimate_is_reliable", False):\n',
     '                if getattr(self.first_stage_model, "comfy_decode_estimate_is_reliable", False) or '
     f'getattr(model_management, "directml_enabled", False):  # {MARK}\n'),
    ("latent_preview.py",
     '        latents_ubyte = latents_ubyte.to(device="cpu", dtype=torch.uint8, '
     'non_blocking=comfy.model_management.device_supports_non_blocking(latent_image.device))\n',
     '        if getattr(comfy.model_management, "directml_enabled", False):  # ' + MARK + '\n'
     '            latents_ubyte = latents_ubyte.to(dtype=torch.uint8)\n'
     '        latents_ubyte = latents_ubyte.to(device="cpu", dtype=torch.uint8, '
     'non_blocking=comfy.model_management.device_supports_non_blocking(latent_image.device))\n'),
]


class PatchError(RuntimeError):
    pass


def _read(p: Path) -> str:
    return p.read_bytes().decode("utf-8")


def patch_comfyui(root: Path | None = None) -> bool:
    """Setzt DirectML in ComfyUI ein (idempotent). False = schon eingesetzt; PatchError = Anker fehlt, nichts geaendert.

    Je Datei bleibt das Original als ``<datei>.nvai-orig`` liegen: Mit einer neuen Fassung dieses Einsatzes wird von dort
    neu eingesetzt. Ein Setup-Update packt ComfyUI ohnehin frisch aus."""
    root = Path(root or config.COMFY_ROOT)
    files = sorted({f for f, _, _ in EDITS})
    texts: dict[str, str] = {}
    for f in files:
        p = root / f
        orig = p.with_name(p.name + ".nvai-orig")
        text = _read(p)
        if MARK in text:
            continue
        if "NVAI-open DirectML patch" in text:  # aeltere Fassung des Einsatzes: vom Original neu
            if not orig.exists():
                raise PatchError(f"{f}: alter Einsatz ohne Original")
            text = _read(orig)
        texts[f] = text
    if not texts:
        return False
    new = dict(texts)
    for f, anchor, repl in EDITS:
        if f not in new:
            continue
        n = new[f].count(anchor)
        if n != 1:
            raise PatchError(f"{f}: Anker {anchor.strip()[:60]!r} kommt {n}-mal vor")
        new[f] = new[f].replace(anchor, repl)
    for f, text in new.items():
        p = root / f
        orig = p.with_name(p.name + ".nvai-orig")
        if not orig.exists():
            orig.write_bytes(texts[f].encode("utf-8"))
        tmp = p.with_name(p.name + ".nvai-tmp")
        tmp.write_bytes(text.encode("utf-8"))
        os.replace(tmp, p)
    log.info("DirectML in ComfyUI eingesetzt (%s)", ", ".join(new))
    return True


# Startschalter fuer ComfyUI mit DirectML (gemessen 22.11.2026, SDXL 1024², 28 Schritte, nachgestelltes 7-GB-Budget,
# notizen/gpu.md): ohne dynamischen VRAM (comfy-aimdo kennt nur CUDA/ROCm); --disable-smart-memory entlaedt die
# anderen Modelle, bevor eines geladen wird (sonst blieb der Text-Encoder liegen und SDXL lud nur teilweise);
# --reserve-vram 0.25: das Budget von Windows beruecksichtigt andere Programme schon, ComfyUIs eigene 0,6 GB machten
# SDXL auf 8 GB zur Teilladung; geteilte Aufmerksamkeit: 4,5 s je Schritt, ComfyUIs Vorgabe fuer DirectML
# (sub-quadratic) 5,8 s, PyTorchs eigene 9,1 s, gleiches Bild.
COMFY_ARGS = ["--directml", "--disable-dynamic-vram", "--disable-smart-memory", "--reserve-vram", "0.25",
              "--use-split-cross-attention"]

# Grund, falls DirectML in dieser Sitzung nicht startete; dann rechnet ComfyUI bis zum naechsten Start auf dem
# Prozessor, und die Leiste sagt warum.
FAILED: str | None = None


def venv_python() -> Path:
    override = os.getenv("NVAI_DML_PYTHON")  # Tests: ein DirectML-venv ausserhalb der Installation
    return Path(override) if override else config.COMFY_ROOT / ".venv-directml" / "Scripts" / "python.exe"


def state() -> dict[str, Any] | None:
    """Was das Setup eingerichtet hat (gpu_mode.json: "directml": {"ok", "device", "torch"}), oder None."""
    try:
        saved = json.loads((config.DATA_DIR / "gpu_mode.json").read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return None
    dml = saved.get("directml") if isinstance(saved, dict) else None
    return dml if isinstance(dml, dict) else None


def active() -> dict[str, Any] | None:
    """{"device"} wenn ComfyUI mit DirectML rechnen soll: vom Setup eingerichtet und geprueft, venv vorhanden, nicht
    abgeschaltet (NVAI_DIRECTML=0) und in dieser Sitzung nicht gescheitert. Sonst None (Prozessor)."""
    if FAILED or os.getenv("NVAI_DIRECTML", "1") == "0":
        return None
    st = state()
    if not st or not st.get("ok") or not venv_python().exists():
        return None
    return {"device": str(st.get("device") or "")}


def fail(reason: str) -> None:
    global FAILED
    FAILED = (reason or "?").strip()[-600:]
    log.warning("DirectML abgeschaltet, ComfyUI rechnet auf dem Prozessor: %s", FAILED)
