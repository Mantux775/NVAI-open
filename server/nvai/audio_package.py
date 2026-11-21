"""Prüfpaket: einen Fall der Ton-Forensik mit allem, was die Prüf-App braucht, in einen Ordner exportieren (Nutzer
18.11.2026: „option das projekt konsolidiert zu exportieren … eine eigenständige app die komplett standalone funktioniert,
ohne downloads … projekt importieren zum weiterbearbeiten, dann halt ohne KI. aber mit allen übersetzungen“).

Aufbau (gelesen von frontend/src/review/local.ts):
    <Fall> – Prüfpaket/
        NVAI-Pruefer.html        die Prüf-App, eine Datei (frontend/dist), in Edge/Chrome ohne Server und ohne Netz
        LIESMICH.txt             Kurzanleitung (deutsch, englisch)
        PRUEFSUMMEN.sha256       SHA-256 jeder gelieferten Datei („<hash> *<pfad>“, prüfbar mit sha256sum -c)
        fall/manifest.json       Paketformat, Version, Inhalt
        fall/projekt.json        der Fall ohne Pfade dieses Rechners
        fall/transkript.json     Übersetzer-Spur mit allen Übersetzungen, Wörtern, Läufen
        fall/proxy/ peaks/ spec/ Ton zum Abspielen, Wellenform, Spektrogramm-Stufen, Sprachkarten
        fall/data/ images/       Schiffsdaten, Ereignisse, Bildliste, AIS; Radar-/ECDIS-Bilder (wahlweise)
        fall/original/<Spur>.wav Originalton der Spur, bitgenau aus der Arbeitsdatei (wahlweise; für WAV-Exporte)
        fall/video/              das zugeordnete Video (wahlweise)
        bearbeitung/             leer; hier speichert die Prüf-App Änderungen und ihr Protokoll
Plan: notizen/pruef-player.md."""
from __future__ import annotations

import asyncio
import contextlib
import datetime as dt
import hashlib
import json
import re
import shutil
import time
from pathlib import Path
from typing import Any

from fastapi import APIRouter
from pydantic import BaseModel, Field

from . import __version__, config, jobs
from . import audio_lab as al
from .audio_forensic import load_transcript, transcript_credits
from .i18n import t
from .schemas import Job

router = APIRouter(prefix="/api/audio", tags=["audio"])

FORMAT = "nvai-pruefpaket"
VERSION = 1
REVIEW_APP = "NVAI-Pruefer.html"
SPEC_SUFFIXES = (".spec", ".spec1", ".spec2", ".spec3", ".act", ".vad")
CHUNK = 1 << 22


def review_app() -> Path:
    return config.ROOT / "frontend" / "dist" / REVIEW_APP


def _safe(name: str) -> str:
    """Datei- und Ordnername, den Windows annimmt."""
    s = re.sub(r'[<>:"/\\|?*\x00-\x1f]+', "_", name).strip(" .")
    return s[:80] or "Fall"


def _tracks(p: dict[str, Any]) -> list[dict[str, Any]]:
    """Alle Spuren außer Vorschau-Spuren (Ausschnitt mit Versatz)."""
    return [x for x in p.get("tracks") or [] if not float(x.get("offset") or 0)]


def _plan(pid: str, images: bool, video: bool) -> tuple[dict[str, Any], list[tuple[Path, str]], dict[str, str], str | None]:
    """Was ins Paket kommt: (Quelle, Ziel unter fall/), Vorschau je Spur, Name des Videos."""
    p = al.load(pid)
    folder = al._dir(pid)
    items: list[tuple[Path, str]] = []
    proxies: dict[str, str] = {}
    for tr in _tracks(p):
        tid = tr["id"]
        for ext in (".webm", ".mp3"):
            f = folder / "proxy" / f"{tid}{ext}"
            if f.is_file():
                items.append((f, f"proxy/{f.name}"))
                proxies[tid] = f.name
                break
        pk = folder / "peaks" / f"{tid}.peaks"
        if pk.is_file():
            items.append((pk, f"peaks/{pk.name}"))
        for suffix in SPEC_SUFFIXES:
            sp = folder / "spec" / f"{tid}{suffix}"
            if sp.is_file():
                items.append((sp, f"spec/{sp.name}"))
    data = folder / "data"
    if data.is_dir():
        for f in sorted(data.glob("*.json")):
            if f.name != "transcript.json":
                items.append((f, f"data/{f.name}"))
    if images and (folder / "images").is_dir():
        base = folder / "images"
        for f in sorted(base.rglob("*")):
            if f.is_file():
                items.append((f, "images/" + f.relative_to(base).as_posix()))
    vname = None
    vpath = Path((p.get("video") or {}).get("path") or "")
    if video and vpath.is_file():
        vname = _safe(vpath.stem) + vpath.suffix.lower()
        items.append((vpath, f"video/{vname}"))
    return p, items, proxies, vname


def _flac_info(path: Path) -> tuple[int, int] | None:
    """Kanäle und Bittiefe aus dem STREAMINFO-Kopf einer FLAC-Datei (der Server hat kein soundfile)."""
    try:
        with path.open("rb") as f:
            head = f.read(42)
    except OSError:
        return None
    if len(head) < 42 or head[:4] != b"fLaC":
        return None
    x = int.from_bytes(head[18:21], "big")  # 20 Bit Rate, 3 Bit Kanäle − 1, 1 Bit (von 5) Bittiefe − 1
    ch = ((x >> 1) & 7) + 1
    bits = (((x & 1) << 4) | (head[21] >> 4)) + 1
    return ch, bits


def _wav_bytes(p: dict[str, Any], tr: dict[str, Any]) -> int:
    """Größe des Originaltons als WAV aus den Spurdaten; Kanäle und Bittiefe aus der FLAC-Datei (bearbeitete Spuren
    sind 24 Bit, die Kanäle eines Schreibers 16 Bit; vorher mit 16 Bit für alle 15,0 statt 17,3 GB geschätzt)."""
    sr = int(tr.get("sr") or tr.get("sample_rate") or p.get("sample_rate") or 48000)
    frames = tr.get("frames") or float(tr.get("duration") or p.get("duration") or 0) * sr
    info = _flac_info(Path(al._track_paths(p["id"], tr["id"])["flac"]))
    ch, bits = info or (int(tr.get("channels") or p.get("channels") or 1), 16)
    return int(frames * ch * (bits // 8)) + 80


def estimate(pid: str) -> dict[str, Any]:
    """Größen der Teile für den Dialog (Bytes)."""
    p = al.load(pid)
    folder = al._dir(pid)

    def size(path: Path) -> int:
        return sum(f.stat().st_size for f in path.rglob("*") if f.is_file()) if path.is_dir() else 0
    _, items, _, _ = _plan(pid, images=False, video=False)
    base = sum(src.stat().st_size for src, _ in items)
    vpath = Path((p.get("video") or {}).get("path") or "")
    originals = {tr["id"]: _wav_bytes(p, tr) for tr in _tracks(p) if Path(al._track_paths(pid, tr["id"])["flac"]).is_file()}
    return {"base": base, "images": size(folder / "images"), "video": vpath.stat().st_size if vpath.is_file() else 0,
            "video_name": vpath.name if vpath.is_file() else None, "originals": originals,
            "app": review_app().is_file()}


async def submit_package(pid: str, req: dict[str, Any]) -> Job:
    p = al.load(pid)
    if p.get("status") != "ready":
        raise al.AudioError(t("Der Fall ist noch nicht eingelesen.", "The case has not been read yet."))
    dest = al.check_dest_dir(req.get("dest_dir"))
    if not dest:
        raise al.AudioError(t("Für das Prüfpaket einen Ordner wählen.", "Choose a folder for the review package."))
    if not review_app().is_file():
        raise al.AudioError(t("Die Prüf-App (NVAI-Pruefer.html) fehlt in dieser Installation.",
                              "The review app (NVAI-Pruefer.html) is missing in this installation."))
    known = {x["id"] for x in _tracks(p)}
    originals = [x for x in req.get("originals") or [] if x in known]
    return await jobs.submit("audio_package", {"project_id": pid, "dest_dir": dest, "images": bool(req.get("images", True)),
                                               "video": bool(req.get("video")), "originals": originals})


_LOCAL = re.compile(r"^[A-Za-z]:[\\/]|^\\\\|^/(Users|home|Volumes)/")


def _strip_paths(x: Any) -> Any:
    """Pfade dieses Rechners (Benutzername, Ordner) durch den bloßen Dateinamen ersetzen: Das Paket geht an Dritte."""
    if isinstance(x, dict):
        return {k: _strip_paths(v) for k, v in x.items()}
    if isinstance(x, list):
        return [_strip_paths(v) for v in x]
    if isinstance(x, str) and _LOCAL.search(x):
        return re.split(r"[\\/]", x.rstrip("\\/"))[-1]
    return x


def _unique(path: Path) -> Path:
    out, k = path, 2
    while out.exists():
        out = path.with_name(f"{path.name} ({k})")
        k += 1
    return out


def _copy_part(job: Job, ctx: jobs.JobContext) -> dict[str, Any]:
    """Ordner anlegen und die Dateien des Falls kopieren (mit SHA-256 im selben Durchgang)."""
    prm = job.params
    pid = prm["project_id"]
    p, items, proxies, vname = _plan(pid, prm["images"], prm["video"])
    out = _unique(Path(prm["dest_dir"]) / f"{_safe(p['name'])} – Prüfpaket")
    fall = out / "fall"
    fall.mkdir(parents=True)
    try:
        return _copy_files(job, ctx, p, items, proxies, vname, out)
    except BaseException:
        _drop_package(out)
        raise


def _drop_package(out: Path) -> None:
    """Halbes Prüfpaket nach Abbruch oder Fehler entfernen: Der Ordner ist in diesem Lauf neu angelegt (_unique), ohne
    Prüfsummen und Prüf-App taugt er nicht zur Weitergabe und belegt sonst Gigabytes."""
    with contextlib.suppress(OSError):
        shutil.rmtree(out)


def _copy_files(job: Job, ctx: jobs.JobContext, p: dict[str, Any], items: Any, proxies: Any, vname: Any,
                out: Path) -> dict[str, Any]:
    prm = job.params
    fall = out / "fall"
    (out / "bearbeitung").mkdir()
    sums: dict[str, str] = {}
    total = sum(src.stat().st_size for src, _ in items)
    share = total / max(1, total + sum(_wav_bytes(p, x) for x in _tracks(p) if x["id"] in prm["originals"]))
    done = 0
    last = 0.0
    for src, rel in items:
        dst = fall / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        h = hashlib.sha256()
        if rel.startswith("data/") and rel.endswith(".json") and src.stat().st_size < 64 * 1024 * 1024:
            # kleine Daten (vdr.json nannte den Quellordner dieses Rechners): ohne Pfade, sonst unverändert
            with contextlib.suppress(ValueError, OSError):
                data = json.dumps(_strip_paths(json.loads(src.read_text(encoding="utf-8"))), ensure_ascii=False).encode("utf-8")
                dst.write_bytes(data)
                h.update(data)
                done += src.stat().st_size
                sums[f"fall/{rel}"] = h.hexdigest()
                continue
        with src.open("rb") as fi, dst.open("wb") as fo:
            for block in iter(lambda: fi.read(CHUNK), b""):
                fo.write(block)
                h.update(block)
                done += len(block)
                if time.time() - last > 0.5:
                    ctx.progress(0.97 * share * done / max(1, total), t(f"kopiert {rel.split('/')[0]}", f"copying {rel.split('/')[0]}"))
                    last = time.time()
                    if ctx.should_stop():
                        raise asyncio.CancelledError
        sums[f"fall/{rel}"] = h.hexdigest()
    return {"p": p, "out": out, "sums": sums, "proxies": proxies, "vname": vname, "share": share, "bytes": done}


def _finish(job: Job, state: dict[str, Any], originals: dict[str, Any]) -> dict[str, Any]:
    """Fall ohne Pfade dieses Rechners, Übersetzer-Spur, Manifest, Prüf-App, Anleitung, Prüfsummen."""
    prm = job.params
    pid = prm["project_id"]
    p, out, sums, vname = state["p"], state["out"], state["sums"], state["vname"]
    fall = out / "fall"
    q = json.loads(json.dumps(p))
    q["tracks"] = _tracks(q)
    q["source"] = {k: v for k, v in (q.get("source") or {}).items() if k != "path"}
    video = q.pop("video", None)
    q["video"] = {**video, "path": f"video/{vname}", "name": vname} if (video and vname) else None
    if video and not vname:
        q["video_info"] = {k: v for k, v in video.items() if k != "path"}
    created = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
    q["package"] = {"format": FORMAT, "version": VERSION, "created": created}
    q = _strip_paths(q)
    doc = load_transcript(pid)
    # Hinweis bei der Übersetzung (Modelle, Lizenzen, Grafikkarte) fest ins Paket, die Prüf-App hat keinen Server
    doc = _strip_paths({**doc, "credits": transcript_credits(doc)})
    manifest = {"format": FORMAT, "version": VERSION, "created": created, "program": f"NVAI-open {__version__}",
                "project_id": pid, "name": p["name"], "time_origin": p.get("time_origin"), "duration": p.get("duration"),
                "proxies": state["proxies"], "video": vname, "images": bool(prm["images"]), "originals": originals,
                "segments": len(doc.get("segments") or []), "files": len(sums) + 5}
    for name, data in (("projekt.json", q), ("transkript.json", doc), ("manifest.json", manifest)):
        raw = json.dumps(data, ensure_ascii=False, indent=1).encode("utf-8")
        (fall / name).write_bytes(raw)
        sums[f"fall/{name}"] = hashlib.sha256(raw).hexdigest()
    app = review_app().read_bytes()
    (out / REVIEW_APP).write_bytes(app)
    sums[REVIEW_APP] = hashlib.sha256(app).hexdigest()
    readme = LIESMICH.format(name=p["name"], created=created, program=manifest["program"]).encode("utf-8")
    (out / "LIESMICH.txt").write_bytes(readme)
    sums["LIESMICH.txt"] = hashlib.sha256(readme).hexdigest()
    (out / "PRUEFSUMMEN.sha256").write_text("".join(f"{h} *{rel}\n" for rel, h in sorted(sums.items())), encoding="utf-8")
    return {"path": str(out), "files": len(sums)}


async def _package(job: Job, ctx: jobs.JobContext) -> list[str]:
    pid = job.params["project_id"]
    state = await asyncio.to_thread(_copy_part, job, ctx)  # räumt bei Abbruch selbst auf
    originals: dict[str, Any] = {}
    todo = job.params["originals"]
    try:
        for k, tid in enumerate(todo):
            name = f"{tid}.wav"
            dst = state["out"] / "fall" / "original" / name
            dst.parent.mkdir(parents=True, exist_ok=True)
            base = state["share"] + (1 - state["share"]) * k / len(todo)
            res = await al._run_tool("wavcopy", {"src": str(al._track_paths(pid, tid)["flac"]), "dst": str(dst)}, ctx,
                                     0.97 * base, 0.97 * (1 - state["share"]) / len(todo),
                                     t("Originalton als WAV", "original audio as WAV"))
            state["sums"][f"fall/original/{name}"] = res["sha256"]
            state["bytes"] += res["bytes"]
            originals[tid] = {"file": name, **{k2: res[k2] for k2 in ("sample_rate", "channels", "frames", "subtype", "format")}}
        res = await asyncio.to_thread(_finish, job, state, originals)
    except BaseException:
        _drop_package(state["out"])
        raise
    ctx.progress(1.0, t("fertig", "done"))
    al.update(pid, lambda q: q["history"].append(
        {"time": time.time(), "op": "export", "format": "pruefpaket", "path": res["path"], "file": Path(res["path"]).name,
         "files": res["files"], "bytes": state["bytes"]}))
    return []


LIESMICH = """NVAI-open · Prüfpaket „{name}“ (erstellt {created} mit {program})

DEUTSCH
1. NVAI-Pruefer.html mit Microsoft Edge oder Google Chrome öffnen (Doppelklick; sonst Rechtsklick → Öffnen mit).
2. Namen eintragen, „Fall öffnen …“ wählen und diesen Ordner wählen (den Ordner, in dem NVAI-Pruefer.html liegt).
   Das Bearbeiten erlauben, wenn der Browser fragt.
3. Ansehen, anhören, Blöcke der Übersetzer-Spur prüfen und korrigieren, Notizen setzen, exportieren.
Ohne Installation, ohne Internet, ohne KI. Änderungen speichert die App im Unterordner „bearbeitung“ (mit einem
Prüfprotokoll); die gelieferten Dateien bleiben unverändert. Prüfen lassen sie sich mit PRUEFSUMMEN.sha256, z. B.
  Windows (PowerShell):  Get-FileHash -Algorithm SHA256 <Datei>
  Mac/Linux:             shasum -a 256 -c PRUEFSUMMEN.sha256
Texte der KI (Erkennung, Übersetzung) sind Entwürfe, bis sie als geprüft markiert sind.

ENGLISH
1. Open NVAI-Pruefer.html with Microsoft Edge or Google Chrome (double-click; otherwise right-click → Open with).
2. Enter your name, choose “Open case …” and select this folder (the one containing NVAI-Pruefer.html). Allow
   editing when the browser asks.
3. View, listen, check and correct blocks of the translation track, set notes, export.
No installation, no internet, no AI. The app saves changes in the subfolder “bearbeitung” (with a review log); the
delivered files stay unchanged and can be verified with PRUEFSUMMEN.sha256 (see above). AI texts (recognition,
translation) are drafts until marked as checked.
"""


class PackageRequest(BaseModel):
    dest_dir: str = Field(..., max_length=500)
    images: bool = True
    video: bool = False
    originals: list[str] = Field(default_factory=list, max_length=64)


@router.get("/projects/{pid}/package/estimate")
async def api_package_estimate(pid: str) -> dict[str, Any]:
    return await asyncio.to_thread(al._http, estimate, pid)


@router.post("/projects/{pid}/package", response_model=Job)
async def api_package(pid: str, req: PackageRequest) -> Job:
    return await al._ahttp(submit_package(pid, req.model_dump()))


jobs.register("audio_package")(_package)
jobs.RENDER_KINDS.add("audio_package")
