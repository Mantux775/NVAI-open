"""VDR-Aufzeichnungen im Bereich „Audio“ (seit 17.11.2026): der Export eines Voyage Data Recorders (Furuno VR-7000,
Ordner „VDR Data files“) wird ein Projekt mit einer Mono-Spur je Eingang (Funk, Mikrofone; 16 kHz), Daten
(Navigation, Alarme, Digital/Analog, AIS: data/*.json), Radar- und ECDIS-Bildern (images/) und den seriellen
Rohdaten, die direkt aus dem Export gelesen werden. Gerechnet wird in vdr.py als eigener Prozess (wie audio_tools.py),
Prüfsummen und Einlesen laufen in der Render-Warteschlange (Prozessor, keine Grafikkarte).

Projekt (project.json) zusätzlich zu den Feldern aus audio_lab.py:
  source      {"kind": "vdr", "path": <angegebener Pfad>, "folder": <Ordner mit den Blöcken>, "name", "layout"}
  time_origin Unix-Zeit (UTC) von t = 0 (Beginn des ersten Blocks)
  vdr         Übersicht (Kanäle, Geräte, Bildquellen, Versionen, Zeiten) und "integrity" (Prüfsummen)
Spuren: id v_<eingang> (v_vhf1, v_mic1 …), kind "original", group "VDR", channel {input, position, category, …},
sr/sample_rate 16000, channels 1, duration, analysis.
"""
from __future__ import annotations

import asyncio
import json
import re
import time
import uuid
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Query
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

from . import audio_lab as al
from . import db, jobs, vdr
from .i18n import lang, t
from .schemas import Job

TOOL = Path(__file__).with_name("vdr.py")
_FRAME = re.compile(r"^radar\d+_\d+/\d+\.(png|jpg|bin)$")
_images_cache: dict[str, tuple[float, dict[str, Any]]] = {}


def _audio_error(e: vdr.VdrError) -> al.AudioError:
    return al.AudioError(t(e.de, e.en))


def _inspect(path: str) -> dict[str, Any]:
    try:
        return vdr.inspect(path)
    except vdr.VdrError as e:
        raise _audio_error(e) from e
    except Exception as e:  # noqa: BLE001 - kaputte Blöcke, fremde Dateien: Meldung statt 500
        raise al.AudioError(t(f"Der VDR-Export lässt sich nicht lesen: {e}",
                              f"The VDR export cannot be read: {e}")) from e


async def inspect(path: str) -> dict[str, Any]:
    path = (path or "").strip().strip('"')
    if not path:
        raise al.AudioError(t("Den Ordner des VDR-Exports angeben.", "Give the folder of the VDR export."))
    return await asyncio.to_thread(_inspect, path)


async def create_project(path: str, name: str = "") -> dict[str, Any]:
    """Projekt aus einem VDR-Export anlegen und das Einlesen (audio_vdr_import) einreihen."""
    path = (path or "").strip().strip('"')
    info = await inspect(path)
    pid = f"aud_{uuid.uuid4().hex[:8]}"
    folder = al.ROOT / pid
    for sub in ("tracks", "peaks", "proxy", "work", "exports", "data", "images"):
        (folder / sub).mkdir(parents=True, exist_ok=True)
    p = {"id": pid, "name": (name.strip() or f"VDR {info['start']} UTC")[:120], "created": time.time(),
         "source": {"kind": "vdr", "path": str(Path(path)), "folder": info["folder"], "name": Path(info["folder"]).name,
                    "layout": info["layout"], "has_video": False},
         "status": "preparing", "tracks": [], "markers": [], "history": [],
         "time_origin": info["start_utc"], "sample_rate": vdr.SR, "channels": 1, "duration": info["duration"],
         "vdr": vdr._small_summary(info)}
    al._save(p)
    job = await jobs.submit("audio_vdr_import", {"project_id": pid})
    return al.update(pid, lambda q: q.update(job_id=job.id))


def _vdr_project(pid: str) -> dict[str, Any]:
    p = al.load(pid)
    if (p.get("source") or {}).get("kind") != "vdr":
        raise al.AudioError(t("Das Projekt ist keine VDR-Aufzeichnung.", "The project is not a VDR recording."))
    return p


async def submit_import(pid: str, track_ids: list[str] | None = None) -> Job:
    """Erneut einlesen (nach Abbruch oder Fehler); vorhandene VDR-Spuren werden ersetzt."""
    p = _vdr_project(pid)
    busy = [j for j in db.list_jobs(limit=200, active=True)
            if j.kind == "audio_vdr_import" and (j.params or {}).get("project_id") == pid]
    if busy:
        return busy[0]
    al.update(pid, lambda q: q.update(status="preparing", error=None))
    job = await jobs.submit("audio_vdr_import", {"project_id": pid, "track_ids": track_ids or []})
    al.update(pid, lambda q: q.update(job_id=job.id))
    return job


def _track_name(tr: dict[str, Any]) -> str:
    extra = tr.get("position") or (tr.get("equipment") if tr.get("equipment") not in ("", tr.get("input")) else "")
    return f"{tr['input']} · {extra}" if extra else tr["input"]


async def _import(job: Job, ctx: jobs.JobContext) -> list[str]:
    pid = job.params["project_id"]
    p = _vdr_project(pid)
    settings = {"path": p["source"]["path"], "out_dir": str(al.ROOT / pid), "lang": lang(),
                "track_ids": job.params.get("track_ids") or []}
    try:
        res = await al._run_tool("import", settings, ctx, 0.0, 1.0, t("VDR einlesen", "reading the VDR"), tool=TOOL)
    except asyncio.CancelledError:
        al.update(pid, lambda q: q.update(status="error", error=t("Einlesen abgebrochen.", "Reading cancelled.")))
        raise
    except Exception as exc:
        al.update(pid, lambda q: q.update(status="error", error=str(exc)[:800]))
        raise

    def fn(q: dict[str, Any]) -> None:
        new = {tr["id"] for tr in res["tracks"]}
        q["tracks"] = [x for x in q["tracks"] if x["id"] not in new]
        longest = float(res["duration"])
        for tr in res["tracks"]:
            x = al._new_track(q, _track_name(tr), "original", tr, None, tr["id"])
            x.update(group="VDR", sr=tr["sample_rate"], sample_rate=tr["sample_rate"], channels=1,
                     duration=tr["duration"], analysis=tr["analysis"], levels=tr["rms_db"],
                     channel={"input": tr["input"], "position": tr["position"], "category": tr["category"],
                              "equipment": tr["equipment"], "vdr_channel": tr["channel"], "file": tr["file"],
                              "side": "L" if tr["side"] == 0 else "R", "delay_ms": tr["delay_ms"]})
            longest = max(longest, float(tr["duration"]))
        # Reihenfolge wie im VDR: Kanal, dann links/rechts
        order = {tr["id"]: k for k, tr in enumerate(res["tracks"])}
        q["tracks"].sort(key=lambda x: (order.get(x["id"], 10_000), x.get("created") or 0))
        q.update(status="ready", error=None, sample_rate=vdr.SR, channels=1, duration=round(longest, 3),
                 time_origin=res["t0_utc"])
        q["vdr"] = {**(q.get("vdr") or {}), **res["summary"], "events": res["events"], "images_count": res["images"],
                    "timings": res["timings"]}
        if res.get("integrity_ok") is not None:
            q["vdr"]["integrity"] = {**(q["vdr"].get("integrity") or {}), "ok": res["integrity_ok"], "time": time.time(),
                                     **_integrity_counts(pid)}
        q["history"].append({"time": time.time(), "op": "vdr_import", "seconds": res.get("seconds"),
                             "tracks": [tr["id"] for tr in res["tracks"]], "blocks": res["blocks"]})
    al.update(pid, fn)
    _images_cache.pop(pid, None)
    return []


def _integrity_counts(pid: str) -> dict[str, Any]:
    """Zählungen der Prüfsummen aus data/vdr.json in derselben Form wie nach „Prüfen“ (für die Anzeige)."""
    path = al.ROOT / pid / "data" / "vdr.json"
    try:
        res = json.loads(path.read_text(encoding="utf-8")).get("integrity") or {}
    except (OSError, ValueError):
        return {}
    cl = res.get("checklist") or {}
    return {"algorithm": cl.get("algorithm"), "listed": cl.get("listed"), "ok_count": cl.get("ok"),
            "bad_count": cl.get("bad_count"), "missing_count": cl.get("missing_count"),
            "checkfile_ok": (res.get("checkfile") or {}).get("ok")}


async def submit_verify(pid: str) -> Job:
    _vdr_project(pid)
    return await jobs.submit("audio_vdr_verify", {"project_id": pid})


async def _verify(job: Job, ctx: jobs.JobContext) -> list[str]:
    pid = job.params["project_id"]
    p = _vdr_project(pid)
    res = await al._run_tool("verify", {"path": p["source"]["path"], "lang": lang()}, ctx, 0.0, 1.0,
                             t("Prüfsummen", "checksums"), tool=TOOL)
    cl = res.get("checklist") or {}
    summary = {"ok": res.get("ok"), "algorithm": cl.get("algorithm"), "listed": cl.get("listed"), "ok_count": cl.get("ok"),
               "bad_count": cl.get("bad_count"), "missing_count": cl.get("missing_count"),
               "checkfile_ok": (res.get("checkfile") or {}).get("ok"), "note": res.get("note"), "time": time.time()}

    def fn(q: dict[str, Any]) -> None:
        q.setdefault("vdr", {})["integrity"] = summary
        q["history"].append({"time": time.time(), "op": "vdr_verify", "ok": res.get("ok"), "seconds": res.get("seconds")})
    al.update(pid, fn)
    path = al.ROOT / pid / "data" / "vdr.json"
    if path.is_file():
        data = json.loads(path.read_text(encoding="utf-8"))
        data["integrity"] = res
        al._write(path, data)
    return []


def _images(pid: str) -> dict[str, Any]:
    path = al.ROOT / pid / "data" / "images.json"
    if not path.is_file():
        raise LookupError(t("Keine Bilder in diesem Projekt.", "No images in this project."))
    mtime = path.stat().st_mtime
    hit = _images_cache.get(pid)
    if hit and hit[0] == mtime:
        return hit[1]
    data = json.loads(path.read_text(encoding="utf-8"))
    _images_cache[pid] = (mtime, data)
    return data


def image_path(pid: str, source: str, index: int) -> Path:
    folder = al._dir(pid)
    frames = (_images(pid).get("frames") or {}).get(source)
    if frames is None:
        raise LookupError(t(f"Unbekannte Bildquelle: {source}", f"Unknown image source: {source}"))
    if not 0 <= index < len(frames):
        raise LookupError(t(f"Kein Bild Nummer {index}", f"No image number {index}"))
    rel = frames[index][1]
    if not _FRAME.match(rel) or not rel.startswith(source + "/"):
        raise LookupError(rel)
    path = folder / "images" / rel
    if not path.is_file():
        raise LookupError(t("Die Bilddatei fehlt.", "The image file is missing."))
    return path


def _raw(pid: str, t_s: float) -> dict[str, Any]:
    p = _vdr_project(pid)
    names = {d["channel"]: d["name"] for d in (p.get("vdr") or {}).get("serial") or []}
    try:
        return vdr.raw_lines(p["source"]["path"], t_s, names)
    except vdr.VdrError as e:
        raise LookupError(t(e.de, e.en)) from e
    except OSError as e:
        raise al.AudioError(t(f"Der VDR-Export ist nicht erreichbar: {e}", f"The VDR export is not reachable: {e}")) from e


jobs.register("audio_vdr_import")(_import)
jobs.register("audio_vdr_verify")(_verify)
jobs.RENDER_KINDS.update({"audio_vdr_import", "audio_vdr_verify"})


# ---------------------------------------------------------------------------------------------------- REST

router = APIRouter(prefix="/api/audio")


class VdrPath(BaseModel):
    path: str = Field(..., max_length=1000, description="Ordner des VDR-Exports (oder eine Blockdatei)")


class VdrCreate(BaseModel):
    path: str = Field(..., max_length=1000, description="Ordner des VDR-Exports (oder eine Blockdatei)")
    name: str = Field("", max_length=120)


class VdrImport(BaseModel):
    track_ids: list[str] = Field(default_factory=list, max_length=32, description="nur diese Spuren (leer = alle)")


@router.post("/vdr/inspect")
async def api_vdr_inspect(req: VdrPath) -> dict[str, Any]:
    return await al._ahttp(inspect(req.path))


@router.post("/vdr/projects")
async def api_vdr_create(req: VdrCreate) -> dict[str, Any]:
    return await al._ahttp(create_project(req.path, req.name))


@router.post("/projects/{pid}/vdr/import", response_model=Job)
async def api_vdr_import(pid: str, req: VdrImport | None = None) -> Job:
    return await al._ahttp(submit_import(pid, (req.track_ids if req else None)))


@router.post("/projects/{pid}/vdr/verify", response_model=Job)
async def api_vdr_verify(pid: str) -> Job:
    return await al._ahttp(submit_verify(pid))


@router.get("/projects/{pid}/vdr/image/{source}/{index}")
async def api_vdr_image(pid: str, source: str, index: int) -> FileResponse:
    path = al._http(image_path, pid, source, index)
    media = {".png": "image/png", ".jpg": "image/jpeg"}.get(path.suffix, "application/octet-stream")
    return FileResponse(path, media_type=media, headers={"Cache-Control": "private, max-age=86400"})


@router.get("/projects/{pid}/vdr/raw")
async def api_vdr_raw(pid: str, at: float = Query(0.0, alias="t", description="Sekunden ab Aufnahmebeginn")
                      ) -> dict[str, Any]:
    return await al._ahttp(asyncio.to_thread(_raw, pid, at))
