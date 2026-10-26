"""Fehlerbericht fuer GitHub: Systemangaben, letzte Auftraege und Logauszuege, anonymisiert.

Der Bericht ist reiner Text, damit der Nutzer vor dem Hochladen sieht, was drinsteht. Nicht
enthalten: Prompts, Bilder, Dateinamen von Uploads. Ersetzt werden Benutzer- und Rechnername,
Benutzerordner, Daten- und Programmordner, E-Mail-Adressen, IP-Adressen (ausser localhost),
MAC-Adressen, Hugging-Face-Token, der API-Token und lange Hex-Ketten.
"""
from __future__ import annotations

import getpass
import os
import platform
import re
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from . import __version__, comfy, config, db, gpu, registry

ISSUES_URL = "https://github.com/Mantux775/NVAI-open/issues/new"

# Logs im Datenordner und wie viele Zeilen vom Ende jeweils mitgehen.
LOGS = [
    ("nvai-server.log", 300),
    ("comfyui.log", 200),
    ("comfyui-text.log", 100),
    ("triposg.log", 80),
    ("trellis2.log", 80),
    ("install.log", 120),
]

# PowerShell-Transkript (install.log): Kopfzeilen mit Benutzer, Rechner und Prozess fliegen ganz raus.
_TRANSCRIPT_HEADER = re.compile(
    r"^\s*(Benutzername|RunAs-Benutzer|Username|RunAs User|Computer|Machine|Hostanwendung|Host Application|"
    r"Prozess-ID|Process ID|Konfigurationsname|Configuration Name)\s*:", re.IGNORECASE)


def _identities() -> list[tuple[str, str, bool]]:
    """(Text, Ersatz, nur als ganzes Wort) -- laengste zuerst, damit C:\\Users\\name vor name
    ersetzt wird. Namen nur als ganzes Wort: ein Benutzer "max" soll "maximal" nicht zerlegen."""
    pairs: list[tuple[str, str, bool]] = []
    home = str(Path.home())
    for value, label in ((str(config.DATA_DIR), "<DATA>"), (str(config.ROOT), "<APP>"),
                         (str(config.MODELS_DIR), "<MODELS>"), (home, "<HOME>")):
        if value and len(value) > 3:
            pairs += [(value, label, False), (value.replace("\\", "/"), label, False)]
    names = {getpass.getuser(), os.getenv("USERNAME", ""), os.getenv("USER", "")}
    hosts = {socket.gethostname(), os.getenv("COMPUTERNAME", ""), os.getenv("USERDOMAIN", "")}
    pairs += [(n, "<USER>", True) for n in names if len(n) >= 2]
    pairs += [(h, "<PC>", True) for h in hosts if len(h) >= 2]
    secrets = [registry.hf_token() or "", config.API_TOKEN or ""]
    pairs += [(s, "<TOKEN>", False) for s in secrets if len(s) >= 8]
    return sorted(set(pairs), key=lambda p: -len(p[0]))


_PATTERNS = [
    (re.compile(r"hf_[A-Za-z0-9]{20,}"), "<HF-TOKEN>"),
    (re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"), "<EMAIL>"),
    (re.compile(r"\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b"), "<MAC>"),
    (re.compile(r"\b(?!127\.0\.0\.1\b)(?!0\.0\.0\.0\b)(?:\d{1,3}\.){3}\d{1,3}\b"), "<IP>"),
    (re.compile(r"\b[0-9a-fA-F]{32,}\b"), "<HEX>"),
    # Benutzerordner, die nicht der eigene sind (etwa aus fremden Pfaden in Tracebacks)
    (re.compile(r"([A-Za-z]:[\\/]+Users[\\/]+)[^\\/\s\"']+", re.IGNORECASE), r"\1<USER>"),
    (re.compile(r"(/Users/|/home/)[^/\s\"']+"), r"\1<USER>"),
]


def anonymize(text: str) -> str:
    for value, label, whole_word in _identities():
        pattern = re.escape(value)
        if whole_word:
            pattern = rf"(?<![A-Za-z0-9]){pattern}(?![A-Za-z0-9])"
        text = re.sub(pattern, label, text, flags=re.IGNORECASE)
    for pattern, label in _PATTERNS:
        if label == "<IP>":
            # "SerializationVersion: 1.1.0.1" ist keine Adresse
            text = pattern.sub(lambda m: m.group(0) if "version" in text[max(0, m.start() - 24):m.start()].lower()
                               else label, text)
        else:
            text = pattern.sub(label, text)
    return text


def _tail(path: Path, lines: int) -> list[str]:
    if not path.exists():
        return []
    content = path.read_text(encoding="utf-8", errors="replace").splitlines()
    # ANSI-Farben aus ComfyUI-Logs entfernen, sonst sind sie auf GitHub unlesbar
    return [re.sub(r"\x1b\[[0-9;]*m", "", line) for line in content[-lines:]
            if not _TRANSCRIPT_HEADER.match(line)]


def _driver() -> str:
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=driver_version", "--format=csv,noheader"],
                             capture_output=True, text=True, timeout=8,
                             creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        if out.returncode == 0 and out.stdout.strip():
            return "NVIDIA " + out.stdout.strip().splitlines()[0]
    except (OSError, subprocess.SubprocessError):
        pass
    cards = [c for c in gpu.list_gpus() if c.get("driver")]
    return f"AMD {cards[0]['driver']}" if cards else "?"


def _torch_version() -> str:
    """PyTorch im ComfyUI-venv laut dist-info, ohne Import: zeigt die CUDA- oder ROCm-Fassung (2.14.1+cu130,
    2.13.0+rocm…). Steht sonst nur am Anfang von comfyui.log, der nach vielen Aufträgen aus dem Bericht fällt."""
    venv = config.COMFY_ROOT / ".venv"
    for site in [venv / "Lib" / "site-packages", *venv.glob("lib/python*/site-packages")]:
        found = sorted(site.glob("torch-*.dist-info"))
        if found:
            return found[-1].name[len("torch-"):-len(".dist-info")]
    return "?"


def _ram_gb() -> str:
    try:
        if sys.platform == "win32":
            import ctypes

            class MemStatus(ctypes.Structure):
                _fields_ = [("dwLength", ctypes.c_ulong), ("dwMemoryLoad", ctypes.c_ulong),
                            ("ullTotalPhys", ctypes.c_ulonglong), ("ullAvailPhys", ctypes.c_ulonglong),
                            ("ullTotalPageFile", ctypes.c_ulonglong), ("ullAvailPageFile", ctypes.c_ulonglong),
                            ("ullTotalVirtual", ctypes.c_ulonglong), ("ullAvailVirtual", ctypes.c_ulonglong),
                            ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]
            m = MemStatus()
            m.dwLength = ctypes.sizeof(MemStatus)
            ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(m))
            return f"{m.ullTotalPhys / 1024 ** 3:.0f} GB"
    except Exception:  # noqa: BLE001 - nur eine Angabe im Bericht
        pass
    return "?"


def _fmt_time(ts: float | None) -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(ts)) if ts else "-"


def build(description: str) -> dict[str, Any]:
    """Bericht als Text plus Kurzangaben fuer den Issue-Text."""
    now = time.time()
    local = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now))
    utc = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
    offset = time.strftime("%z", time.localtime(now))
    gpus = gpu.list_gpus()
    gpu_text = "; ".join(f"GPU {g['index']}: {g['name']} ({g.get('vram_total_gb', '?')} GB"
                         + (f", {g['arch']}" if g.get("arch") else "") + ")" for g in gpus) or "none found"
    torch_version = _torch_version()
    jobs = db.list_jobs(limit=25)
    last_error = next((j.error for j in jobs if j.status == "error" and j.error), None)

    out: list[str] = [
        "NVAI-open problem report",
        "========================",
        f"Created:      {local} (UTC{offset[:3]}:{offset[3:]}) / {utc}",
        "",
        "Description",
        "-----------",
        description.strip() or "(none)",
        "",
        "System",
        "------",
        f"NVAI-open:    {__version__} ({'setup' if 'Programs' in str(config.ROOT) else 'source'})",
        f"ComfyUI:      {comfy.installed_version() or '?'}",
        f"OS:           {platform.platform()}",
        f"Python:       {platform.python_version()}",
        f"RAM:          {_ram_gb()}",
        f"Graphics:     {gpu_text}",
        f"Vendor:       {gpu.vendor() or '?'}",
        f"Driver:       {_driver()}",
        f"PyTorch:      {torch_version}",
    ]
    if len(gpus) > 1:
        out.append(f"Assignment:   {gpu.assignment()} (separate text backend: {gpu.separate_text_backend()})")
    active = registry.get_active_models()
    installed = sorted(e["id"] for e in registry.all_entries() if registry.is_installed(e))
    out += [
        f"Active:       {', '.join(f'{k}={v}' for k, v in active.items() if v) or '-'}",
        f"Installed:    {', '.join(installed) or '-'}",
        "",
        "Recent jobs (newest first, without prompts)",
        "-------------------------------------------",
    ]
    for j in jobs:
        took = f"{(j.finished_at - j.started_at):.0f} s" if j.finished_at and j.started_at else "-"
        model = j.params.get("model_id") or "-"
        size = f"{j.params.get('width')}x{j.params.get('height')}" if j.params.get("width") else ""
        line = f"{_fmt_time(j.created_at)}  {j.kind:<14} {j.status:<9} {took:>6}  {model} {size}".rstrip()
        out.append(line)
        if j.error:
            out.append("    error: " + j.error.strip().replace("\n", "\n    "))
    if not jobs:
        out.append("(none)")
    for name, lines in LOGS:
        tail = _tail(config.DATA_DIR / name, lines)
        if not tail:
            continue
        out += ["", f"{name} (last {len(tail)} lines)", "-" * (len(name) + 20), *tail]
    text = anonymize("\n".join(out)) + "\n"
    stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime(now))
    return {
        "filename": f"nvai-report-{stamp}.txt",
        "text": text,
        "created_at": now,
        "summary": {
            "version": __version__,
            "os": platform.platform(),
            "graphics": anonymize(gpu_text),
            "driver": _driver(),
            "torch": torch_version,
            "last_error": anonymize(last_error.strip())[:600] if last_error else None,
            "time": f"{local} (UTC{offset[:3]}:{offset[3:]})",
        },
        "issues_url": ISSUES_URL,
    }
