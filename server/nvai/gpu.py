"""GPU-Erkennung ohne laufendes Backend.

ComfyUI meldet VRAM erst, wenn es laeuft. Fuer die Modellauswahl braucht der
Server die Zahl aber schon vorher -- sonst kann er nicht sagen, welches Modell
auf diese Karte passt. nvidia-smi liegt auf jedem NVIDIA-System im Systempfad
und antwortet in Millisekunden.

Seit 0.5 (experimentell): alle Karten statt nur der ersten, und AMD-Karten (ROCm).
AMD liest die Windows-Treiberdaten aus der Registry -- dort steht der echte
Grafikspeicher (qwMemorySize), WMI meldet hoechstens 4 GB.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
from typing import Any

from pathlib import Path

from . import config
from .i18n import t

# Ergebnis kurz halten: die Karte wechselt nicht waehrend der Laufzeit, aber ein
# Prozessaufruf pro Health-Abfrage waere trotzdem Verschwendung.
_cache: list[dict[str, Any]] | None = None
_cached_at = 0.0
_TTL = 300.0

ROLES = ("image", "text", "mesh")
ASSIGNMENT_FILE = config.DATA_DIR / "gpus.json"

# Karten nach Steckplatz zaehlen, wie nvidia-smi. CUDA sortiert sonst "schnellste zuerst", dann
# meinte --cuda-device 1 in ComfyUI auf manchen Rechnern eine andere Karte als GPU 1 in NVAI-open.
# Wird vom Server an ComfyUI und die 3D-Worker vererbt.
os.environ.setdefault("CUDA_DEVICE_ORDER", "PCI_BUS_ID")


def _nvidia() -> list[dict[str, Any]]:
    exe = shutil.which("nvidia-smi")
    if not exe:
        return []
    try:
        out = subprocess.run(
            [exe, "--query-gpu=index,name,memory.total,compute_cap", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=8, check=True,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        ).stdout.strip()
    except (subprocess.SubprocessError, OSError):
        return []
    cards = []
    for line in out.splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 3 or not parts[0].isdigit() or not parts[2].isdigit():
            continue
        try:
            # 12.0 = RTX 50 (Blackwell), 8.9 = RTX 40, 8.6 = RTX 30, 7.5 = RTX 20
            compute_cap = float(parts[3])
        except (IndexError, ValueError):
            compute_cap = None
        total_mb = int(parts[2])
        cards.append({"index": int(parts[0]), "vendor": "nvidia", "name": parts[1],
                      "vram_total_mb": total_mb, "vram_total_gb": round(total_mb / 1024, 1),
                      "compute_cap": compute_cap})
    pcie = _nvidia_pcie(exe)
    for card in cards:
        card.update(pcie.get(card["index"], {"pcie_gen": None, "pcie_width": None, "pcie_gbps": None}))
    return cards


# Nutzbare PCIe-Bandbreite je Lane in GB/s nach Generation
_PCIE_LANE_GBPS = {1: 0.25, 2: 0.5, 3: 0.985, 4: 1.969, 5: 3.938, 6: 7.563}


def _nvidia_pcie(exe: str) -> dict[int, dict[str, Any]]:
    """Anschluss je Karte: hoechste moegliche Generation (die aktuelle faellt im Leerlauf auf 1) und
    ausgehandelte Breite. Eigener Aufruf, weil aeltere Treiber die Felder womoeglich nicht kennen --
    dann bleibt die Kartenerkennung trotzdem intakt. Gemessen 25.10.: Die RTX 4060 am Riser meldet
    Gen 3 x4 (3,9 GB/s), die RTX 5060 Ti Gen 4 x8 (15,8 GB/s)."""
    try:
        out = subprocess.run(
            [exe, "--query-gpu=index,pcie.link.gen.max,pcie.link.width.current",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=8, check=True,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        ).stdout.strip()
    except (subprocess.SubprocessError, OSError):
        return {}
    info: dict[int, dict[str, Any]] = {}
    for line in out.splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 3 or not all(p.isdigit() for p in parts[:3]):
            continue
        gen, width = int(parts[1]), int(parts[2])
        gbps = _PCIE_LANE_GBPS.get(gen)
        info[int(parts[0])] = {"pcie_gen": gen, "pcie_width": width,
                               "pcie_gbps": round(gbps * width, 1) if gbps else None}
    return info


# AMD-Architektur (gfx-Ziel) aus dem Kartennamen; die Treiberdaten in der Registry nennen sie nicht. Danach richten
# sich die Empfehlung (RDNA4 rechnet FP8 in Hardware, RDNA3 nicht) und die ROCm-Kernel, die install-runtime.ps1
# laedt (dieselbe Tabelle steht dort). Quelle: ComfyUIs README (AMD unter Windows, ROCm 10) und AMDs
# Zieltabelle (github.com/ROCm/TheRock, RELEASES.md). Reihenfolge zaehlt: das erste Muster gewinnt.
AMD_TARGETS: list[tuple[str, str]] = [
    (r"RX\s*9070|R9700|AI\s*PRO\s*R9", "gfx1201"),
    (r"RX\s*9060", "gfx1200"),
    (r"RX\s*7900|W7900|W7800", "gfx1100"),
    (r"RX\s*7800|RX\s*7700|W7700", "gfx1101"),
    (r"RX\s*76[05]0|W7600|W7500", "gfx1102"),
    (r"8060S|8050S|8040S|AI\s*Max", "gfx1151"),
    (r"890M|880M", "gfx1150"),
    (r"780M|760M|740M", "gfx1103"),
    (r"RX\s*69[05]0|RX\s*6800", "gfx1030"),
    (r"RX\s*67[05]0", "gfx1031"),
    (r"RX\s*66[05]0|RX\s*6600", "gfx1032"),
]


def amd_arch(name: str) -> str | None:
    """gfx-Ziel einer Radeon nach ihrem Namen, etwa "gfx1201" fuer die RX 9070 XT; None = unbekannt."""
    import re
    for pattern, target in AMD_TARGETS:
        if re.search(pattern, name or "", re.IGNORECASE):
            return target
    return None


def rdna(arch: str | None) -> int | None:
    """RDNA-Generation eines gfx-Ziels: gfx12xx = 4, gfx11xx = 3, gfx103x = 2."""
    if not arch:
        return None
    if arch.startswith("gfx12"):
        return 4
    if arch.startswith("gfx11"):
        return 3
    if arch.startswith("gfx103"):
        return 2
    return None


def _amd_windows() -> list[dict[str, Any]]:
    """Radeon-Karten aus der Klasse "Display" der Geraeteverwaltung.

    Die Reihenfolge entspricht der, in der ROCm die Karten zaehlt, nur wenn keine
    anderen Grafikkarten dazwischenliegen; integrierte Radeon-Grafik (APU) zaehlt mit.
    Fuer die Zuordnung reicht das -- mehrere AMD-Karten sind ohnehin ungetestet.
    """
    if sys.platform != "win32":
        return []
    import winreg

    base = r"SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
    cards = []
    try:
        root = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, base)
    except OSError:
        return []
    with root:
        i = 0
        while True:
            try:
                sub = winreg.EnumKey(root, i)
            except OSError:
                break
            i += 1
            if not sub.isdigit():
                continue
            try:
                with winreg.OpenKey(root, sub) as k:
                    def val(name: str) -> Any:
                        try:
                            return winreg.QueryValueEx(k, name)[0]
                        except OSError:
                            return None
                    provider = str(val("ProviderName") or "")
                    desc = str(val("DriverDesc") or "")
                    mem = val("HardwareInformation.qwMemorySize")
                    driver = str(val("DriverVersion") or "")
            except OSError:
                continue
            if "Advanced Micro Devices" not in provider and "AMD" not in provider and "Radeon" not in desc:
                continue
            if isinstance(mem, bytes):
                mem = int.from_bytes(mem[:8], "little")
            total_mb = int(mem) // (1024 * 1024) if isinstance(mem, int) and mem > 0 else 0
            cards.append({"index": len(cards), "vendor": "amd", "name": desc or "AMD Radeon",
                          "vram_total_mb": total_mb, "vram_total_gb": round(total_mb / 1024, 1),
                          "compute_cap": None, "driver": driver or None, "arch": amd_arch(desc)})
    # Ryzen 7000/9000 haben eine kleine Radeon im Prozessor ("AMD Radeon(TM) Graphics", RDNA2). Steckt daneben eine
    # eigene Karte, zählt nur sie: ComfyUI soll dort rechnen, und comfy-kitchen schaltet seine schnellen Kernel ab,
    # sobald eine RDNA2-Karte sichtbar ist. Eine APU allein (etwa Ryzen AI Max) bleibt.
    discrete = [c for c in cards if _is_discrete(c["name"])]
    if discrete and len(discrete) < len(cards):
        cards = [{**c, "index": i} for i, c in enumerate(discrete)]
    return cards


def _is_discrete(name: str) -> bool:
    import re
    return bool(re.search(r"\bRX\b|\bPRO\s*W|AI\s*PRO|R9700", name or "", re.IGNORECASE))


# HIP-Geräte, wie ROCm sie zählt (nicht unbedingt die Reihenfolge der Registry): einmal im ComfyUI-venv abgefragt
# und mit Treiber und torch-Fassung in DATA_DIR/hip_devices.json gemerkt.
HIP_PROBE = (
    "import json, torch\n"
    "out = {'torch': torch.__version__, 'hip': torch.version.hip, 'devices': []}\n"
    "if torch.version.hip and torch.cuda.is_available():\n"
    "    for i in range(torch.cuda.device_count()):\n"
    "        p = torch.cuda.get_device_properties(i)\n"
    "        out['devices'].append({'index': i, 'name': p.name, 'arch': p.gcnArchName.split(':')[0],\n"
    "                               'total_mb': p.total_memory // (1024 * 1024)})\n"
    "print(json.dumps(out))\n"
)
_hip_cache: dict[str, Any] | None = None


def hip_devices(python: str | None = None) -> dict[str, Any] | None:
    """{"torch", "hip", "devices": [{index, name, arch, total_mb}]} aus dem ComfyUI-venv, oder None (kein ROCm,
    kein venv, Abfrage fehlgeschlagen). Der Import von torch mit ROCm dauert einige Sekunden; das Ergebnis gilt,
    solange Treiber und Karten gleich bleiben."""
    global _hip_cache
    if vendor() != "amd" or os.getenv("NVAI_SIMULATE_AMD"):
        return None
    if _hip_cache is not None:
        return _hip_cache
    stamp = ";".join(f"{c['name']}|{c.get('driver')}" for c in _amd_windows())
    path = config.DATA_DIR / "hip_devices.json"
    try:
        saved = json.loads(path.read_text(encoding="utf-8"))
        if saved.get("stamp") == stamp and saved.get("devices"):
            _hip_cache = saved
            return saved
    except (OSError, ValueError):
        pass
    if python is None:
        from .comfy import comfy_python
        python = str(comfy_python())
    if not Path(python).exists():
        return None
    try:
        out = subprocess.run([python, "-c", HIP_PROBE], capture_output=True, text=True, timeout=120,
                             creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0)).stdout
        result = json.loads(out.strip().splitlines()[-1])
    except (subprocess.SubprocessError, OSError, ValueError, IndexError):
        return None
    result["stamp"] = stamp
    try:
        path.write_text(json.dumps(result, indent=1), encoding="utf-8")
    except OSError:
        pass
    _hip_cache = result
    return result


def hip_main_device() -> int | None:
    """Die HIP-Nummer der Karte mit dem meisten Speicher (die eigene Radeon vor der integrierten), oder None."""
    info = hip_devices()
    devices = (info or {}).get("devices") or []
    if not devices:
        return None
    return max(devices, key=lambda d: d.get("total_mb") or 0)["index"]


def list_gpus(force: bool = False) -> list[dict[str, Any]]:
    """Alle nutzbaren Karten. NVIDIA hat Vorrang: steckt eine NVIDIA-Karte im Rechner,
    rechnet NVAI-open mit CUDA, und eine zusaetzliche Radeon (etwa die integrierte Grafik)
    spielt keine Rolle."""
    global _cache, _cached_at
    if not force and _cache is not None and time.time() - _cached_at < _TTL:
        return _cache
    cards = _simulated_amd() or _nvidia() or _amd_windows()
    sim = _simulated()
    if sim and cards:
        # Testschalter: die erste Karte mehrfach melden, damit sich die Mehrkarten-Pfade
        # (Zuordnung, zweites ComfyUI, Anzeige) mit einer Karte pruefen lassen.
        cards = [{**cards[0], "index": i, "name": f"{cards[0]['name']} (sim {i})"} for i in range(sim)]
    _cache, _cached_at = cards, time.time()
    return cards


def _simulated_amd() -> list[dict[str, Any]]:
    """Testschalter NVAI_SIMULATE_AMD="AMD Radeon RX 9070 XT:16": meldet statt der echten Karte eine Radeon
    mit diesem Namen und Speicher in GB. Nur fuer Empfehlungen, Hinweise und Anzeige; ComfyUI rechnet weiter auf
    der echten Karte."""
    spec = os.getenv("NVAI_SIMULATE_AMD", "").strip()
    if not spec:
        return []
    name, _, gb = spec.rpartition(":")
    try:
        total_mb = int(float(gb) * 1024)
    except ValueError:
        name, total_mb = spec, 16 * 1024
    name = name or "AMD Radeon"
    return [{"index": 0, "vendor": "amd", "name": name, "vram_total_mb": total_mb,
             "vram_total_gb": round(total_mb / 1024, 1), "compute_cap": None, "driver": "simulated",
             "arch": amd_arch(name)}]


def _simulated() -> int:
    try:
        n = int(os.getenv("NVAI_SIMULATE_GPUS", "0"))
    except ValueError:
        return 0
    return n if n > 1 else 0


def device_for(role: str) -> int:
    """Die echte Karte fuer eine Aufgabe -- mit NVAI_SIMULATE_GPUS immer Karte 0."""
    return 0 if _simulated() else assignment()[role]


def usage() -> dict[int, int]:
    """Belegter Videospeicher je Karte in MB (nur NVIDIA; AMD meldet das unter Windows
    nicht ohne Weiteres). Ohne Zwischenspeicher -- das aendert sich staendig."""
    exe = shutil.which("nvidia-smi")
    if not exe:
        return {}
    try:
        out = subprocess.run(
            [exe, "--query-gpu=index,memory.used", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=5, check=True,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        ).stdout
    except (subprocess.SubprocessError, OSError):
        return {}
    used = {}
    for line in out.splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
            used[int(parts[0])] = int(parts[1])
    return used


def vendor() -> str | None:
    """"nvidia", "amd" oder None (keine Karte erkannt)."""
    cards = list_gpus()
    return cards[0]["vendor"] if cards else None


# ----------------------------------------------------------- Zuordnung

def strength(card: dict[str, Any]) -> tuple[float, float]:
    """Womit eine Karte rechnet: zuerst der Grafikspeicher (er entscheidet, ob ein Modell ohne
    Nachladen passt), bei Gleichstand die Architektur (12.0 = RTX 50 mit FP4-Einheiten fuer
    NVFP4-Modelle, 8.9 = RTX 40)."""
    return (float(card.get("vram_total_mb") or 0), float(card.get("compute_cap") or 0))


def card_vram_gb(index: int) -> float | None:
    """Grafikspeicher einer Karte in GB, None wenn sie unbekannt ist."""
    card = next((c for c in list_gpus() if c["index"] == index), None)
    return card["vram_total_gb"] if card and card.get("vram_total_gb") else None


def strongest() -> int:
    """Index der staerksten Karte, 0 ohne erkannte Karte."""
    cards = list_gpus()
    return max(cards, key=strength)["index"] if cards else 0


def recommended() -> dict[str, int]:
    """Automatische Verteilung: alles auf die staerkste Karte (meister Grafikspeicher, dann
    neueste Architektur).

    Gemessen mit RTX 5060 Ti 16 GB und RTX 4060 8 GB am Riser-Kabel (PCIe 3.0 x4), 23.10.2026:
    FLUX 3 auf der 4060 29 statt 9 s, Qwen-Image-2512 1095 statt 97 s. Text-Encoder auf die 4060:
    kein Gewinn, ComfyUI laedt Gewichte ohnehin dynamisch nach. Upsampler auf der 4060: int8 passt
    nicht (134-203 s je Prompt), w4a8 allein 7,5-8,6 s, FLUX 3 mit neuem Prompt dann aber 35-41
    statt 31-34 s. Volllast auf beiden Karten zugleich liess die 4060 einmal vom Bus fallen
    (nvlddmkm 153 "BusReset TDR"; Ollama lief dort mit beiden Karten unter Volllast stabil).
    Eine zweite Karte bleibt deshalb eine bewusste Wahl, Messwerte in Issue #1 auf GitHub.
    """
    best = strongest()
    return {role: best for role in ROLES}


def _stored() -> dict[str, Any]:
    try:
        data = json.loads(ASSIGNMENT_FILE.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def is_auto() -> bool:
    """Automatik an: keine eigene Einstellung gespeichert oder ausdruecklich zurueckgesetzt.
    Eine Datei ohne "auto" stammt von 0.5.0 bis 0.5.5 und ist eine eigene Wahl."""
    data = _stored()
    return not data or bool(data.get("auto"))


def assignment() -> dict[str, int]:
    """Welche Karte welche Arbeit macht: image (Bild-, Video- und Audiomodelle), text
    (Prompt-Upsampler, "Prompt ausbauen"), mesh (3D-Worker). Ohne eigene Einstellung die
    staerkste Karte fuer alles (bis 0.5.5: Karte 0, auch wenn das die schwaechere war)."""
    if is_auto():
        return recommended()
    data = _stored()
    count = len(list_gpus())
    best = strongest()
    out = {}
    for role in ROLES:
        v = data.get(role, best)
        out[role] = v if isinstance(v, int) and 0 <= v < max(count, 1) else best
    return out


def set_assignment(values: dict[str, Any]) -> dict[str, int]:
    """Eigene Verteilung speichern; {"auto": true} schaltet zur Automatik zurueck."""
    if values.get("auto") is True:
        config.ensure_dirs()
        ASSIGNMENT_FILE.write_text(json.dumps({"auto": True}, indent=2), encoding="utf-8")
        return assignment()
    count = len(list_gpus(force=True))
    for role, v in values.items():
        if role == "auto":
            continue
        if role not in ROLES:
            raise ValueError(t(f"Unbekannte Aufgabe: {role} (erlaubt: image, text, mesh)",
                               f"Unknown task: {role} (allowed: image, text, mesh)"))
        if not isinstance(v, int) or not 0 <= v < max(count, 1):
            raise ValueError(t(f"Keine Grafikkarte {v} (gefunden: {count})",
                               f"No graphics card {v} (found: {count})"))
    current = assignment()
    current.update({k: v for k, v in values.items() if k != "auto"})
    config.ensure_dirs()
    ASSIGNMENT_FILE.write_text(json.dumps({**current, "auto": False}, indent=2), encoding="utf-8")
    return current


def multi_gpu() -> bool:
    """Mehr als eine Karte im Einsatz -- erst dann bekommen ComfyUI und die Worker
    eine feste Karte, sonst bleibt alles wie in 0.4."""
    return len(list_gpus()) > 1


def separate_text_backend() -> bool:
    """Eigenes ComfyUI fuer die Sprachmodelle? Ja, wenn sie auf einer anderen Karte
    liegen als die Bildmodelle. NVAI_TEXT_BACKEND=separate erzwingt es auch mit einer
    Karte -- nur zum Testen der Aufteilung."""
    if os.getenv("NVAI_TEXT_BACKEND", "").lower() == "separate":
        return True
    a = assignment()
    return multi_gpu() and a["text"] != a["image"]


# ----------------------------------------------------- bisherige Schnittstelle

def detect(force: bool = False) -> dict[str, Any] | None:
    """Die Karte fuer die Bildmodelle (Name, Gesamtspeicher), oder None.

    None heisst: keine GPU gefunden. Das ist kein Fehler -- der Server laeuft dann
    trotzdem, kann aber keine Empfehlung zur Modellgroesse geben.
    """
    cards = list_gpus(force)
    if not cards:
        return None
    idx = assignment()["image"] if len(cards) > 1 else 0
    return next((c for c in cards if c["index"] == idx), cards[0])


def vram_gb() -> float | None:
    """Nutzbarer Videospeicher in GB, oder None wenn keine Karte erkannt wurde."""
    info = detect()
    return info["vram_total_gb"] if info and info["vram_total_gb"] else None


def budget_gb() -> float | None:
    """Wieviel VRAM einem Modell realistisch zur Verfuegung steht.

    Windows haelt sich selbst einen Teil des Speichers frei (Desktop, Browser),
    und ComfyUI braucht Luft fuer Aktivierungen. Aus Messungen auf der 16-GB-Karte:
    rund 1,5 GB gehen ab, bevor ein Modell ueberhaupt geladen wird.
    """
    total = vram_gb()
    return None if total is None else round(total - 1.5, 1)


def fits(need_gb: float) -> str:
    """Passt ein Modell mit diesem VRAM-Bedarf auf die erkannte Karte?

    "ja"       laeuft mit Reserve
    "knapp"    laeuft, aber ohne Puffer -- vorher VRAM leeren
    "nein"     Modell wird bei jedem Schritt nachgeladen; gemessen 25.10. an PCIe 4.0 x8 kaum langsamer
               (Krea 2 INT8 mit 8 GB 13,0 statt 12,2 s mit 16 GB), am langsamen Anschluss deutlich
    "unklar"   keine GPU erkannt
    """
    budget = budget_gb()
    if budget is None:
        return "unklar"
    if need_gb <= budget - 2:
        return "ja"
    if need_gb <= budget:
        return "knapp"
    return "nein"
