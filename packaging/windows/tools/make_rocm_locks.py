"""Lock-Dateien fuer AMD erzeugen (Python 3.10+, braucht uv im PATH). Aus dem Ordner packaging\\windows:

    python tools\\make_rocm_locks.py [--comfy-kitchen 0.2.41]

1. hebt mit --comfy-kitchen in locks\\comfyui.lock (also auch fuer NVIDIA) comfy-kitchen auf diese Fassung
   (Pruefsummen aller Dateien von PyPI); ohne bleibt dort ComfyUIs Pin,
2. leitet locks\\comfyui-amd-base.lock daraus ab (ohne torch, torchvision, torchaudio; comfy-kitchen in der
   Fassung AMD_COMFY_KITCHEN),
3. loest mit uv den ROCm-Stapel aus AMDs Index auf: locks\\comfyui-rocm.lock (torch, torchvision, torchaudio und
   die ROCm-Laufzeit) und je Kartenfamilie locks\\comfyui-rocm-<gfx>.lock (die Kernel dieser Karte). Allgemeine
   Pakete (numpy, sympy ...) bleiben im Basis-Lock; install-runtime.ps1 installiert die ROCm-Locks mit --no-deps.
   Die ROCm-Locks nennen jede Datei mit fester Adresse (wie comfyui-rocm72.lock): die Pakete liegen teils bei AMD,
   teils auf PyPI (rocm-bootstrap), so braucht die Installation keinen Index.

Fassung wie in ComfyUIs README (AMD unter Windows): ROCm 10.0.0 mit PyTorch 2.13.0. ROCm 7.2.1 (torch 2.9.1, das
Paket von ComfyUIs eigener AMD-Fassung) bleibt als locks\\comfyui-rocm72.lock fuer "-Rocm 7.2".
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import unquote, urljoin

HERE = Path(__file__).resolve().parent.parent
LOCKS = HERE / "locks"
INDEX = "https://stable.repo.amd.com/rocm/whl-next/"
ROCM = "10.0.0"
TORCH = "2.13.0"
TORCHVISION = "0.28.0"
TORCHAUDIO = "2.11.0.2"
# Kartenfamilien wie in server\nvai\gpu.py (AMD_TARGETS) und install-runtime.ps1.
TARGETS = ["gfx1201", "gfx1200", "gfx1100", "gfx1101", "gfx1102", "gfx1151", "gfx1150", "gfx1103",
           "gfx1030", "gfx1031", "gfx1032"]
BASE_PACKAGES = {"rocm", "rocm-bootstrap", "rocm-sdk-core", "rocm-sdk-libraries", "torch", "torchvision",
                 "torchaudio"}
# comfy-kitchen fuer AMD abweichend von comfyui.lock; None = wie dort (ComfyUIs Pin, 0.42.1: ==0.2.39). Nicht ueber
# den Pin heben: 0.2.40 ("deltanet for tree MTP", #266) lehnt ComfyUI 0.42.1s Qwen3.5-Ausbau ab
# ("gated_delta_decode_deferred launch rejected" bei MOSS-Image) und der FLUX-3-Upsampler fand kein Textende mehr
# (3584 statt 185 Token), gemessen 26.10.2026 auf der RTX 5060 Ti. 0.2.39 hat die HIP-Kernel fuer gfx1200/1201 schon.
AMD_COMFY_KITCHEN = None
# Dateien fuer Python 3.12 unter Windows, in dieser Reihenfolge bevorzugt.
TAGS = ["-cp312-cp312-win_amd64.whl", "-cp312-abi3-win_amd64.whl", "-py3-none-win_amd64.whl", "-py3-none-any.whl",
        ".tar.gz"]


def blocks(text: str) -> tuple[list[str], list[tuple[str, str]]]:
    """Kopfzeilen und (Paketname, Block) einer uv-Lockdatei."""
    head, out, current, name = [], [], [], None
    for line in text.splitlines():
        m = re.match(r"^([A-Za-z0-9_.\-]+)(==| @ )", line)
        if m:
            if name:
                out.append((name, "\n".join(current)))
            name, current = m.group(1).lower().replace("_", "-"), [line]
        elif name:
            current.append(line)
        else:
            head.append(line)
    if name:
        out.append((name, "\n".join(current)))
    return head, out


def strip_via(block: str) -> str:
    """Die "# via"-Kommentare von uv weglassen (die Locks werden mit --no-deps installiert)."""
    return "\n".join(l for l in block.splitlines() if not l.lstrip().startswith("#")).rstrip()


def with_url(block: str) -> str:
    """"name==version" mit Pruefsumme -> "name @ Adresse" mit Pruefsumme. Auf PyPI zaehlt die Datei mit genau dieser
    Pruefsumme; AMDs Index nennt keine Pruefsummen, dort die Datei fuer Python 3.12 unter Windows (uv hat beim
    Aufloesen genau diese geladen und gehasht, die Installation prueft die Summe)."""
    first, *rest = strip_via(block).splitlines()
    name, version = re.match(r"^([A-Za-z0-9_.\-]+)==([^ \\]+)", first).groups()
    hashes = [re.search(r"sha256:([0-9a-f]{64})", l).group(1) for l in rest if "sha256:" in l]
    if len(hashes) != 1:
        sys.exit(f"{name}: {len(hashes)} Pruefsummen, erwartet genau eine")
    sha, url = hashes[0], None
    try:
        data = json.load(urllib.request.urlopen(f"https://pypi.org/pypi/{name}/{version}/json"))
        url = next((f["url"] for f in data["urls"] if f["digests"]["sha256"] == sha), None)
    except urllib.error.HTTPError:
        pass
    if url is None:
        page = urllib.request.urlopen(INDEX + name + "/")
        base, html = page.geturl(), page.read().decode("utf-8")
        files = {unquote(h.rsplit("/", 1)[-1]): urljoin(base, h) for h in re.findall(r'href="([^"#]+)', html)}
        stems = {re.sub(r"[-_.]+", "_", name) + "-" + version, name + "-" + version}
        url = next((files[s + tag] for tag in TAGS for s in stems if s + tag in files), None)
    if url is None:
        sys.exit(f"{name}=={version}: keine Datei fuer Python 3.12 unter Windows gefunden")
    return f"{name} @ {url} \\\n    --hash=sha256:{sha}"


def kitchen_block(version: str) -> tuple[str, int]:
    """comfy-kitchen==version mit den Pruefsummen aller Dateien von PyPI, im Format von uv."""
    data = json.load(urllib.request.urlopen(f"https://pypi.org/pypi/comfy-kitchen/{version}/json"))
    hashes = sorted(f["digests"]["sha256"] for f in data["urls"])
    return f"comfy-kitchen=={version} \\\n" + " \\\n".join(f"    --hash=sha256:{h}" for h in hashes), len(hashes)


def set_kitchen(text: str, version: str, where: str) -> str:
    block, n_files = kitchen_block(version)
    new, n = re.subn(r"^comfy-kitchen==[^\n]*(?:\n    --hash=sha256:[0-9a-f]+(?: \\)?)+", block, text, flags=re.M)
    if n != 1:
        sys.exit(f"comfy-kitchen nicht genau einmal in {where} gefunden")
    print(f"{where}: comfy-kitchen {version} ({n_files} Dateien)")
    return new


def bump_comfy_kitchen(version: str) -> None:
    path = LOCKS / "comfyui.lock"
    path.write_text(set_kitchen(path.read_text(encoding="utf-8"), version, "comfyui.lock"), encoding="utf-8",
                    newline="\n")


def amd_base() -> None:
    head, items = blocks((LOCKS / "comfyui.lock").read_text(encoding="utf-8"))
    keep = [b for name, b in items if name not in ("torch", "torchvision", "torchaudio")]
    text = ("# ComfyUI-Pakete fuer AMD (ROCm): wie comfyui.lock, aber ohne torch/torchvision/torchaudio --\n"
            "# die kommen aus comfyui-rocm.lock -- und mit comfy-kitchen " + (AMD_COMFY_KITCHEN or "wie dort") + ".\n"
            "# Erzeugt von tools\\make_rocm_locks.py, nicht von Hand aendern.\n"
            "--index-url https://pypi.org/simple\n\n" + "\n".join(keep) + "\n")
    if AMD_COMFY_KITCHEN:
        text = set_kitchen(text, AMD_COMFY_KITCHEN, "comfyui-amd-base.lock")
    (LOCKS / "comfyui-amd-base.lock").write_text(text, encoding="utf-8", newline="\n")
    print(f"comfyui-amd-base.lock: {len(keep)} Pakete")


def compile_target(target: str) -> list[tuple[str, str]]:
    req = "\n".join([f"torch=={TORCH}+rocm{ROCM}", f"torchvision=={TORCHVISION}+rocm{ROCM}",
                     f"torchaudio=={TORCHAUDIO}+rocm{ROCM}", f"amd-torch-device-{target}=={TORCH}+rocm{ROCM}",
                     f"amd-torchvision-device-{target}=={TORCHVISION}+rocm{ROCM}"]) + "\n"
    with tempfile.TemporaryDirectory() as tmp:
        src, out = Path(tmp) / "in.txt", Path(tmp) / "out.lock"
        src.write_text(req, encoding="utf-8")
        subprocess.run(["uv", "pip", "compile", str(src), "--python-version", "3.12", "--python-platform", "windows",
                        "--generate-hashes", "--index-url", INDEX, "--extra-index-url", "https://pypi.org/simple",
                        "--index-strategy", "unsafe-best-match", "--no-header", "-q", "-o", str(out)], check=True)
        return blocks(out.read_text(encoding="utf-8"))[1]


def rocm_locks() -> None:
    header = (f"# PyTorch {TORCH} mit ROCm {ROCM} fuer AMD-Grafikkarten unter Windows (AMDs Mehrarchitektur-Pakete, wie\n"
              "# in ComfyUIs README). Erzeugt von tools\\make_rocm_locks.py. Installiert mit --no-deps --require-hashes;\n"
              "# die uebrigen Abhaengigkeiten stehen in comfyui-amd-base.lock, die Kernel der Karte in\n"
              "# comfyui-rocm-<gfx>.lock.\n")
    base_written = False
    for target in TARGETS:
        items = compile_target(target)
        if not base_written:
            base = [with_url(b) for name, b in items if name in BASE_PACKAGES]
            (LOCKS / "comfyui-rocm.lock").write_text(header + "\n".join(base) + "\n", encoding="utf-8", newline="\n")
            print(f"comfyui-rocm.lock: {len(base)} Pakete")
            base_written = True
        device = [with_url(b) for name, b in items if target in name]
        (LOCKS / f"comfyui-rocm-{target}.lock").write_text(
            f"# Kernel fuer {target} zu comfyui-rocm.lock (ROCm {ROCM}, PyTorch {TORCH}). Erzeugt von\n"
            "# tools\\make_rocm_locks.py; installiert mit --no-deps --require-hashes.\n" + "\n".join(device) + "\n",
            encoding="utf-8", newline="\n")
        print(f"comfyui-rocm-{target}.lock: {len(device)} Pakete")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--comfy-kitchen", default=None, help="comfy-kitchen in comfyui.lock auf diese Fassung heben")
    ap.add_argument("--skip-rocm", action="store_true")
    args = ap.parse_args()
    if args.comfy_kitchen:
        bump_comfy_kitchen(args.comfy_kitchen)
    amd_base()
    if not args.skip_rocm:
        rocm_locks()
