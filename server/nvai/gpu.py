"""GPU-Erkennung ohne laufendes Backend.

ComfyUI meldet VRAM erst, wenn es laeuft. Fuer die Modellauswahl braucht der
Server die Zahl aber schon vorher -- sonst kann er nicht sagen, welches Modell
auf diese Karte passt. nvidia-smi liegt auf jedem NVIDIA-System im Systempfad
und antwortet in Millisekunden.
"""
from __future__ import annotations

import shutil
import subprocess
import time
from typing import Any

# Ergebnis kurz halten: die Karte wechselt nicht waehrend der Laufzeit, aber ein
# Prozessaufruf pro Health-Abfrage waere trotzdem Verschwendung.
_cache: dict[str, Any] | None = None
_cached_at = 0.0
_TTL = 300.0


def detect(force: bool = False) -> dict[str, Any] | None:
    """Name und Gesamtspeicher der ersten NVIDIA-Karte, oder None.

    None heisst: keine NVIDIA-GPU gefunden. Das ist kein Fehler -- der Server
    laeuft dann trotzdem, kann aber keine Empfehlung zur Modellgroesse geben.
    """
    global _cache, _cached_at
    if not force and _cache is not None and time.time() - _cached_at < _TTL:
        return _cache

    exe = shutil.which("nvidia-smi")
    if not exe:
        return None
    try:
        out = subprocess.run(
            [exe, "--query-gpu=name,memory.total,compute_cap", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=8, check=True,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        ).stdout.strip()
    except (subprocess.SubprocessError, OSError):
        return None

    first = out.splitlines()[0] if out else ""
    parts = [p.strip() for p in first.split(",")]
    if len(parts) < 2 or not parts[1].isdigit():
        return None

    total_mb = int(parts[1])
    try:
        # 12.0 = RTX 50 (Blackwell), 8.9 = RTX 40, 8.6 = RTX 30, 7.5 = RTX 20
        compute_cap = float(parts[2])
    except (IndexError, ValueError):
        compute_cap = None
    _cache = {
        "name": parts[0],
        "vram_total_mb": total_mb,
        "vram_total_gb": round(total_mb / 1024, 1),
        "compute_cap": compute_cap,
    }
    _cached_at = time.time()
    return _cache


def vram_gb() -> float | None:
    """Nutzbarer Videospeicher in GB, oder None wenn keine Karte erkannt wurde."""
    info = detect()
    return info["vram_total_gb"] if info else None


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
