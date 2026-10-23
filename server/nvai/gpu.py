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
# meinte --cuda-device 1 in ComfyUI auf manchen Rechnern eine andere Karte als GPU 1 in NV-AI.
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
    return cards


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
                          "compute_cap": None, "driver": driver or None})
    return cards


def list_gpus(force: bool = False) -> list[dict[str, Any]]:
    """Alle nutzbaren Karten. NVIDIA hat Vorrang: steckt eine NVIDIA-Karte im Rechner,
    rechnet NV-AI mit CUDA, und eine zusaetzliche Radeon (etwa die integrierte Grafik)
    spielt keine Rolle."""
    global _cache, _cached_at
    if not force and _cache is not None and time.time() - _cached_at < _TTL:
        return _cache
    cards = _nvidia() or _amd_windows()
    sim = _simulated()
    if sim and cards:
        # Testschalter: die erste Karte mehrfach melden, damit sich die Mehrkarten-Pfade
        # (Zuordnung, zweites ComfyUI, Anzeige) mit einer Karte pruefen lassen.
        cards = [{**cards[0], "index": i, "name": f"{cards[0]['name']} (sim {i})"} for i in range(sim)]
    _cache, _cached_at = cards, time.time()
    return cards


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
    "nein"     Modell muss staendig nachgeladen werden, wird sehr langsam
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
