"""Bereich „Audio“ (seit 17.11.2026; Nutzer: „neuer Bereich Audio, dort soll ich audio von stimme trennen können und
andersrum auch für aufnahmen von mehreren stunden … wie studio … rauschen entfernen, nur gewisse geräusche entfernen
(mit training) und die besten modelle vorschlagen“).

Ein Projekt ist eine Aufnahme (Audio oder Video) mit Spuren: das Original und alles, was daraus entsteht (Stimme, Rest,
entrauscht, gefiltert). Gerechnet wird in audio_tools.py (eigener Prozess in external/audio/.venv, PyTorch aus dem
venv von ComfyUI), in Blöcken und fortsetzbar. Modelle: audio_models/<name>.py mit Manifest <name>.json.

Daten: <Daten>/Audio/<projekt>/ (project.json, tracks/, peaks/, proxy/, work/, exports/), Modelle unter
<Daten>/Audio-Modelle/<name>/.
"""
from __future__ import annotations

import asyncio
import contextlib
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path
from typing import Any

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import FileResponse, Response
from pydantic import BaseModel, Field

from . import comfy, config, db, gpu, jobs, mesh_workers, registry
from .i18n import t
from .schemas import Job

ROOT = config.DATA_DIR / "Audio"
# Testserver: NVAI_AUDIO_MODELS_DIR und NVAI_AUDIO_ENV zeigen auf Modelle und Umgebung der Installation
MODELS_DIR = Path(os.getenv("NVAI_AUDIO_MODELS_DIR") or config.DATA_DIR / "Audio-Modelle")
ENV = Path(os.getenv("NVAI_AUDIO_ENV") or config.ROOT / "external" / "audio" / ".venv")
TOOL = Path(__file__).with_name("audio_tools.py")
ADAPTERS = Path(__file__).with_name("audio_models")
# Pakete der eigenen kleinen Umgebung (ohne PyTorch; das kommt aus dem venv von ComfyUI)
ENV_PACKAGES = ["rotary-embedding-torch==0.9.2", "beartype==0.23.1", "deepfilternet-slim==0.1.0"]
_PID = re.compile(r"^aud_[a-z0-9]{8}$")
_FILE = re.compile(r"^[A-Za-z0-9_\-.]{1,120}$")
_lock = threading.Lock()

# Vorschlag je Aufgabe (beste Wahl mit kommerziell nutzbarer Lizenz, Recherche 17.11.2026)
RECOMMENDED = {"voice": "melroformer_kim", "dialogue": "bandit_v2", "denoise": "mossformer2_se48k",
               "denoise_fast": "deepfilternet3"}
TASK_LABEL = {
    "voice": ("Stimme von Musik trennen", "Separate voice from music"),
    "dialogue": ("Sprache, Musik und Geräusche trennen", "Separate speech, music and effects"),
    "denoise": ("Rauschen aus Sprache entfernen", "Remove noise from speech"),
}
STEM_LABEL = {"voice": ("Stimme", "Voice"), "rest": ("Begleitung", "Accompaniment"), "speech": ("Sprache", "Speech"),
              "music": ("Musik", "Music"), "effects": ("Geräusche", "Effects"), "clean": ("Entrauscht", "Denoised"),
              "removed": ("Entferntes", "Removed")}
# Welche Stems je Aufgabe als Spuren entstehen (der Rest ergibt sich in audio_tools als Mischung minus Ziel)
TASK_STEMS = {"voice": ["voice", "rest"], "dialogue": ["speech", "music", "effects"], "denoise": ["clean", "removed"],
              "learned": ["clean", "removed"]}
LEARNED = {"id": "learned", "label_de": "Gelerntes Geräusch", "label_en": "Learned sound", "task": "learned",
           "stems": ["clean"], "device": "cuda"}
COLORS = ["#76b900", "#7cc4ff", "#ffd166", "#ff8fab", "#b39ddb", "#80cbc4", "#ffab91"]


class AudioError(Exception):
    """Fehler, den der Nutzer beheben kann; die Route macht 400 daraus."""


# ------------------------------------------------------------------------------------------- Umgebung, Modelle

def _site_packages(venv: Path) -> Path:
    return venv / "Lib" / "site-packages" if sys.platform == "win32" else next(
        iter(sorted((venv / "lib").glob("python3*/site-packages"))), venv / "lib" / "site-packages")


def env_python() -> Path:
    return ENV / ("Scripts/python.exe" if sys.platform == "win32" else "bin/python")


def env_ready() -> bool:
    return env_python().exists() and all((_site_packages(ENV) / p).exists()
                                         for p in ("rotary_embedding_torch", "deepfilternet_slim"))


def _python() -> Path:
    """Die Audio-Umgebung, solange sie fehlt ComfyUIs Python (reicht für Einlesen, Filter und Export)."""
    return env_python() if env_python().exists() else comfy.comfy_python()


def _tool_env() -> dict[str, str]:
    env = {**os.environ, "PYTHONUTF8": "1", "PYTHONIOENCODING": "utf-8", "PYTHONUNBUFFERED": "1",
           "NVAI_AUDIO_TORCH_SITE": str(_site_packages(config.COMFY_ROOT / ".venv"))}
    for key in ("PYTHONPATH", "PYTHONHOME", "VIRTUAL_ENV"):
        env.pop(key, None)
    return env


def manifests() -> list[dict[str, Any]]:
    out = []
    for f in sorted(ADAPTERS.glob("*.json")):
        with contextlib.suppress(OSError, ValueError):
            m = json.loads(f.read_text(encoding="utf-8"))
            if (ADAPTERS / f"{m.get('id')}.py").exists():
                out.append(m)
    return out


def manifest(model_id: str) -> dict[str, Any]:
    m = next((x for x in manifests() if x["id"] == model_id), None)
    if m is None:
        raise LookupError(t(f"Unbekanntes Audio-Modell: {model_id}", f"Unknown audio model: {model_id}"))
    return m


def model_installed(m: dict[str, Any]) -> bool:
    folder = MODELS_DIR / m["id"]
    return all((folder / f["path"]).exists() and (not f.get("size") or (folder / f["path"]).stat().st_size == int(f["size"]))
               for f in m.get("files") or [])


def models_info() -> list[dict[str, Any]]:
    out = []
    for m in manifests():
        size = sum(int(f.get("size") or 0) for f in m.get("files") or [])
        out.append({**{k: v for k, v in m.items() if k != "files"}, "installed": model_installed(m),
                    "size_mb": round(size / 1024**2), "recommended_for": [k for k, v in RECOMMENDED.items() if v == m["id"]],
                    "label": t(m.get("label_de") or m["id"], m.get("label_en") or m["id"]),
                    "notes": t(m.get("notes_de") or "", m.get("notes_en") or "")})
    return out


def status() -> dict[str, Any]:
    with contextlib.suppress(OSError):
        ROOT.mkdir(parents=True, exist_ok=True)
    return {"root": str(ROOT), "models_dir": str(MODELS_DIR), "env_ready": env_ready(), "env": str(ENV),
            "nvidia": gpu.vendor() == "nvidia", "free_gb": round(shutil.disk_usage(ROOT).free / 1024**3, 1),
            "models": models_info(), "recommended": RECOMMENDED, "projects": list_projects(),
            "tasks": {k: {"label": t(*v), "stems": TASK_STEMS[k]} for k, v in TASK_LABEL.items()},
            "stem_labels": {k: t(*v) for k, v in STEM_LABEL.items()}}


async def _setup(job: Job, ctx: jobs.JobContext) -> list[str]:
    """Umgebung anlegen (uv, ohne PyTorch) und/oder Modelle laden (aus den Manifesten, Prüfsumme)."""
    p = job.params
    if p.get("env", True) and not env_ready():
        uv = config.ROOT / "tools" / ("uv.exe" if sys.platform == "win32" else "uv")
        uv_exe = str(uv) if uv.exists() else shutil.which("uv")
        if not uv_exe:
            raise AudioError(t("uv fehlt (gehört zur Installation, Ordner tools).", "uv is missing (folder tools)."))
        ctx.progress(0.02, t("richte die Audio-Umgebung ein …", "setting up the audio environment …"))
        env = {**os.environ, "UV_LINK_MODE": "copy"}
        pydir = config.ROOT / "python"
        if pydir.is_dir():
            env["UV_PYTHON_INSTALL_DIR"] = str(pydir)
        for cmd in ([uv_exe, "venv", "--python", "3.12", str(ENV)],
                    [uv_exe, "pip", "install", "--python", str(env_python()), "--no-deps", *ENV_PACKAGES]):
            if cmd[1] == "venv" and env_python().exists():
                continue
            proc = await asyncio.create_subprocess_exec(*cmd, env=env, stdout=asyncio.subprocess.PIPE,
                                                        stderr=asyncio.subprocess.STDOUT,
                                                        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            out, _ = await proc.communicate()
            if proc.returncode != 0:
                raise RuntimeError(t(f"Einrichten gescheitert: {out.decode(errors='replace')[-800:]}",
                                     f"Setup failed: {out.decode(errors='replace')[-800:]}"))
    ids = [x for x in p.get("models") or [] if x]
    for n, mid in enumerate(ids):
        m = manifest(mid)
        files = m.get("files") or []
        for k, f in enumerate(files):
            dest = MODELS_DIR / mid / f["path"]
            if dest.exists() and (not f.get("size") or dest.stat().st_size == int(f["size"])):
                continue
            base = 0.1 + 0.9 * (n + k / max(1, len(files))) / len(ids)
            span = 0.9 / len(ids) / max(1, len(files))
            await asyncio.to_thread(registry._download_url, f["url"], dest, m.get("label_en") or mid, base, span,
                                    ctx.progress, ctx.should_stop)
            if f.get("sha256"):
                digest = await asyncio.to_thread(_sha256, dest)
                if digest != f["sha256"]:
                    dest.unlink(missing_ok=True)
                    raise RuntimeError(t(f"Prüfsumme stimmt nicht: {dest.name}", f"Checksum mismatch: {dest.name}"))
        jobs.publish({"type": "audio.changed"})
    return []


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1 << 22), b""):
            h.update(block)
    return h.hexdigest()


def delete_model(model_id: str) -> None:
    m = manifest(model_id)
    shutil.rmtree(MODELS_DIR / m["id"], ignore_errors=True)
    jobs.publish({"type": "audio.changed"})


# ------------------------------------------------------------------------------------------------ Projekte

def _dir(pid: str) -> Path:
    if not _PID.match(pid or "") or not (ROOT / pid / "project.json").exists():
        raise LookupError(t(f"Unbekanntes Audio-Projekt: {pid}", f"Unknown audio project: {pid}"))
    return ROOT / pid


def _write(path: Path, data: dict[str, Any]) -> None:
    tmp = path.with_suffix(f".{uuid.uuid4().hex[:6]}.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(tmp, path)


def load(pid: str) -> dict[str, Any]:
    return json.loads((_dir(pid) / "project.json").read_text(encoding="utf-8"))


def _save(p: dict[str, Any]) -> dict[str, Any]:
    p["updated"] = time.time()
    _write(ROOT / p["id"] / "project.json", p)
    jobs.publish({"type": "audio.changed", "project_id": p["id"]})
    return p


def update(pid: str, fn: Any) -> dict[str, Any]:
    """Projekt unter Sperre ändern: fn(projekt) ändert es an Ort und Stelle."""
    with _lock:
        p = load(pid)
        fn(p)
        return _save(p)


def list_projects() -> list[dict[str, Any]]:
    out = []
    if ROOT.exists():
        for f in ROOT.glob("aud_*/project.json"):
            with contextlib.suppress(OSError, ValueError, KeyError):
                p = json.loads(f.read_text(encoding="utf-8"))
                out.append({"id": p["id"], "name": p["name"], "duration": p.get("duration"), "status": p.get("status"),
                            "tracks": len(p.get("tracks") or []), "updated": p.get("updated"),
                            "has_video": (p.get("source") or {}).get("has_video", False),
                            "source_kind": (p.get("source") or {}).get("kind") or "file"})
    return sorted(out, key=lambda x: -(x.get("updated") or 0))


def _source_path(source: dict[str, Any]) -> Path:
    if source.get("asset_id"):
        asset = db.get_asset(source["asset_id"])
        path = db.asset_file(asset.filename) if asset else None
        if path is None or not path.exists():
            raise AudioError(t("Die Datei des Projekts fehlt im Verlauf.", "The project's file is missing in the history."))
        return path
    path = Path(source.get("path") or "")
    if not path.is_file():
        raise AudioError(t(f"Datei nicht gefunden: {path}", f"File not found: {path}"))
    return path


async def create_project(asset_id: str | None, path: str | None, name: str = "") -> dict[str, Any]:
    if not asset_id and not path:
        raise AudioError(t("Eine Datei angeben (aus dem Verlauf, hochgeladen oder als Pfad).",
                           "Give a file (from the history, uploaded or as a path)."))
    source: dict[str, Any] = {"asset_id": asset_id} if asset_id else {"path": str(Path(path.strip().strip('"')))}
    src = _source_path(source)
    pid = f"aud_{uuid.uuid4().hex[:8]}"
    folder = ROOT / pid
    for sub in ("tracks", "peaks", "proxy", "work", "exports"):
        (folder / sub).mkdir(parents=True, exist_ok=True)
    source["name"] = (db.get_asset(asset_id).meta or {}).get("original_name") if asset_id and db.get_asset(asset_id) else src.name
    source["name"] = source["name"] or src.name
    p = {"id": pid, "name": (name or Path(source["name"]).stem)[:120], "created": time.time(), "source": source,
         "status": "preparing", "tracks": [], "markers": [], "history": []}
    _save(p)
    job = await jobs.submit("audio_prepare", {"project_id": pid})
    return update(pid, lambda q: q.update(job_id=job.id))


def delete_project(pid: str) -> dict[str, Any]:
    """In den Papierkorb, nicht endgültig (Nutzer 17.11.2026: „ich soll die fälle auch löschen können“). Der Fallordner
    wird nur umbenannt (sofort, kein Kopieren); die Quelle liegt nie darin, Exporte im Verlauf bleiben."""
    folder = _dir(pid)
    busy = [j for j in db.list_jobs(limit=200, active=True) if (j.params or {}).get("project_id") == pid]
    if busy:
        raise AudioError(t("In diesem Fall läuft gerade ein Auftrag; erst abbrechen oder abwarten.",
                           "A job is running in this case; cancel it or wait first."))
    TRASH.mkdir(parents=True, exist_ok=True)
    entry = f"{pid}--{time.strftime('%Y%m%d-%H%M%S')}"
    with _lock:
        _move_dir(folder, TRASH / entry)
        with contextlib.suppress(OSError, ValueError):
            path = TRASH / entry / "project.json"
            p = json.loads(path.read_text(encoding="utf-8"))
            p.setdefault("history", []).append({"time": time.time(), "op": "trash",
                                                "label": t("In den Papierkorb gelegt", "Moved to the trash")})
            _write(path, p)
    _forget(pid)
    jobs.publish({"type": "audio.changed"})
    return {"ok": True, "trash": entry}


# ------------------------------------------------------------------------------------------------ Papierkorb

TRASH = ROOT / "_papierkorb"
_TRASH_ENTRY = re.compile(r"^(aud_[a-z0-9]{8})--(\d{8}-\d{6})$")


def _move_dir(src: Path, dst: Path) -> None:
    """Ordner umbenennen; unter Windows halten offene Dateien (Wiedergabe, Spektrogramm-Abruf) ihn kurz fest."""
    for k in range(12):
        try:
            os.replace(src, dst)
            return
        except PermissionError:
            if k == 11:
                raise AudioError(t("Dateien des Falls sind noch geöffnet (Wiedergabe oder Abruf). Gleich noch einmal versuchen.",
                                   "Files of the case are still open (playback or loading). Try again in a moment.")) from None
            time.sleep(0.5)


def _forget(pid: str) -> None:
    with contextlib.suppress(Exception):
        from . import audio_vdr
        audio_vdr._images_cache.pop(pid, None)


def _folder_size(path: Path) -> int:
    total = 0
    for root, _dirs, files in os.walk(path):
        for f in files:
            with contextlib.suppress(OSError):
                total += os.stat(os.path.join(root, f)).st_size
    return total


def _trash_dir(entry: str) -> tuple[Path, str]:
    m = _TRASH_ENTRY.match(entry or "")
    if not m or not (TRASH / entry).is_dir():
        raise LookupError(t("Nicht im Papierkorb.", "Not in the trash."))
    return TRASH / entry, m.group(1)


def list_trash() -> list[dict[str, Any]]:
    out = []
    if TRASH.exists():
        for d in TRASH.iterdir():
            m = _TRASH_ENTRY.match(d.name)
            if not m or not d.is_dir():
                continue
            p: dict[str, Any] = {}
            with contextlib.suppress(OSError, ValueError):
                p = json.loads((d / "project.json").read_text(encoding="utf-8"))
            out.append({"entry": d.name, "id": m.group(1), "name": p.get("name") or m.group(1),
                        "deleted": time.mktime(time.strptime(m.group(2), "%Y%m%d-%H%M%S")),
                        "duration": p.get("duration"), "tracks": len(p.get("tracks") or []),
                        "kind": (p.get("source") or {}).get("kind") or "file", "size": _folder_size(d),
                        "exists": (ROOT / m.group(1)).exists()})
    return sorted(out, key=lambda x: -x["deleted"])


def restore_trash(entry: str) -> dict[str, Any]:
    src, pid = _trash_dir(entry)
    if (ROOT / pid).exists():
        raise AudioError(t("Ein Fall mit dieser Kennung ist schon da.", "A case with this id already exists."))
    with _lock:
        _move_dir(src, ROOT / pid)
    update(pid, lambda q: q.setdefault("history", []).append(
        {"time": time.time(), "op": "restore", "label": t("Aus dem Papierkorb wiederhergestellt", "Restored from the trash")}))
    return {"ok": True, "id": pid}


def _rmtree(path: Path) -> None:
    def retry(func: Any, p: str, _exc: Any) -> None:
        with contextlib.suppress(OSError):
            os.chmod(p, 0o600)
            func(p)
    if sys.version_info >= (3, 12):
        shutil.rmtree(path, onexc=retry)
    else:
        shutil.rmtree(path, onerror=retry)
    if path.exists():
        raise AudioError(t("Nicht alles ließ sich löschen (Dateien noch geöffnet?). Gleich noch einmal versuchen.",
                           "Not everything could be deleted (files still open?). Try again in a moment."))


def purge_trash(entry: str | None = None) -> dict[str, Any]:
    """Endgültig löschen: ein Eintrag oder (entry=None) der ganze Papierkorb. Gibt den Platz frei."""
    if entry is None:
        dirs = [d for d in TRASH.iterdir() if _TRASH_ENTRY.match(d.name) and d.is_dir()] if TRASH.exists() else []
    else:
        dirs = [_trash_dir(entry)[0]]
    freed = 0
    for d in dirs:
        size = _folder_size(d)
        _rmtree(d)
        freed += size
    return {"ok": True, "count": len(dirs), "freed": freed}


def _track_paths(pid: str, tid: str) -> dict[str, str]:
    folder = ROOT / pid
    return {"flac": str(folder / "tracks" / f"{tid}.flac"), "peaks": str(folder / "peaks" / f"{tid}.peaks"),
            "proxy": str(folder / "proxy" / f"{tid}.webm")}


def _track(p: dict[str, Any], tid: str) -> dict[str, Any]:
    tr = next((x for x in p["tracks"] if x["id"] == tid), None)
    if tr is None and tid == "t_orig":
        # Vorgabe „t_orig“ in Projekten ohne diese Spur (VDR: v_vhf1, v_mic1 …): die erste Originalspur
        tr = next((x for x in p["tracks"] if x.get("kind") == "original"), None)
    if tr is None:
        raise LookupError(t(f"Unbekannte Spur: {tid}", f"Unknown track: {tid}"))
    return tr


def _track_sr(p: dict[str, Any], tr: dict[str, Any]) -> int:
    """Abtastrate einer Spur (Projekte mit gemischten Raten, etwa VDR 16 kHz neben Video 48 kHz)."""
    return int(tr.get("sr") or p["sample_rate"])


def _new_track(p: dict[str, Any], name: str, kind: str, info: dict[str, Any], op: dict[str, Any] | None,
               tid: str, offset: float = 0.0) -> dict[str, Any]:
    tr = {"id": tid, "name": name, "kind": kind, "frames": info.get("frames"), "bars": info.get("bars"),
          "peak": info.get("peak"), "offset": offset, "gain_db": 0.0, "mute": False, "solo": False,
          "color": COLORS[len(p["tracks"]) % len(COLORS)], "op": op, "created": time.time(),
          "sr": info.get("sample_rate") or p.get("sample_rate")}
    p["tracks"].append(tr)
    return tr


def update_track(pid: str, tid: str, fields: dict[str, Any]) -> dict[str, Any]:
    def fn(p: dict[str, Any]) -> None:
        tr = _track(p, tid)
        for k in ("name", "gain_db", "mute", "solo", "color"):
            if fields.get(k) is not None:
                tr[k] = fields[k] if k != "name" else str(fields[k])[:80]
    return update(pid, fn)


def delete_track(pid: str, tid: str) -> dict[str, Any]:
    def fn(p: dict[str, Any]) -> None:
        tr = _track(p, tid)
        if tr["kind"] == "original":
            raise AudioError(t("Das Original bleibt.", "The original stays."))
        p["tracks"] = [x for x in p["tracks"] if x["id"] != tid]
        for key, path in _track_paths(pid, tid).items():
            Path(path).unlink(missing_ok=True)
    return update(pid, fn)


def set_markers(pid: str, markers: list[dict[str, Any]]) -> dict[str, Any]:
    """Marken: Beispiele für „Gezielt entfernen“ (noise/keep) und Notizen der Ton-Forensik (note, Text bis 4000
    Zeichen, Verfasser und Zeitpunkt der Notiz)."""
    clean = []
    for m in markers[:5000]:
        start, end = float(m.get("start") or 0), float(m.get("end") or 0)
        if end < start:
            start, end = end, start
        kind = m.get("kind") if m.get("kind") in ("noise", "keep", "note") else "note"
        clean.append({"id": str(m.get("id") or uuid.uuid4().hex[:8])[:16], "start": round(start, 3),
                      "end": round(end, 3), "kind": kind, "label": str(m.get("label") or "")[:4000 if kind == "note" else 80],
                      "author": str(m.get("author") or "")[:60], "created": float(m.get("created") or time.time())})
    return update(pid, lambda p: p.update(markers=clean))


# ------------------------------------------------------------------------------------------------ Werkzeug

async def _run_tool(cmd: str, settings: dict[str, Any], ctx: jobs.JobContext | None, base: float = 0.0,
                    span: float = 1.0, stage: str = "", info: dict[str, Any] | None = None,
                    tool: Path | None = None) -> dict[str, Any]:
    """audio_tools.py (oder ein anderes Werkzeug-Skript mit derselben Befehlszeile, tool=…) als eigener Prozess;
    Fortschritt aus JSON-Zeilen, Abbrechen beendet ihn (KI-Schritte setzen beim nächsten Start dort fort)."""
    work = ROOT / "_settings"
    work.mkdir(parents=True, exist_ok=True)
    path = work / f"{cmd}_{uuid.uuid4().hex[:8]}.json"
    path.write_text(json.dumps(settings), encoding="utf-8")
    proc = await asyncio.create_subprocess_exec(
        str(_python()), "-I", str(tool or TOOL), cmd, str(path), env=_tool_env(), stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    err_task = asyncio.create_task(proc.stderr.read()) if proc.stderr else None
    result: dict[str, Any] = {}
    error = ""
    try:
        assert proc.stdout is not None
        async for raw in proc.stdout:
            line = raw.decode(errors="replace").strip()
            if not line.startswith("{"):
                continue
            with contextlib.suppress(ValueError):
                msg = json.loads(line)
                if "progress" in msg and ctx is not None:
                    ctx.progress(base + span * float(msg["progress"]), f"{stage}: {msg.get('stage') or ''}".strip(": "))
                if "info" in msg and info is not None:
                    info.update(msg["info"])
                if "result" in msg:
                    result = msg["result"]
                if "error" in msg:
                    error = str(msg["error"])
            if ctx is not None and ctx.should_stop():
                proc.kill()
                raise asyncio.CancelledError
        err = (await err_task).decode(errors="replace") if err_task else ""
        if await proc.wait() != 0 or not result:
            raise RuntimeError(error or t(f"Audio-Werkzeug ({cmd}) gescheitert: {err[-700:]}",
                                          f"Audio tool ({cmd}) failed: {err[-700:]}"))
    finally:
        if proc.returncode is None:
            proc.kill()
        path.unlink(missing_ok=True)
    return result


# ------------------------------------------------------------------------------------------------- Aufträge

async def _prepare(job: Job, ctx: jobs.JobContext) -> list[str]:
    pid = job.params["project_id"]
    p = load(pid)
    src = _source_path(p["source"])
    tid = "t_orig"
    try:
        res = await _run_tool("prepare", {"src": str(src), **_track_paths(pid, tid)}, ctx, 0, 1,
                              t("einlesen", "reading"))
    except Exception as exc:
        update(pid, lambda q: q.update(status="error", error=str(exc)[:800]))
        raise

    def fn(q: dict[str, Any]) -> None:
        q.update(status="ready", error=None, sample_rate=res["sample_rate"], channels=res["channels"],
                 duration=res["duration"], analysis=res["analysis"])
        q["source"].update({"has_video": bool(res["probe"].get("has_video")), "video": res["probe"].get("video"),
                            "codec": res["probe"].get("codec"), "container": res["probe"].get("container"),
                            "source_rate": res["probe"].get("sample_rate"), "source_channels": res["probe"].get("channels")})
        q["tracks"] = [x for x in q["tracks"] if x["id"] != tid]
        _new_track(q, t("Original", "Original"), "original", res, None, tid)
        q["history"].append({"time": time.time(), "op": "prepare", "seconds": res.get("seconds")})
    update(pid, fn)
    # Beweiskette (Ton-Forensik): Prüfsumme der unveränderten Quelle festhalten
    with contextlib.suppress(Exception):
        await jobs.submit("audio_hash", {"project_id": pid})
    return []


def _region_frames(p: dict[str, Any], region: list[float] | None, sr: int | None = None) -> list[int] | None:
    if not region:
        return None
    sr = int(sr or p["sample_rate"])
    a, b = sorted(float(x) for x in region[:2])
    a, b = max(0.0, a), min(float(p.get("duration") or b), b)
    if b - a < 0.5:
        raise AudioError(t("Die Auswahl ist kürzer als eine halbe Sekunde.", "The selection is shorter than half a second."))
    return [int(a * sr), int((b - a) * sr)]


def _op_key(op: dict[str, Any]) -> str:
    return hashlib.sha1(json.dumps(op, sort_keys=True).encode()).hexdigest()[:12]


async def submit_op(pid: str, op: dict[str, Any]) -> Job:
    """Bearbeitung einer Spur: klassisch (Filterkette) oder KI (Modell). Mit region nur ein Ausschnitt (Vorschau)."""
    p = load(pid)
    if p.get("status") != "ready":
        raise AudioError(t("Das Projekt ist noch nicht eingelesen.", "The project has not been read yet."))
    src = _track(p, op.get("track") or "t_orig")
    kind = op.get("kind")
    if kind == "classic":
        chain = [s for s in op.get("chain") or [] if isinstance(s, dict) and s.get("type")]
        if not chain:
            raise AudioError(t("Mindestens einen Filter wählen.", "Choose at least one filter."))
        job_kind = "audio_dsp"
    elif kind == "learned":
        prof = next((x for x in p.get("profiles") or [] if x["id"] == op.get("profile")), None)
        if prof is None:
            raise AudioError(t("Unbekanntes gelerntes Geräusch.", "Unknown learned sound."))
        if not env_ready():
            raise AudioError(t("Erst die Audio-Umgebung einrichten.", "Set up the audio environment first."))
        op = {**op, "model": "learned", "task": "learned",
              "params": {**(op.get("params") or {}), "profile": str(ROOT / pid / prof["file"]), "profile_name": prof["name"]}}
        job_kind = "audio_ai"
    elif kind == "ai":
        m = manifest(op.get("model") or "")
        if not model_installed(m):
            raise AudioError(t(f"„{m.get('label_de')}“ ist noch nicht geladen.", f"“{m.get('label_en')}” is not downloaded yet."))
        if not env_ready():
            raise AudioError(t("Erst die Audio-Umgebung einrichten.", "Set up the audio environment first."))
        job_kind = "audio_ai"
    else:
        raise AudioError(t("Unbekannte Bearbeitung.", "Unknown operation."))
    if src.get("offset"):
        raise AudioError(t("Eine Vorschau-Spur lässt sich nicht weiter bearbeiten; die ganze Spur nehmen.",
                           "A preview track cannot be processed further; use a full track."))
    region = _region_frames(p, op.get("region"), _track_sr(p, src))
    spec = {"kind": "ai" if kind == "learned" else kind, "track": src["id"], "chain": op.get("chain"), "model": op.get("model"),
            "params": op.get("params") or {}, "region": region, "task": op.get("task")}
    # request: die Anfrage, wie sie kam; „Fortsetzen“ schickt sie erneut, der Arbeitsordner (gleicher Schlüssel) trägt
    return await jobs.submit(job_kind, {"project_id": pid, "op": spec, "name": (op.get("name") or "")[:80],
                                        "request": {k: op.get(k) for k in ("kind", "track", "chain", "model", "task",
                                                                           "params", "region", "name", "profile")}})


async def _free_gpu(ctx: jobs.JobContext) -> None:
    ctx.progress(0.0, t("gibt den Grafikspeicher frei", "freeing graphics memory"))
    with contextlib.suppress(Exception):
        if await comfy.is_running():
            await comfy.free_memory()
            comfy.set_loaded_model(None)
    for w in mesh_workers.all_workers():
        with contextlib.suppress(Exception):
            if await w.is_running():
                await w.unload()


def _op_label(spec: dict[str, Any], m: dict[str, Any] | None) -> str:
    if spec["kind"] == "classic":
        names = {"hum": t("Brummen", "hum"), "highpass": t("Trittschall", "rumble"), "lowpass": t("Tiefpass", "low-pass"),
                 "denoise": t("Rauschen klassisch", "classic denoise"), "declick": t("Knackser", "clicks"),
                 "level": t("Pegel angleichen", "levelling"), "deess": t("Zischlaute", "de-ess"),
                 "loudness": t("Lautheit", "loudness"), "linewhistle": t("Zeilenpfeifen", "line whistle")}
        return ", ".join(names.get(s["type"], s["type"]) for s in spec.get("chain") or [])
    return t(m.get("label_de") or spec["model"], m.get("label_en") or spec["model"]) if m else spec["model"]


async def _op(job: Job, ctx: jobs.JobContext) -> list[str]:
    pid = job.params["project_id"]
    spec = job.params["op"]
    p = load(pid)
    src = _track(p, spec["track"])
    paths_in = _track_paths(pid, src["id"])
    work = ROOT / pid / "work" / _op_key(spec)
    sr = _track_sr(p, src)
    offset = (spec["region"][0] / sr) if spec.get("region") else 0.0
    preview = bool(spec.get("region"))
    base_name = (job.params.get("name") or "").strip()
    m = (LEARNED if spec["model"] == "learned" else manifest(spec["model"])) if spec["kind"] == "ai" else None
    label = _op_label(spec, m)
    info: dict[str, Any] = {}
    t0 = time.time()
    if spec["kind"] == "classic":
        tid = f"t_{uuid.uuid4().hex[:8]}"
        chain = list(spec["chain"])
        for st in chain:
            if st.get("type") == "hum" and not st.get("freq"):
                st["freq"] = ((p.get("analysis") or {}).get("hum") or {}).get("freq") or 50
        settings: dict[str, Any] = {"src": paths_in["flac"], "chain": chain, **_track_paths(pid, tid)}
        if spec.get("region"):
            settings["region"] = spec["region"]
        res = await _run_tool("process", settings, ctx, 0, 1, t("bearbeiten", "processing"))
        outs = {"main": (tid, res)}
        names = {"main": base_name or f"{src['name']} · {label}"}
    else:
        if (m.get("device") or "cuda") == "cuda":
            await _free_gpu(ctx)
        stems = list(m.get("stems") or [])
        task = spec.get("task") or m.get("task")
        want = list(dict.fromkeys(stems + [x for x in TASK_STEMS.get(task, []) if x not in stems]))
        ids = {st: f"t_{uuid.uuid4().hex[:8]}" for st in want}
        settings = {"src": paths_in["flac"], "model": m["id"], "weights_dir": str(MODELS_DIR / m["id"]),
                    "work_dir": str(work), "device": m.get("device") or "cuda", "params": spec.get("params") or {},
                    "outputs": {st: _track_paths(pid, tid) for st, tid in ids.items()}}
        if spec.get("region"):
            settings["region"] = spec["region"]
        res = await _run_tool("ai", settings, ctx, 0.02, 0.98, label, info)
        outs = {st: (ids[st], res["stems"][st]) for st in want}
        if m["id"] == "learned":
            sound = (spec.get("params") or {}).get("profile_name") or "?"
            names = {"clean": t(f"ohne „{sound}“", f"without “{sound}”"), "removed": t(f"nur „{sound}“", f"only “{sound}”")}
        else:
            names = {st: (f"{base_name} · " if base_name else "") + t(STEM_LABEL.get(st, (st, st))[0], STEM_LABEL.get(st, (st, st))[1])
                     + ("" if base_name else f" ({label})") for st in want}
    seconds = round(time.time() - t0, 1)

    def fn(q: dict[str, Any]) -> None:
        for key, (tid, r) in outs.items():
            _new_track(q, names[key] + (t(" · Vorschau", " · preview") if preview else ""),
                       "preview" if preview else ("stem" if spec["kind"] == "ai" else "processed"), r,
                       {**spec, "stem": key, "label": label, "seconds": seconds, **({"vram_gb": info.get("vram_gb")} if info else {})},
                       tid, offset)
        q["history"].append({"time": time.time(), "op": spec["kind"], "label": label, "seconds": seconds,
                             "track": spec["track"], "region": spec.get("region"), "tracks": [v[0] for v in outs.values()]})
    update(pid, fn)
    shutil.rmtree(work, ignore_errors=True)
    return []


async def submit_learn(pid: str, name: str, track: str, steps: int) -> Job:
    """Ein Geräusch aus den Marken „Störgeräusch“ lernen (saubere Stellen: Marken „behalten“, sonst zufällig)."""
    p = load(pid)
    if p.get("status") != "ready":
        raise AudioError(t("Das Projekt ist noch nicht eingelesen.", "The project has not been read yet."))
    if not env_ready():
        raise AudioError(t("Erst die Audio-Umgebung einrichten.", "Set up the audio environment first."))
    src = _track(p, track or "t_orig")
    if src.get("offset"):
        raise AudioError(t("Bitte eine ganze Spur wählen.", "Please choose a full track."))
    sr = _track_sr(p, src)
    noise = [m for m in p.get("markers") or [] if m["kind"] == "noise" and m["end"] - m["start"] >= 0.1]
    if len(noise) < 2:
        raise AudioError(t("Mindestens zwei Marken „Störgeräusch“ setzen (je ein Beispiel, gut sind 4 bis 10).",
                           "Set at least two “unwanted sound” markers (one example each, 4 to 10 work well)."))
    keep = [m for m in p.get("markers") or [] if m["kind"] == "keep" and m["end"] - m["start"] >= 1]
    return await jobs.submit("audio_learn", {
        "project_id": pid, "name": (name or "").strip()[:60] or t("Störgeräusch", "Unwanted sound"), "track": src["id"],
        "steps": max(500, min(int(steps or 3000), 20000)),
        "noise": [[int(m["start"] * sr), int((m["end"] - m["start"]) * sr)] for m in noise],
        "keep": [[int(m["start"] * sr), int((m["end"] - m["start"]) * sr)] for m in keep]})


async def _learn(job: Job, ctx: jobs.JobContext) -> list[str]:
    pid = job.params["project_id"]
    await _free_gpu(ctx)
    prof_id = f"g_{uuid.uuid4().hex[:8]}"
    rel = f"profiles/{prof_id}.pt"
    res = await _run_tool("learn", {"src": _track_paths(pid, job.params["track"])["flac"], "noise": job.params["noise"],
                                    "keep": job.params["keep"], "steps": job.params["steps"], "out": str(ROOT / pid / rel)},
                          ctx, 0.02, 0.98, t("lernen", "learning"))

    def fn(q: dict[str, Any]) -> None:
        q.setdefault("profiles", []).append({"id": prof_id, "name": job.params["name"], "file": rel, "created": time.time(),
                                             "metrics": res["metrics"], "track": job.params["track"]})
        q["history"].append({"time": time.time(), "op": "learn", "label": job.params["name"],
                             "seconds": res["metrics"].get("train_seconds")})
    update(pid, fn)
    return []


async def submit_scan(pid: str, track: str) -> Job:
    p = load(pid)
    if p.get("status") != "ready":
        raise AudioError(t("Das Projekt ist noch nicht eingelesen.", "The project has not been read yet."))
    src = _track(p, track or "t_orig")
    return await jobs.submit("audio_scan", {"project_id": pid, "track": src["id"]})


async def _scan(job: Job, ctx: jobs.JobContext) -> list[str]:
    pid = job.params["project_id"]
    res = await _run_tool("scan", {"src": _track_paths(pid, job.params["track"])["flac"]}, ctx, 0, 1,
                          t("Töne suchen", "finding tones"))
    update(pid, lambda q: q.update(scan={**res, "track": job.params["track"], "time": time.time()}))
    return []


def delete_profile(pid: str, prof_id: str) -> dict[str, Any]:
    def fn(p: dict[str, Any]) -> None:
        prof = next((x for x in p.get("profiles") or [] if x["id"] == prof_id), None)
        if prof is None:
            raise LookupError(prof_id)
        (ROOT / pid / prof["file"]).unlink(missing_ok=True)
        p["profiles"] = [x for x in p["profiles"] if x["id"] != prof_id]
    return update(pid, fn)


def check_dest_dir(dest_dir: str | None) -> str | None:
    """Zielordner eines Exports (Nutzer 18.11.: „ich sollte auch auswählen können wohin ich die audio oder video files
    speichere“): vollständiger, vorhandener, beschreibbarer Ordner auf diesem Rechner. None = in den Verlauf."""
    if not dest_dir or not dest_dir.strip():
        return None
    d = Path(dest_dir.strip().strip('"')).expanduser()
    if not d.is_absolute():
        raise AudioError(t("Der Zielordner muss ein vollständiger Pfad sein.", "The target folder must be a full path."))
    if not d.is_dir():
        raise AudioError(t(f"Ordner nicht gefunden: {d}", f"Folder not found: {d}"))
    probe = d / f".nvai-{uuid.uuid4().hex[:6]}.tmp"
    try:
        probe.write_bytes(b"")
        probe.unlink()
    except OSError as e:
        raise AudioError(t(f"In diesen Ordner lässt sich nicht schreiben: {d}", f"Cannot write to this folder: {d}")) from e
    return str(d)


def export_target(dest_dir: str | None, stem: str, suffix: str) -> tuple[Path, bool]:
    """Wohin ein Export schreibt: in den gewählten Ordner (lesbarer Name, nichts überschreiben, kein zweites Kopieren)
    oder in den Verlauf. Ergebnis: Pfad und ob er ein Asset im Verlauf wird."""
    if dest_dir:
        folder = Path(dest_dir)
        out = folder / f"{stem}{suffix}"
        k = 2
        while out.exists():
            out = folder / f"{stem} ({k}){suffix}"
            k += 1
        return out, False
    return config.ASSET_DIR / f"{db.new_id('aud')}_{stem}{suffix}", True


async def submit_export(pid: str, tracks: list[dict[str, Any]], fmt: str, into_video: bool, name: str = "",
                        mono: bool = False, region: list[float] | None = None, dest_dir: str | None = None) -> Job:
    p = load(pid)
    if p.get("status") != "ready":
        raise AudioError(t("Das Projekt ist noch nicht eingelesen.", "The project has not been read yet."))
    chosen = []
    for tr in tracks:
        x = _track(p, tr["id"])
        if x.get("offset"):
            raise AudioError(t("Vorschau-Spuren lassen sich nicht exportieren.", "Preview tracks cannot be exported."))
        if not tr.get("mute"):
            chosen.append({"id": x["id"], "gain_db": float(tr.get("gain_db") or 0)})
    if not chosen:
        raise AudioError(t("Keine Spur zum Exportieren.", "No track to export."))
    if into_video and not (p.get("source") or {}).get("has_video"):
        raise AudioError(t("Die Quelle ist kein Video.", "The source is not a video."))
    fmt = "mp4" if into_video else (fmt if fmt in ("wav", "flac", "mp3", "opus", "m4a") else "wav")
    if region:
        a, b = sorted(float(x) for x in region[:2])
        region = [max(0.0, a), b] if b - a >= 0.1 else None
    return await jobs.submit("audio_export", {"project_id": pid, "tracks": chosen, "format": fmt,
                                              "into_video": into_video, "name": name[:80], "mono": bool(mono),
                                              "region": None if into_video else region,
                                              "dest_dir": check_dest_dir(dest_dir)})


async def _export(job: Job, ctx: jobs.JobContext) -> list[str]:
    pid = job.params["project_id"]
    p = load(pid)
    fmt = job.params["format"]
    stem = re.sub(r"[^\w\-. ]+", "_", job.params.get("name") or p["name"])[:80].strip() or "export"
    suffix = {"opus": ".ogg"}.get(fmt, f".{fmt}")
    dest, as_asset = export_target(job.params.get("dest_dir"), stem, suffix)
    out_name = dest.name
    settings: dict[str, Any] = {"tracks": [{"file": _track_paths(pid, x["id"])["flac"], "gain_db": x["gain_db"]}
                                           for x in job.params["tracks"]], "format": fmt, "out": str(dest),
                                "mono": bool(job.params.get("mono")), "region": job.params.get("region")}
    if job.params.get("into_video"):
        settings["video_src"] = str(_source_path(p["source"]))
    res = await _run_tool("export", settings, ctx, 0, 1, t("exportieren", "exporting"))
    kind = "video" if job.params.get("into_video") else "audio"
    if not as_asset:
        update(pid, lambda q: q["history"].append({"time": time.time(), "op": "export", "format": fmt, "path": str(dest),
                                                   "file": out_name}))
        return []
    asset = db.create_asset(kind=kind, filename=out_name, job_id=job.id, prompt=p["name"],
                            model_id="audio-lab", meta={"audio_project": pid, "tracks": job.params["tracks"],
                                                        "format": fmt, "size_mb": res.get("size_mb")})
    update(pid, lambda q: q["history"].append({"time": time.time(), "op": "export", "format": fmt, "asset_id": asset.id,
                                               "file": out_name}))
    jobs.publish({"type": "assets.changed"})
    return [asset.id]


def suggestions(p: dict[str, Any]) -> list[dict[str, Any]]:
    """Vorschläge aus den Messwerten der Aufnahme (nur was gemessen ist)."""
    a = p.get("analysis") or {}
    out: list[dict[str, Any]] = []
    hum = a.get("hum") or {}
    if hum.get("present"):
        out.append({"kind": "classic", "chain": [{"type": "hum", "freq": hum["freq"]}],
                    "text": t(f"Netzbrummen bei {hum['freq']} Hz (+{hum['db_over_floor']} dB über dem Umfeld): Brummfilter.",
                              f"Mains hum at {hum['freq']} Hz (+{hum['db_over_floor']} dB above its surroundings): hum filter.")})
    floor = a.get("noise_floor_db")
    if floor is not None and floor > -55:
        out.append({"kind": "ai", "task": "denoise", "model": RECOMMENDED["denoise"],
                    "text": t(f"Rauschboden {floor} dBFS (deutlich hörbar): Rauschen entfernen.",
                              f"Noise floor {floor} dBFS (clearly audible): remove noise.")})
    lufs = a.get("lufs")
    if lufs is not None and (lufs < -24 or lufs > -12):
        out.append({"kind": "classic", "chain": [{"type": "loudness", "target": -16}],
                    "text": t(f"Lautheit {lufs} LUFS: auf −16 LUFS angleichen (Sprache), Musik eher −14.",
                              f"Loudness {lufs} LUFS: normalise to −16 LUFS (speech), music rather −14.")})
    if (a.get("clipped") or 0) > 100:
        out.append({"kind": "info", "text": t(f"{a['clipped']} Proben übersteuert: Die Aufnahme ist an diesen Stellen verzerrt.",
                                              f"{a['clipped']} samples clipped: the recording is distorted there.")})
    return out


def project_view(pid: str) -> dict[str, Any]:
    p = load(pid)
    return {**p, "suggestions": suggestions(p) if p.get("status") == "ready" else []}


def file_path(pid: str, area: str, name: str) -> Path:
    folder = _dir(pid)
    if area not in ("tracks", "peaks", "proxy", "exports", "data") or not _FILE.match(name):
        raise LookupError(name)
    path = folder / area / name
    if not path.is_file():
        raise LookupError(name)
    return path


jobs.register("audio_prepare")(_prepare)
jobs.register("audio_dsp")(_op)
jobs.register("audio_ai")(_op)
jobs.register("audio_export")(_export)
jobs.register("audio_setup")(_setup)
jobs.register("audio_learn")(_learn)
jobs.register("audio_scan")(_scan)
jobs.RENDER_KINDS.update({"audio_prepare", "audio_dsp", "audio_export", "audio_scan"})
jobs.IO_KINDS.add("audio_setup")


# ---------------------------------------------------------------------------------------------------- REST

router = APIRouter(prefix="/api/audio")


# ------------------------------------------------------------------------------------------- Teil-Antworten

_RANGE = re.compile(r"^bytes=(\d*)-(\d*)$")


def capped_file(request: Request, path: Path, media_type: str, cap: int) -> Response:
    """Datei für <audio>/<video> mit Teil-Antworten, je höchstens cap Bytes (auch bei „bytes=X-“). Der Browser hält nur
    6 Verbindungen je Server; mit offenem Ende hielt jede Spur ihre Verbindung, bis sie genug geladen hatte, und Sprünge
    anderer Spuren und sogar /api/health warteten (gemessen 18.11. an 9 Spuren und dem Live-Player-Video)."""
    size = path.stat().st_size
    start, end = 0, size - 1
    m = _RANGE.match((request.headers.get("range") or "").strip())
    if m and (m.group(1) or m.group(2)):
        if m.group(1):
            start = int(m.group(1))
            if m.group(2):
                end = min(end, int(m.group(2)))
        else:  # „bytes=-N“: die letzten N Bytes
            start = max(0, size - int(m.group(2)))
    if start >= size or start > end:
        return Response(status_code=416, headers={"Content-Range": f"bytes */{size}", "Accept-Ranges": "bytes"})
    end = min(end, start + cap - 1)
    with path.open("rb") as fh:
        fh.seek(start)
        data = fh.read(end - start + 1)
    return Response(content=data, status_code=206, media_type=media_type,
                    headers={"Content-Range": f"bytes {start}-{start + len(data) - 1}/{size}", "Accept-Ranges": "bytes",
                             "Cache-Control": "no-cache"})


def _http(fn: Any, *args: Any, **kwargs: Any) -> Any:
    try:
        return fn(*args, **kwargs)
    except LookupError as e:
        raise HTTPException(404, str(e).strip("'\"")) from e
    except (AudioError, ValueError) as e:
        raise HTTPException(400, str(e)) from e


async def _ahttp(coro: Any) -> Any:
    try:
        return await coro
    except LookupError as e:
        raise HTTPException(404, str(e).strip("'\"")) from e
    except (AudioError, ValueError) as e:
        raise HTTPException(400, str(e)) from e


class ProjectCreate(BaseModel):
    asset_id: str | None = None
    path: str | None = Field(None, max_length=1000)
    name: str = Field("", max_length=120)


class ProjectUpdate(BaseModel):
    name: str | None = Field(None, max_length=120)


class TrackUpdate(BaseModel):
    name: str | None = Field(None, max_length=80)
    gain_db: float | None = Field(None, ge=-60, le=24)
    mute: bool | None = None
    solo: bool | None = None
    color: str | None = Field(None, max_length=16)


class Markers(BaseModel):
    markers: list[dict[str, Any]] = Field(default_factory=list, max_length=5000)


class OpRequest(BaseModel):
    kind: str = Field(..., description="classic oder ai")
    track: str = "t_orig"
    chain: list[dict[str, Any]] | None = None
    model: str | None = None
    task: str | None = None
    params: dict[str, Any] | None = None
    region: list[float] | None = Field(None, description="[Anfang, Ende] in Sekunden; nur dieser Ausschnitt")
    name: str = Field("", max_length=80)
    profile: str | None = Field(None, description="bei kind=learned: das gelernte Geräusch")


class ExportRequest(BaseModel):
    tracks: list[dict[str, Any]] = Field(..., max_length=32)
    format: str = "wav"
    into_video: bool = False
    name: str = Field("", max_length=80)
    mono: bool = False
    region: list[float] | None = Field(None, description="[Anfang, Ende] in Sekunden; nur dieser Ausschnitt")
    dest_dir: str | None = Field(None, max_length=500, description="Zielordner auf diesem Rechner; leer = Verlauf")


class LearnRequest(BaseModel):
    name: str = Field("", max_length=60)
    track: str = "t_orig"
    steps: int = Field(3000, ge=500, le=20000)


class SetupRequest(BaseModel):
    env: bool = True
    models: list[str] = Field(default_factory=list, max_length=20)


@router.get("/status")
async def api_status() -> dict[str, Any]:
    return await asyncio.to_thread(status)


@router.post("/setup", response_model=Job)
async def api_setup(req: SetupRequest) -> Job:
    for mid in req.models:
        _http(manifest, mid)
    return await jobs.submit("audio_setup", {"env": req.env, "models": req.models})


@router.delete("/models/{model_id}")
async def api_model_delete(model_id: str) -> dict[str, Any]:
    _http(delete_model, model_id)
    return {"ok": True}


@router.post("/projects")
async def api_create(req: ProjectCreate) -> dict[str, Any]:
    return await _ahttp(create_project(req.asset_id, req.path, req.name))


@router.get("/projects/{pid}")
async def api_project(pid: str) -> dict[str, Any]:
    return _http(project_view, pid)


@router.put("/projects/{pid}")
async def api_project_update(pid: str, req: ProjectUpdate) -> dict[str, Any]:
    return _http(update, pid, lambda p: p.update(name=req.name.strip()[:120]) if req.name else None)


@router.delete("/projects/{pid}")
async def api_project_delete(pid: str) -> dict[str, Any]:
    return await asyncio.to_thread(_http, delete_project, pid)


@router.get("/trash")
async def api_trash() -> list[dict[str, Any]]:
    return await asyncio.to_thread(list_trash)


@router.post("/trash/{entry}/restore")
async def api_trash_restore(entry: str) -> dict[str, Any]:
    return await asyncio.to_thread(_http, restore_trash, entry)


@router.delete("/trash/{entry}")
async def api_trash_purge(entry: str) -> dict[str, Any]:
    return await asyncio.to_thread(_http, purge_trash, entry)


@router.delete("/trash")
async def api_trash_empty() -> dict[str, Any]:
    return await asyncio.to_thread(_http, purge_trash, None)


@router.put("/projects/{pid}/tracks/{tid}")
async def api_track(pid: str, tid: str, req: TrackUpdate) -> dict[str, Any]:
    return _http(update_track, pid, tid, req.model_dump())


@router.delete("/projects/{pid}/tracks/{tid}")
async def api_track_delete(pid: str, tid: str) -> dict[str, Any]:
    return _http(delete_track, pid, tid)


@router.put("/projects/{pid}/markers")
async def api_markers(pid: str, req: Markers) -> dict[str, Any]:
    return _http(set_markers, pid, req.markers)


@router.post("/projects/{pid}/ops", response_model=Job)
async def api_op(pid: str, req: OpRequest) -> Job:
    return await _ahttp(submit_op(pid, req.model_dump()))


@router.post("/projects/{pid}/export", response_model=Job)
async def api_export(pid: str, req: ExportRequest) -> Job:
    return await _ahttp(submit_export(pid, req.tracks, req.format, req.into_video, req.name, req.mono, req.region,
                                      req.dest_dir))


@router.post("/projects/{pid}/reveal/{index}")
async def api_reveal(pid: str, index: int) -> dict[str, Any]:
    """Eine in einen Ordner exportierte Datei im Explorer zeigen. Der Pfad kommt aus dem Protokoll des Falls, nie aus
    der Anfrage."""
    from . import folders
    hist = _http(load, pid).get("history") or []
    if not 0 <= index < len(hist) or not hist[index].get("path"):
        raise HTTPException(404, t("Kein Export mit Pfad.", "No export with a path."))
    path = Path(hist[index]["path"])
    if not path.exists():
        raise HTTPException(404, t(f"Die Datei ist nicht mehr da: {path}", f"The file is gone: {path}"))
    await asyncio.to_thread(folders.reveal, path)
    return {"ok": True}


@router.post("/projects/{pid}/learn", response_model=Job)
async def api_learn(pid: str, req: LearnRequest) -> Job:
    return await _ahttp(submit_learn(pid, req.name, req.track, req.steps))


@router.post("/projects/{pid}/scan", response_model=Job)
async def api_scan(pid: str, track: str = "t_orig") -> Job:
    return await _ahttp(submit_scan(pid, track))


@router.delete("/projects/{pid}/profiles/{prof_id}")
async def api_profile_delete(pid: str, prof_id: str) -> dict[str, Any]:
    return _http(delete_profile, pid, prof_id)


@router.get("/projects/{pid}/files/{area}/{name}")
async def api_file(pid: str, area: str, name: str, request: Request) -> Response:
    path = _http(file_path, pid, area, name)
    media = {".flac": "audio/flac", ".mp3": "audio/mpeg", ".webm": "audio/webm",
             ".peaks": "application/octet-stream", ".json": "application/json"}.get(path.suffix,
                                                                                                    "application/octet-stream")
    if area == "proxy":  # Wiedergabe: begrenzte Teil-Antworten (capped_file)
        return await asyncio.to_thread(capped_file, request, path, media, 1 << 20)
    return FileResponse(path, media_type=media, headers={"Cache-Control": "no-cache"})
