"""Studio: Projekte mit zwei Zeitleisten (Nutzer 26.10.2026, Anleitung docs/STUDIO.md).

Komposition: Szenen mit Prompt, Modell und Dauer auf Bahnen (Bild/Video, Sprecher, Musik, Klang), dazu Marker, die
sagen, was wohin soll. Schnitt: die echten Clips auf Spuren (V1, V2, A1, A2) mit In/Out, Ueberblendung und
Lautstaerke. Ein Clip bleibt mit seiner Szene verbunden: Wird sie neu erzeugt, tauscht er beim Uebernehmen sein
Material und behaelt den Schnitt, soweit das neue Material reicht.

Zeit in ganzzahligen Ticks wie bei FilmCraft (254 016 000 000 je Sekunde: teilt jede Bild- und Abtastrate, kein
Rundungsfehler bei 29,97 fps). Befehle nehmen Zeiten in Ticks (`start`, `duration`, `at`, `in`, `out`) oder in
Sekunden (`start_s`, `duration_s`, `at_s` …), wie FilmCraft `time`/`seconds`.

Jede Aenderung ist ein Befehl (`apply`); Oberflaeche, REST und MCP nutzen dieselben. Rueckgaengig/Wiederholen haelt
je Projekt bis zu 100 Staende im Speicher (Sitzungszustand wie bei FilmCraft). Projekte liegen als JSON in
DATA_DIR/studio/, Geloeschtes wandert nach studio/papierkorb/.
"""
from __future__ import annotations

import asyncio
import copy
import json
import os
import re
import subprocess
import threading
import time
from pathlib import Path
from typing import Any, Callable

from . import comfy, config, db, jobs, registry
from .i18n import t
from .schemas import GenerateAudioRequest, GenerateImageRequest, GenerateVideoRequest, Job

TICKS_PER_SECOND = 254_016_000_000
UNDO_LIMIT = 100
VERSION = 1

# Bahnen der Komposition und die Spur, auf die das Uebernehmen ihre Takes legt.
LANES = ("video", "voice", "music", "sfx")
LANE_TRACK = {"video": "V1", "voice": "A1", "music": "A2", "sfx": "A2"}
TRACKS = [{"id": "V2", "kind": "video"}, {"id": "V1", "kind": "video"},
          {"id": "A1", "kind": "audio"}, {"id": "A2", "kind": "audio"}]
MARKER_KINDS = ("place", "transition", "chain", "audio", "ai", "note")
MARKER_COLORS = {"place": "blue", "transition": "yellow", "chain": "green", "audio": "cyan", "ai": "purple",
                 "note": "gray"}
IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp", ".bmp"}
DEFAULT_IMAGE_SECONDS = 5.0

_lock = threading.RLock()
_undo: dict[str, list[dict[str, Any]]] = {}
_redo: dict[str, list[dict[str, Any]]] = {}
# Anschluss-Szenen, die auf ihre Vorlage warten: Szenen-ID -> Task (nur im Speicher, wie FilmCraft den Sitzungszustand)
_chain_tasks: dict[str, asyncio.Task] = {}
CHAIN_POLL_SECONDS = 2.0


class StudioError(ValueError):
    """Ungueltiger Befehl oder Parameter; die API macht daraus 422 bzw. 404."""


class NotFound(StudioError):
    pass


# ------------------------------------------------------------------------------------------------ Zeit

def ticks(seconds: float) -> int:
    return int(round(float(seconds) * TICKS_PER_SECOND))


def seconds(value: int) -> float:
    return value / TICKS_PER_SECOND


def _time(a: dict[str, Any], key: str, default: int | None = None) -> int | None:
    """Zeit aus `key` (Ticks) oder `key_s` (Sekunden)."""
    if a.get(key) is not None:
        return int(a[key])
    if a.get(f"{key}_s") is not None:
        return ticks(a[f"{key}_s"])
    return default


def frame_ticks(p: dict[str, Any]) -> int:
    num, den = p["settings"]["fps"]
    return TICKS_PER_SECOND * den // num


# ---------------------------------------------------------------------------------------- Speicherort

def _dir() -> Path:
    d = config.DATA_DIR / "studio"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _path(pid: str) -> Path:
    if not pid or any(c in pid for c in "/\\.:"):
        raise NotFound(t(f"Unbekanntes Projekt: {pid}", f"Unknown project: {pid}"))
    return _dir() / f"{pid}.json"


def _save(p: dict[str, Any]) -> None:
    path = _path(p["id"])
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(p, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(tmp, path)
    # Die Oberflaeche laedt nach, auch wenn Claude per MCP oder ein fertiger Auftrag das Projekt geaendert hat
    jobs.publish({"type": "studio.changed", "project_id": p["id"], "updated_at": p.get("updated_at")})


def load(pid: str) -> dict[str, Any]:
    path = _path(pid)
    if not path.exists():
        raise NotFound(t(f"Unbekanntes Projekt: {pid}", f"Unknown project: {pid}"))
    return json.loads(path.read_text(encoding="utf-8"))


def list_projects() -> list[dict[str, Any]]:
    out = []
    for f in sorted(_dir().glob("*.json"), key=lambda f: f.stat().st_mtime, reverse=True):
        try:
            p = json.loads(f.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        out.append({"id": p["id"], "name": p["name"], "updated_at": p.get("updated_at"),
                    "scenes": len(p.get("scenes", [])), "clips": len(p.get("clips", [])),
                    "duration_s": round(seconds(edit_duration(p)), 2)})
    return out


def _next_new_name() -> str:
    """„New 1“, „New 2“ …: Ohne Namen heißt ein Projekt so, mit der nächsten Zahl (Nutzer 26.10.2026, in beiden
    Sprachen gleich)."""
    numbers = [int(m.group(1)) for info in list_projects() if (m := re.fullmatch(r"New (\d+)", info["name"]))]
    return f"New {max(numbers, default=0) + 1}"


def create(name: str = "", width: int = 1920, height: int = 1080, fps: tuple[int, int] = (24, 1)) -> dict[str, Any]:
    now = time.time()
    p = {"version": VERSION, "id": db.new_id("stu"), "name": name.strip() or _next_new_name(),
         "created_at": now, "updated_at": now,
         "settings": {"width": int(width), "height": int(height), "fps": [int(fps[0]), int(fps[1])],
                      "sample_rate": 48000, "video_quality": "dfr"},
         "scenes": [], "markers": [], "tracks": copy.deepcopy(TRACKS), "clips": [], "media": {}}
    with _lock:
        _save(p)
    return p


def delete(pid: str) -> None:
    """In den Papierkorb des Studios, nicht endgueltig."""
    path = _path(pid)
    if not path.exists():
        raise NotFound(t(f"Unbekanntes Projekt: {pid}", f"Unknown project: {pid}"))
    trash = _dir() / "papierkorb"
    trash.mkdir(exist_ok=True)
    with _lock:
        os.replace(path, trash / f"{pid}-{int(time.time())}.json")
        _undo.pop(pid, None)
        _redo.pop(pid, None)


# -------------------------------------------------------------------------------------------- Medien

def _asset_path(asset_id: str) -> tuple[Any, Path]:
    asset = db.get_asset(asset_id)
    if asset is None:
        raise StudioError(t(f"Unbekanntes Asset: {asset_id}", f"Unknown asset: {asset_id}"))
    return asset, config.ASSET_DIR / asset.filename


def _source_path(asset_id: str) -> Path:
    """Die beste Quelle eines Assets: der verlustfreie Master (meta.master), sonst die Datei selbst. Export und
    Anschluss-Startbild lesen daraus, damit nur der Export selbst komprimiert."""
    asset, path = _asset_path(asset_id)
    return jobs.master_path(asset) or path


def probe(asset_id: str) -> dict[str, Any]:
    """Art, Dauer, Format eines Assets; Bilder haben keine eigene Dauer. Laeuft in video_tools.py (PyAV)."""
    asset, path = _asset_path(asset_id)
    if asset.kind == "image" or path.suffix.lower() in IMAGE_SUFFIXES:
        return {"kind": "image", "duration": None}
    if asset.kind not in ("video", "audio", "upload"):
        raise StudioError(t(f"{asset_id} ist weder Bild, Video noch Ton.", f"{asset_id} is not an image, video or audio."))
    script = Path(__file__).with_name("video_tools.py")
    proc = subprocess.run([str(comfy.comfy_python()), "-I", str(script), "probe", str(path)], capture_output=True,
                          text=True, timeout=60, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    if proc.returncode != 0:
        raise StudioError(t(f"Datei nicht lesbar: {asset.filename}", f"Cannot read file: {asset.filename}"))
    info = json.loads(proc.stdout.strip().splitlines()[-1])
    kind = "video" if info.get("video") else "audio"
    out = {"kind": kind, "duration": ticks(info["seconds"]) if info.get("seconds") else None,
           "audio": bool(info.get("audio"))}
    if kind == "video":
        out.update(width=info.get("width"), height=info.get("height"), fps=info.get("fps"))
    return out


def _media(p: dict[str, Any], asset_id: str) -> dict[str, Any]:
    """Medieninfo aus dem Projekt-Cache, sonst einmal gemessen."""
    m = p.setdefault("media", {})
    if asset_id not in m:
        m[asset_id] = probe(asset_id)
    return m[asset_id]


# ----------------------------------------------------------------------------------------- Abfragen

def _find(items: list[dict[str, Any]], item_id: str, what: str) -> dict[str, Any]:
    for it in items:
        if it["id"] == item_id:
            return it
    raise NotFound(t(f"Unbekannte {what}: {item_id}", f"Unknown {what}: {item_id}"))


def clip_end(c: dict[str, Any]) -> int:
    return c["start"] + (c["out"] - c["in"])


def edit_duration(p: dict[str, Any]) -> int:
    return max((clip_end(c) for c in p.get("clips", [])), default=0)


def composition_duration(p: dict[str, Any]) -> int:
    return max((s["start"] + s["duration"] for s in p.get("scenes", [])), default=0)


def _lane_end(p: dict[str, Any], lane: str) -> int:
    return max((s["start"] + s["duration"] for s in p["scenes"] if s["lane"] == lane), default=0)


# ------------------------------------------------------------------------------------------- Befehle

Command = Callable[[dict[str, Any], dict[str, Any]], Any]
COMMANDS: dict[str, Command] = {}
HELP: dict[str, str] = {}


def command(name: str, help_text: str) -> Callable[[Command], Command]:
    def deco(fn: Command) -> Command:
        COMMANDS[name] = fn
        HELP[name] = help_text
        return fn
    return deco


def apply(pid: str, name: str, params: dict[str, Any] | None = None) -> tuple[dict[str, Any], Any]:
    """Befehl ausfuehren, speichern, den alten Stand auf den Rueckgaengig-Stapel legen."""
    if name not in COMMANDS:
        raise StudioError(t(f"Unbekannter Befehl: {name}", f"Unknown command: {name}"))
    with _lock:
        p = load(pid)
        before = copy.deepcopy(p)
        result = COMMANDS[name](p, dict(params or {}))
        p["updated_at"] = time.time()
        _save(p)
        stack = _undo.setdefault(pid, [])
        stack.append(before)
        del stack[:-UNDO_LIMIT]
        _redo.pop(pid, None)
    return p, result


def undo(pid: str) -> dict[str, Any]:
    with _lock:
        stack = _undo.get(pid) or []
        if not stack:
            raise StudioError(t("Nichts zum Rückgängigmachen.", "Nothing to undo."))
        current = load(pid)
        p = stack.pop()
        _keep_generation(p, current)
        _redo.setdefault(pid, []).append(current)
        p["updated_at"] = time.time()
        _save(p)
    return p


def redo(pid: str) -> dict[str, Any]:
    with _lock:
        stack = _redo.get(pid) or []
        if not stack:
            raise StudioError(t("Nichts zum Wiederholen.", "Nothing to redo."))
        current = load(pid)
        p = stack.pop()
        _keep_generation(p, current)
        _undo.setdefault(pid, []).append(current)
        p["updated_at"] = time.time()
        _save(p)
    return p


def _keep_generation(restored: dict[str, Any], current: dict[str, Any]) -> None:
    """Was Erzeugungsauftraege eingetragen haben, ist kein Befehl: Rueckgaengig und Wiederholen behalten neue Takes,
    laufende Auftraege und wartende Anschluesse, statt sie mit dem alten Stand zu verlieren."""
    now = {s["id"]: s for s in current["scenes"]}
    for s in restored["scenes"]:
        c = now.get(s["id"])
        if c is None:
            continue
        s["takes"] = s["takes"] + [a for a in c["takes"] if a not in s["takes"]]
        s["jobs"] = list(c.get("jobs") or [])
        s["error"] = c.get("error")
        if c.get("waiting_for"):
            s["waiting_for"] = c["waiting_for"]
        else:
            s.pop("waiting_for", None)
        if not s.get("take") and c.get("take"):
            s["take"] = c["take"]
    restored["media"] = {**restored.get("media", {}), **current.get("media", {})}


def history(pid: str) -> dict[str, int]:
    return {"undo": len(_undo.get(pid) or []), "redo": len(_redo.get(pid) or [])}


@command("project.update", "Name oder Einstellungen: name, width, height, fps [num, den], video_quality (dfr|standard)")
def _project_update(p: dict[str, Any], a: dict[str, Any]) -> None:
    if "name" in a:
        p["name"] = str(a["name"]).strip() or p["name"]
    s = p["settings"]
    for key in ("width", "height"):
        if key in a:
            value = int(a[key])
            if not 128 <= value <= 7680 or value % 2:
                raise StudioError(t(f"{key} muss gerade sein, 128 bis 7680.", f"{key} must be even, 128 to 7680."))
            s[key] = value
    if "fps" in a:
        num, den = (int(a["fps"][0]), int(a["fps"][1])) if isinstance(a["fps"], (list, tuple)) else (int(a["fps"]), 1)
        if num <= 0 or den <= 0 or not 1 <= num / den <= 120:
            raise StudioError(t("Bildrate 1 bis 120.", "Frame rate 1 to 120."))
        s["fps"] = [num, den]
    if "video_quality" in a:
        if a["video_quality"] not in ("dfr", "standard"):
            raise StudioError(t("Videoqualität: dfr oder standard.", "Video quality: dfr or standard."))
        s["video_quality"] = a["video_quality"]


# ---------------------------------------------------------------------------------------- Szenen

SCENE_FIELDS = ("title", "prompt", "kind", "model_id", "lane", "chain_from", "lyrics")


@command("scene.add", "Szene anlegen: lane (video|voice|music|sfx), prompt, title, kind (video|image|audio), "
         "model_id, start/start_s (sonst hinten an der Bahn), duration/duration_s (Vorgabe 5 s), params")
def _scene_add(p: dict[str, Any], a: dict[str, Any]) -> dict[str, str]:
    lane = a.get("lane", "video")
    if lane not in LANES:
        raise StudioError(t(f"Bahn {lane} gibt es nicht ({', '.join(LANES)}).", f"No lane {lane} ({', '.join(LANES)})."))
    duration = _time(a, "duration", ticks(5))
    if duration <= 0:
        raise StudioError(t("Die Dauer muss größer als 0 sein.", "The duration must be greater than 0."))
    start = _time(a, "start", _lane_end(p, lane))
    kind = a.get("kind") or ("video" if lane == "video" else "audio")
    if kind not in ("video", "image", "audio"):
        raise StudioError(t("kind ist video, image oder audio.", "kind is video, image or audio."))
    scene = {"id": db.new_id("sc"), "lane": lane, "start": max(0, start), "duration": duration,
             "title": str(a.get("title", "")), "prompt": str(a.get("prompt", "")), "kind": kind,
             "model_id": a.get("model_id"), "lyrics": str(a.get("lyrics", "")), "params": dict(a.get("params") or {}),
             "chain_from": a.get("chain_from"), "takes": [], "take": None, "jobs": [], "error": None}
    p["scenes"].append(scene)
    p["scenes"].sort(key=lambda s: (LANES.index(s["lane"]), s["start"]))
    return {"id": scene["id"]}


@command("scene.update", "Felder ändern: id und title, prompt, kind, model_id, lane, chain_from, lyrics, params "
         "(wird zusammengeführt), start/start_s, duration/duration_s")
def _scene_update(p: dict[str, Any], a: dict[str, Any]) -> None:
    s = _find(p["scenes"], a.get("id", ""), t("Szene", "scene"))
    for key in SCENE_FIELDS:
        if key in a:
            s[key] = a[key]
    if s["lane"] not in LANES:
        raise StudioError(t(f"Bahn {s['lane']} gibt es nicht.", f"No lane {s['lane']}."))
    if isinstance(a.get("params"), dict):
        s["params"].update(a["params"])
    start = _time(a, "start")
    if start is not None:
        s["start"] = max(0, start)
    duration = _time(a, "duration")
    if duration is not None:
        if duration <= 0:
            raise StudioError(t("Die Dauer muss größer als 0 sein.", "The duration must be greater than 0."))
        s["duration"] = duration
    p["scenes"].sort(key=lambda x: (LANES.index(x["lane"]), x["start"]))


@command("scene.delete", "Szene löschen: id; verbundene Clips im Schnitt bleiben, verlieren nur die Verbindung")
def _scene_delete(p: dict[str, Any], a: dict[str, Any]) -> None:
    s = _find(p["scenes"], a.get("id", ""), t("Szene", "scene"))
    p["scenes"].remove(s)
    for c in p["clips"]:
        if c.get("scene_id") == s["id"]:
            c["scene_id"] = None
    for other in p["scenes"]:
        if other.get("chain_from") == s["id"]:
            other["chain_from"] = None
        if other.get("waiting_for") == s["id"]:
            other.pop("waiting_for")  # der wartende Task sieht das und endet


@command("scene.take", "Take wählen oder hinzufügen: id, asset_id (ein Asset aus dem Verlauf wird zum Take)")
def _scene_take(p: dict[str, Any], a: dict[str, Any]) -> None:
    s = _find(p["scenes"], a.get("id", ""), t("Szene", "scene"))
    asset_id = a.get("asset_id", "")
    _media(p, asset_id)  # prueft, dass es das Asset gibt und es lesbar ist
    if asset_id not in s["takes"]:
        s["takes"].append(asset_id)
    s["take"] = asset_id
    s["error"] = None


# ------------------------------------------------------------------------------------------ Marker

@command("marker.add", "Marker setzen: at/at_s, kind (place|transition|chain|audio|ai|note), name, comment, "
         "duration/duration_s, params (place: scene_id, track; transition: seconds; audio: scene_id)")
def _marker_add(p: dict[str, Any], a: dict[str, Any]) -> dict[str, str]:
    kind = a.get("kind", "note")
    if kind not in MARKER_KINDS:
        raise StudioError(t(f"Markerart {kind} gibt es nicht ({', '.join(MARKER_KINDS)}).",
                            f"No marker kind {kind} ({', '.join(MARKER_KINDS)})."))
    at = _time(a, "at", 0)
    marker = {"id": db.new_id("mk"), "at": max(0, at), "duration": max(0, _time(a, "duration", 0)), "kind": kind,
              "name": str(a.get("name", "")), "comment": str(a.get("comment", "")),
              "color": a.get("color") or MARKER_COLORS[kind], "params": dict(a.get("params") or {}), "done": False}
    p["markers"].append(marker)
    p["markers"].sort(key=lambda m: m["at"])
    return {"id": marker["id"]}


@command("marker.update", "Marker ändern: id und at/at_s, duration/duration_s, kind, name, comment, color, params, done")
def _marker_update(p: dict[str, Any], a: dict[str, Any]) -> None:
    m = _find(p["markers"], a.get("id", ""), t("Marker", "marker"))
    for key in ("name", "comment", "color", "done"):
        if key in a:
            m[key] = a[key]
    if "kind" in a:
        if a["kind"] not in MARKER_KINDS:
            raise StudioError(t(f"Markerart {a['kind']} gibt es nicht.", f"No marker kind {a['kind']}."))
        m["kind"] = a["kind"]
    if not m.get("color"):  # neue Art ohne eigene Farbe: die Farbe der Art
        m["color"] = MARKER_COLORS[m["kind"]]
    if isinstance(a.get("params"), dict):
        m["params"].update(a["params"])
    at = _time(a, "at")
    if at is not None:
        m["at"] = max(0, at)
    duration = _time(a, "duration")
    if duration is not None:
        m["duration"] = max(0, duration)
    p["markers"].sort(key=lambda x: x["at"])


@command("marker.delete", "Marker löschen: id")
def _marker_delete(p: dict[str, Any], a: dict[str, Any]) -> None:
    p["markers"].remove(_find(p["markers"], a.get("id", ""), t("Marker", "marker")))


# ------------------------------------------------------------------------------------------- Schnitt

def _track(p: dict[str, Any], track_id: str) -> dict[str, Any]:
    for tr in p["tracks"]:
        if tr["id"] == track_id:
            return tr
    raise StudioError(t(f"Spur {track_id} gibt es nicht.", f"No track {track_id}."))


def _overwrite(p: dict[str, Any], clip: dict[str, Any]) -> None:
    """Wie „Überschreiben“ in jedem Schnittprogramm: Was auf derselben Spur unter dem Clip liegt, wird gekürzt,
    geteilt oder entfernt."""
    s, e = clip["start"], clip_end(clip)
    keep = []
    for c in p["clips"]:
        if c is clip or c["track"] != clip["track"] or clip_end(c) <= s or c["start"] >= e:
            keep.append(c)
            continue
        if c["start"] >= s and clip_end(c) <= e:
            continue  # ganz verdeckt
        if c["start"] < s and clip_end(c) > e:  # teilen
            tail = copy.deepcopy(c)
            tail["id"] = db.new_id("cl")
            tail["in"] = c["in"] + (e - c["start"])
            tail["start"] = e
            tail["transition"] = None
            c["out"] = c["in"] + (s - c["start"])
            keep += [c, tail]
        elif c["start"] < s:  # Ende kürzen
            c["out"] = c["in"] + (s - c["start"])
            keep.append(c)
        else:  # Anfang kürzen
            c["in"] += e - c["start"]
            c["start"] = e
            c["transition"] = None
            keep.append(c)
    p["clips"] = keep
    p["clips"].sort(key=lambda c: (c["track"], c["start"]))


def _new_clip(p: dict[str, Any], track: str, asset_id: str, start: int, length: int | None = None,
              in_point: int = 0, scene_id: str | None = None) -> dict[str, Any]:
    tr = _track(p, track)
    media = _media(p, asset_id)
    if tr["kind"] == "audio" and media["kind"] == "image":
        raise StudioError(t("Ein Bild gehört auf eine Videospur.", "An image belongs on a video track."))
    if tr["kind"] == "video" and media["kind"] == "audio":
        raise StudioError(t("Ton gehört auf eine Tonspur.", "Audio belongs on an audio track."))
    available = None if media["kind"] == "image" else (media["duration"] or 0) - in_point
    if length is None:
        length = available if available else ticks(DEFAULT_IMAGE_SECONDS)
    if available is not None:
        length = min(length, available)
    if length <= 0:
        raise StudioError(t("Der Clip hätte keine Länge.", "The clip would have no length."))
    return {"id": db.new_id("cl"), "track": track, "asset_id": asset_id, "scene_id": scene_id, "start": max(0, start),
            "in": in_point, "out": in_point + length, "gain_db": 0.0, "muted": False, "transition": None}


@command("clip.add", "Clip auf eine Spur legen (überschreibt Darunterliegendes): track (V1|V2|A1|A2), asset_id, "
         "start/start_s, in/in_s, duration/duration_s")
def _clip_add(p: dict[str, Any], a: dict[str, Any]) -> dict[str, str]:
    clip = _new_clip(p, a.get("track", "V1"), a.get("asset_id", ""), _time(a, "start", edit_duration(p)),
                     _time(a, "duration"), _time(a, "in", 0))
    p["clips"].append(clip)
    _overwrite(p, clip)
    return {"id": clip["id"]}


@command("clip.move", "Clip verschieben: id, start/start_s, track (überschreibt am Ziel)")
def _clip_move(p: dict[str, Any], a: dict[str, Any]) -> None:
    c = _find(p["clips"], a.get("id", ""), t("Clip", "clip"))
    start = _time(a, "start")
    if start is not None:
        c["start"] = max(0, start)
    if a.get("track"):
        tr = _track(p, a["track"])
        if tr["kind"] != _track(p, c["track"])["kind"]:
            raise StudioError(t("Video bleibt auf Video-, Ton auf Tonspuren.", "Video stays on video, audio on audio tracks."))
        c["track"] = tr["id"]
    _overwrite(p, c)


@command("clip.trim", "Clip trimmen: id und edge (start|end) mit to/to_s (Zeitleistenposition), oder in/out "
         "(Medienzeit)")
def _clip_trim(p: dict[str, Any], a: dict[str, Any]) -> None:
    c = _find(p["clips"], a.get("id", ""), t("Clip", "clip"))
    media = _media(p, c["asset_id"])
    limit = None if media["kind"] == "image" else media["duration"]
    frame = frame_ticks(p)
    to = _time(a, "to")
    if a.get("edge") == "start" and to is not None:
        delta = to - c["start"]
        c["in"] = c["in"] + delta
        c["start"] = to
    elif a.get("edge") == "end" and to is not None:
        c["out"] = c["in"] + (to - c["start"])
    else:
        if _time(a, "in") is not None:
            new_in = _time(a, "in")
            c["start"] += new_in - c["in"]
            c["in"] = new_in
        if _time(a, "out") is not None:
            c["out"] = _time(a, "out")
    if c["in"] < 0:  # nicht vor den Anfang des Materials
        c["start"] -= c["in"]
        c["in"] = 0
    if limit is not None and c["out"] > limit:
        c["out"] = limit
    if c["start"] < 0:
        c["in"] -= c["start"]
        c["start"] = 0
    if c["out"] - c["in"] < frame:
        raise StudioError(t("Ein Clip braucht mindestens ein Bild.", "A clip needs at least one frame."))
    _overwrite(p, c)


@command("clip.razor", "Schneiden: at/at_s; track (sonst alle Spuren)")
def _clip_razor(p: dict[str, Any], a: dict[str, Any]) -> dict[str, list[str]]:
    at = _time(a, "at")
    if at is None:
        raise StudioError(t("at oder at_s fehlt.", "at or at_s is missing."))
    new_ids = []
    for c in list(p["clips"]):
        if a.get("track") and c["track"] != a["track"]:
            continue
        if c["start"] < at < clip_end(c):
            tail = copy.deepcopy(c)
            tail["id"] = db.new_id("cl")
            tail["in"] = c["in"] + (at - c["start"])
            tail["start"] = at
            tail["transition"] = None
            c["out"] = tail["in"]
            p["clips"].append(tail)
            new_ids.append(tail["id"])
    p["clips"].sort(key=lambda c: (c["track"], c["start"]))
    return {"ids": new_ids}


@command("clip.delete", "Clips löschen: ids (Liste) oder id; ripple=true schließt die Lücke auf der Spur")
def _clip_delete(p: dict[str, Any], a: dict[str, Any]) -> None:
    ids = list(a.get("ids") or ([a["id"]] if a.get("id") else []))
    for clip_id in ids:
        c = _find(p["clips"], clip_id, t("Clip", "clip"))
        p["clips"].remove(c)
        if a.get("ripple"):
            gap = c["out"] - c["in"]
            for other in p["clips"]:
                if other["track"] == c["track"] and other["start"] >= clip_end(c):
                    other["start"] -= gap


@command("clip.update", "Clip ändern: id, gain_db, muted, transition (Überblendung am Anfang: {kind: dissolve, "
         "duration/duration_s} oder null)")
def _clip_update(p: dict[str, Any], a: dict[str, Any]) -> None:
    c = _find(p["clips"], a.get("id", ""), t("Clip", "clip"))
    if "gain_db" in a:
        c["gain_db"] = max(-60.0, min(12.0, float(a["gain_db"])))
    if "muted" in a:
        c["muted"] = bool(a["muted"])
    if "transition" in a:
        tr = a["transition"]
        if tr is None:
            c["transition"] = None
        else:
            duration = _time(tr, "duration", ticks(0.5))
            c["transition"] = {"kind": tr.get("kind", "dissolve"),
                               "duration": max(frame_ticks(p), min(duration, c["out"] - c["in"]))}


# ---------------------------------------------------------------------------------------- Übernehmen

@command("edit.conform", "Komposition übernehmen: legt die gewählten Takes in den Schnitt, tauscht neu erzeugtes "
         "Material in verbundenen Clips aus und wertet die Marker aus (place, transition, audio)")
def _conform(p: dict[str, Any], a: dict[str, Any]) -> dict[str, int]:
    created = updated = transitions = 0
    scenes = {s["id"]: s for s in p["scenes"]}
    # Audio-Marker: die genannte Szene beginnt an der Marke
    for m in p["markers"]:
        if m["kind"] == "audio" and m["params"].get("scene_id") in scenes:
            scenes[m["params"]["scene_id"]]["start"] = m["at"]
    placed: dict[str, tuple[int, str]] = {}
    for m in p["markers"]:
        if m["kind"] == "place" and m["params"].get("scene_id") in scenes:
            placed[m["params"]["scene_id"]] = (m["at"], m["params"].get("track") or "V2")
    for s in p["scenes"]:
        if not s.get("take"):
            continue
        start, track = placed.get(s["id"], (s["start"], LANE_TRACK[s["lane"]]))
        linked = [c for c in p["clips"] if c.get("scene_id") == s["id"]]
        if linked:
            for c in linked:
                if c["asset_id"] != s["take"]:
                    media = _media(p, s["take"])
                    c["asset_id"] = s["take"]
                    if media["kind"] != "image" and media["duration"]:
                        c["out"] = min(c["out"], media["duration"])
                        c["in"] = min(c["in"], max(0, c["out"] - frame_ticks(p)))
                    updated += 1
            continue
        clip = _new_clip(p, track, s["take"], start, s["duration"], 0, s["id"])
        p["clips"].append(clip)
        _overwrite(p, clip)
        created += 1
    # Übergang-Marker: Überblendung auf den Clip, der dort (± eine halbe Sekunde) beginnt
    half = ticks(0.5)
    for m in p["markers"]:
        if m["kind"] != "transition":
            continue
        duration = m["duration"] or ticks(float(m["params"].get("seconds", 0.5)))
        for c in p["clips"]:
            if c["track"] in ("V1", "V2") and abs(c["start"] - m["at"]) <= half and c["start"] > 0:
                c["transition"] = {"kind": m["params"].get("transition", "dissolve"),
                                   "duration": max(frame_ticks(p), min(duration, c["out"] - c["in"]))}
                transitions += 1
                break
    p["clips"].sort(key=lambda c: (c["track"], c["start"]))
    return {"created": created, "updated": updated, "transitions": transitions}


# --------------------------------------------------------------------------- Abgleich mit den Aufträgen

def refresh(pid: str) -> dict[str, Any]:
    """Fertige Erzeugungsaufträge als Takes eintragen (auch wenn Claude per MCP erzeugen ließ). Kein Befehl:
    landet nicht auf dem Rückgängig-Stapel."""
    with _lock:
        p = load(pid)
        changed = False
        for s in p["scenes"]:
            pending = []
            for job_id in s.get("jobs", []):
                job = db.get_job(job_id)
                if job is None or job.status in ("queued", "running"):
                    if job is not None:
                        pending.append(job_id)
                    continue
                changed = True
                if job.status == "done":
                    for asset_id in job.asset_ids:
                        if asset_id not in s["takes"]:
                            s["takes"].append(asset_id)
                    if job.asset_ids:
                        s["take"] = job.asset_ids[-1]
                        s["error"] = None
                elif job.status == "error":
                    s["error"] = job.error
            if pending != s.get("jobs", []):
                s["jobs"] = pending
                changed = True
            # Takes, deren Datei gelöscht wurde (Material oder Verlauf), fallen weg
            alive = [a for a in s["takes"] if db.get_asset(a) is not None]
            if alive != s["takes"]:
                s["takes"] = alive
                if s.get("take") not in alive:
                    s["take"] = alive[-1] if alive else None
                changed = True
            # Wartende Anschluss-Szene ohne lebenden Task (Server neu gestartet): wieder freigeben
            if s.get("waiting_for") and s["id"] not in _chain_tasks:
                s.pop("waiting_for")
                changed = True
        if changed:
            for s in p["scenes"]:
                for asset_id in s["takes"]:
                    try:
                        _media(p, asset_id)
                    except StudioError:
                        pass
            p["updated_at"] = time.time()
            _save(p)
    return p


def scene_status(s: dict[str, Any]) -> str:
    if s.get("jobs"):
        return "running"
    if s.get("waiting_for"):
        return "waiting"
    if s.get("error"):
        return "error"
    return "done" if s.get("take") else "empty"


# ------------------------------------------------------------------------------------------- Erzeugen

def _video_size(model_id: str | None, p: dict[str, Any], params: dict[str, Any]) -> dict[str, int]:
    """LTX-2.5 rechnet in Vielfachen von 64: 1080p als 1920 × 1088, sonst 1280 × 704 (Hochformat gedreht)."""
    if params.get("width") and params.get("height"):
        return {"width": int(params["width"]), "height": int(params["height"])}
    w, h = p["settings"]["width"], p["settings"]["height"]
    big = max(w, h) >= 1900
    long_side, short_side = (1920, 1088) if big else (1280, 704)
    if not (model_id or "").startswith("ltx"):
        long_side, short_side = (832, 480)
    return {"width": long_side, "height": short_side} if w >= h else {"width": short_side, "height": long_side}


def _image_size(p: dict[str, Any], params: dict[str, Any]) -> dict[str, int]:
    """Rund 1 MP im Seitenverhältnis des Projekts, Vielfache von 16."""
    if params.get("width") and params.get("height"):
        return {"width": int(params["width"]), "height": int(params["height"])}
    w, h = p["settings"]["width"], p["settings"]["height"]
    scale = (1_048_576 / (w * h)) ** 0.5
    return {"width": max(256, int(w * scale) // 16 * 16), "height": max(256, int(h * scale) // 16 * 16)}


def _last_frame_asset(asset_id: str, title: str = "") -> str:
    """Letztes Bild eines Videos als Upload-Asset (Startbild für „Anschluss“), in der Medienleiste beschriftet."""
    path = _source_path(asset_id)
    name = f"{db.new_id('upl')}.png"
    script = Path(__file__).with_name("video_tools.py")
    proc = subprocess.run([str(comfy.comfy_python()), "-I", str(script), "last-frame", str(path),
                           str(config.ASSET_DIR / name)], capture_output=True, text=True, timeout=300,
                          creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    if proc.returncode != 0:
        raise StudioError(t("Letztes Bild nicht lesbar.", "Cannot read the last frame."))
    label = t(f"Letztes Bild von „{title}“", f'Last frame of "{title}"') if title else t("Letztes Bild", "Last frame")
    return db.create_asset(kind="upload", filename=name, prompt=label, meta={"studio_last_frame_of": asset_id}).id


def _known_model(model_id: str | None, kind: str) -> str | None:
    """Das Modell der Szene, wenn es es noch gibt, sonst das aktive (etwa nach dem Entfernen von ACE-Step)."""
    if model_id and registry.get_entry(model_id) is not None:
        return model_id
    return registry.get_active_model(kind)


def _job_request(p: dict[str, Any], s: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    """Die Anfrage, wie sie auch /api/generate/* bekäme (dieselbe Prüfung durch das Schema)."""
    params = dict(s.get("params") or {})
    if not s.get("prompt", "").strip():
        raise StudioError(t("Die Szene hat noch keinen Prompt.", "The scene has no prompt yet."))
    secs = seconds(s["duration"])
    if s["lane"] == "voice":
        raise StudioError(t("Eine Sprecherstimme (TTS) hat NVAI-open noch nicht; sie kommt mit Stufe 3. Bis dahin "
                            "eine Tondatei als Take hinzufügen.", "NVAI-open has no voice (TTS) yet; it comes with "
                            "stage 3. Until then, add an audio file as a take."))
    if s["lane"] in ("music", "sfx"):
        model_id = _known_model(s.get("model_id"), "audio")
        req = GenerateAudioRequest(prompt=s["prompt"], model_id=model_id,
                                   seconds=round(min(secs, 300.0), 2),
                                   **{k: v for k, v in params.items() if k in ("seed", "bpm", "key_scale",
                                                                               "time_signature", "steps", "cfg")})
        return "txt2audio", req.model_dump()
    if s["kind"] == "image":
        model_id = _known_model(s.get("model_id"), "image")
        req = GenerateImageRequest(prompt=s["prompt"], model_id=model_id, **_image_size(p, params),
                                   **{k: v for k, v in params.items() if k in ("seed", "steps", "cfg",
                                                                               "negative_prompt",
                                                                               "reference_asset_ids", "loras")})
        return "txt2img", req.model_dump()
    model_id = _known_model(s.get("model_id"), "video")
    fps = 24 if (model_id or "").startswith("ltx") else 16
    step = 8 if (model_id or "").startswith("ltx") else 4
    frames = max(9, int(round(secs * fps / step)) * step + 1)
    extra = {k: v for k, v in params.items() if k in ("seed", "steps", "cfg", "negative_prompt", "loras",
                                                      "end_image_asset_id", "quality", "motion_speed")}
    entry = registry.get_entry(model_id) if model_id else None
    if entry and entry.get("family") == "ltx25" and "quality" not in extra:
        # HQ 1080p (Nutzer 26.10.2026): „Höchste Qualität (DFR)“, wenn das Detail-IC-LoRA da ist und kein Endbild
        # verlangt ist (gemessen 5 s 1080p: Details bleiben über die ganze Länge, 786 statt 241 s)
        wants = p["settings"].get("video_quality", "dfr")
        dfr = wants == "dfr" and registry.features_for(entry).get("dfr") and not extra.get("end_image_asset_id")
        extra["quality"] = "dfr" if dfr else "standard"
    image_id = params.get("image_asset_id")
    if s.get("chain_from"):
        source = _find(p["scenes"], s["chain_from"], t("Szene", "scene"))
        if not source.get("take"):
            raise StudioError(t("Für den Anschluss braucht die vorherige Szene erst ein Video.",
                                "For the chain, the previous scene needs a video first."))
        image_id = _last_frame_asset(source["take"], source.get("title") or "")
    req = GenerateVideoRequest(prompt=s["prompt"], model_id=model_id, frames=frames, fps=fps,
                               image_asset_id=image_id, **_video_size(model_id, p, params), **extra)
    return "txt2video", req.model_dump()


def _resolve_chain_markers(p: dict[str, Any]) -> None:
    """Anschluss-Marker: Die Videoszene, die am Marker (± eine halbe Sekunde) beginnt, startet mit dem letzten Bild
    der Videoszene davor, wenn sie nicht schon eine eigene Vorlage hat."""
    half = ticks(0.5)
    video = [s for s in p["scenes"] if s["lane"] == "video"]
    for m in p["markers"]:
        if m["kind"] != "chain":
            continue
        after = next((s for s in video if abs(s["start"] - m["at"]) <= half), None)
        before = [s for s in video if s["start"] + s["duration"] <= m["at"] + half and s is not after]
        if after is not None and before and not after.get("chain_from") and after["kind"] == "video":
            after["chain_from"] = max(before, key=lambda s: s["start"])["id"]
            after["chain_marker"] = m["id"]  # nur abgeleitet, wird nicht gespeichert


def _busy(s: dict[str, Any]) -> bool:
    return bool(s.get("jobs") or s.get("waiting_for"))


KIND_ORDER = {"audio": 0, "image": 1, "video": 2}


def _job_kind(s: dict[str, Any]) -> str:
    if s["lane"] != "video":
        return "audio"
    return "image" if s["kind"] == "image" else "video"


def _model_of(s: dict[str, Any]) -> str:
    return s.get("model_id") or registry.get_active_model(_job_kind(s)) or ""


async def generate(pid: str, scene_ids: list[str] | None = None) -> dict[str, Any]:
    """Aufträge für die Szenen abschicken (alle ohne Take, wenn keine genannt sind). Fehler je Szene, kein Abbruch.
    Eine Anschluss-Szene, deren Vorlage gerade erst entsteht, wartet darauf und wird danach abgeschickt."""
    p = await asyncio.to_thread(refresh, pid)
    _resolve_chain_markers(p)
    wanted = [s for s in p["scenes"] if not s.get("waiting_for")
              and (s["id"] in scene_ids if scene_ids else not s.get("take") and not s.get("jobs"))]
    # Reihenfolge in der GPU-Schlange: Ton und Bilder zuerst (kurz, schnelle Rückmeldung), dann Videos nach Modell,
    # Anschluss-Szenen zuletzt. So folgt ein Anschluss direkt auf seine Vorlage, ohne dass das Videomodell
    # dazwischen für ein Bild- oder Tonmodell entladen wird.
    wanted.sort(key=lambda s: (bool(s.get("chain_from")), KIND_ORDER.get(_job_kind(s), 9), _model_of(s), s["start"]))
    by_id = {s["id"]: s for s in p["scenes"]}
    submitted: dict[str, str] = {}
    waiting: dict[str, str] = {}
    errors: dict[str, str] = {}
    for s in wanted:
        source = by_id.get(s.get("chain_from") or "")
        if source is not None and (source["id"] in submitted or source["id"] in waiting or _busy(source)):
            waiting[s["id"]] = source["id"]
            continue
        try:
            kind, params = await asyncio.to_thread(_job_request, p, s)
            job = await jobs.submit(kind, params)
            submitted[s["id"]] = job.id
        except Exception as exc:  # noqa: BLE001 - Fehler gehört an die Szene
            errors[s["id"]] = str(exc)
    with _lock:
        p = load(pid)
        for s in p["scenes"]:
            if s["id"] in submitted:
                s.setdefault("jobs", []).append(submitted[s["id"]])
                s["error"] = None
            elif s["id"] in waiting:
                s["waiting_for"] = waiting[s["id"]]
                s["error"] = None
                # Unter der Sperre anlegen: ein refresh aus einem anderen Thread hielte die Szene sonst für verwaist
                _chain_tasks[s["id"]] = asyncio.create_task(_chain_later(pid, s["id"], waiting[s["id"]]),
                                                            name=f"nvai-studio-chain-{s['id']}")
            elif s["id"] in errors:
                s["error"] = errors[s["id"]]
        p["updated_at"] = time.time()
        _save(p)
    return {"jobs": submitted, "waiting": waiting, "errors": errors}


async def _chain_later(pid: str, scene_id: str, source_id: str) -> None:
    """Wartet, bis die Vorlage einer Anschluss-Szene fertig ist, und schickt dann deren Auftrag ab. Endet still, wenn
    Szene oder Projekt gelöscht oder umgestellt wurden."""
    try:
        while True:
            await asyncio.sleep(CHAIN_POLL_SECONDS)
            try:
                p = await asyncio.to_thread(refresh, pid)
            except NotFound:
                return
            by_id = {s["id"]: s for s in p["scenes"]}
            s, source = by_id.get(scene_id), by_id.get(source_id)
            if s is None or s.get("waiting_for") != source_id:
                return
            if source is not None and _busy(source):
                continue
            job_id, error = None, None
            if source is None or source.get("error") or not source.get("take"):
                error = t("Die Szene, an die diese anschließt, ist fehlgeschlagen.",
                          "The scene this one continues from failed.")
            else:
                s["chain_from"] = source_id  # auch wenn der Anschluss nur aus einem Marker kam
                try:
                    kind, params = await asyncio.to_thread(_job_request, p, s)
                    job_id = (await jobs.submit(kind, params)).id
                except Exception as exc:  # noqa: BLE001 - Fehler gehört an die Szene
                    error = str(exc)
            with _lock:
                p = load(pid)
                s = next((x for x in p["scenes"] if x["id"] == scene_id), None)
                if s is None:
                    return
                s.pop("waiting_for", None)
                if job_id:
                    s.setdefault("jobs", []).append(job_id)
                    s["error"] = None
                else:
                    s["error"] = error
                p["updated_at"] = time.time()
                _save(p)
            return
    finally:
        if _chain_tasks.get(scene_id) is asyncio.current_task():
            _chain_tasks.pop(scene_id, None)


# --------------------------------------------------------------------------------------------- Export

PRESETS: dict[str, dict[str, Any]] = {
    # 24 Mbit/s: gemessen 42,8 dB PSNR gegen den Master (12 Mbit/s: 42,3, 40: 43,0), die Grenze von 4:2:0 liegt
    # bei 43,9 dB; mehr Bitrate kauft kaum noch etwas
    "youtube-1080p": {"label": ("YouTube 1080p (H.264)", "YouTube 1080p (H.264)"), "codec": "h264",
                      "width": 1920, "height": 1080, "bitrate": 24_000_000},
    "youtube-2160p": {"label": ("YouTube 4K (H.265)", "YouTube 4K (H.265)"), "codec": "hevc",
                      "width": 3840, "height": 2160, "bitrate": 40_000_000},
    "shorts-1080x1920": {"label": ("Hochformat 1080 × 1920 (Shorts)", "Vertical 1080 × 1920 (Shorts)"),
                         "codec": "h264", "width": 1080, "height": 1920, "bitrate": 10_000_000},
    "project": {"label": ("Projektformat (H.264)", "Project format (H.264)"), "codec": "h264", "bitrate": None},
    "av1-1080p": {"label": ("AV1 1080p (klein)", "AV1 1080p (small)"), "codec": "av1", "width": 1920,
                  "height": 1080, "bitrate": 6_000_000},
    # Ohne Qualitätsverlust weiterverarbeiten: FFV1 ist verlustfrei (Ton als Float-PCM), ProRes 4444 liest jedes
    # Schnittprogramm (Ton 24 Bit). Beide spielt kein Browser ab: Sie sind zum Herunterladen.
    "master": {"label": ("Master verlustfrei (MKV, FFV1)", "Lossless master (MKV, FFV1)"), "codec": "ffv1",
               "bitrate": None, "ext": "mkv"},
    "prores": {"label": ("ProRes 4444 (MOV, für Schnittprogramme)", "ProRes 4444 (MOV, for editing software)"),
               "codec": "prores", "bitrate": None, "ext": "mov"},
}


def presets() -> list[dict[str, Any]]:
    return [{"id": k, "label": t(*v["label"]), "codec": v["codec"], "ext": v.get("ext", "mp4")}
            for k, v in PRESETS.items()]


def render_plan(p: dict[str, Any], preset: str) -> dict[str, Any]:
    """Was studio_render.py braucht: Dateipfade, Clips in Sekunden, Ausgabeformat."""
    if preset not in PRESETS:
        raise StudioError(t(f"Unbekannte Vorlage: {preset}", f"Unknown preset: {preset}"))
    if not p["clips"]:
        raise StudioError(t("Der Schnitt ist leer: erst Szenen übernehmen oder Clips anlegen.",
                            "The edit is empty: conform scenes or add clips first."))
    pr = PRESETS[preset]
    s = p["settings"]
    clips = []
    for c in p["clips"]:
        path = _source_path(c["asset_id"])
        media = _media(p, c["asset_id"])
        clips.append({"track": c["track"], "path": str(path), "media": media["kind"], "audio": media.get("audio", False),
                      "start": seconds(c["start"]), "in": seconds(c["in"]), "out": seconds(c["out"]),
                      "gain_db": c.get("gain_db", 0.0), "muted": c.get("muted", False),
                      "transition": ({"kind": c["transition"]["kind"],
                                      "seconds": seconds(c["transition"]["duration"])} if c.get("transition") else None)})
    lossless_audio = pr["codec"] in ("ffv1", "prores")  # PCM schwingt nicht über wie AAC
    return {"width": pr.get("width") or s["width"], "height": pr.get("height") or s["height"], "fps": s["fps"],
            "sample_rate": s.get("sample_rate", 48000), "codec": pr["codec"], "bitrate": pr["bitrate"],
            "duration": seconds(edit_duration(p)), "tracks": [tr["id"] for tr in p["tracks"]], "clips": clips,
            "loudness": -14.0, "ceiling_db": -1.0 if lossless_audio else -2.5}


# Dateien, die kein Browser abspielt: Sie bekommen eine H.264-Vorschau (meta.preview)
NO_BROWSER = {".mkv", ".mov", ".avi", ".wmv", ".flv", ".mxf", ".mts", ".m2ts", ".ts"}
_previews: set[str] = set()


async def make_preview(asset_id: str) -> None:
    """Vorschau für ein hochgeladenes Video im Hintergrund (kein Auftrag im Verlauf); fertig meldet assets.changed."""
    if asset_id in _previews:
        return
    _previews.add(asset_id)
    try:
        asset = db.get_asset(asset_id)
        if asset is None or (asset.meta or {}).get("preview"):
            return
        src = config.ASSET_DIR / asset.filename
        name = f"{src.stem}.preview.mp4"
        script = Path(__file__).with_name("video_tools.py")
        proc = await asyncio.create_subprocess_exec(
            str(comfy.comfy_python()), "-I", str(script), "preview", str(src), str(config.ASSET_DIR / name),
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        await proc.communicate()
        if proc.returncode == 0 and (config.ASSET_DIR / name).exists():
            await asyncio.to_thread(db.update_asset_meta, asset_id, {"preview": name})
            jobs.publish({"type": "assets.changed"})
    finally:
        _previews.discard(asset_id)


@jobs.register("studio_export")
async def _export(job: Job, ctx: jobs.JobContext) -> list[str]:
    """studio_render.py im ComfyUI-venv (PyAV mit NVENC/AMF/QSV, NumPy); Fortschritt als JSON-Zeilen."""
    pid = job.params["project_id"]
    preset = job.params.get("preset", "youtube-1080p")
    p = await asyncio.to_thread(load, pid)
    plan = await asyncio.to_thread(render_plan, p, preset)
    stem = db.new_id("stx")
    name = f"{stem}.{PRESETS[preset].get('ext', 'mp4')}"
    out = config.ASSET_DIR / name
    # MKV (FFV1) und ProRes spielt kein Browser: dieselben Bilder zusätzlich als H.264-Vorschau
    preview = config.ASSET_DIR / f"{stem}.preview.mp4" if out.suffix.lower() in NO_BROWSER else None
    plan_path = config.DATA_DIR / "studio" / f"{job.id}.plan.json"
    plan_path.write_text(json.dumps(plan), encoding="utf-8")
    script = Path(__file__).with_name("studio_render.py")
    proc = await asyncio.create_subprocess_exec(
        str(comfy.comfy_python()), "-I", str(script), str(plan_path), str(out), *([str(preview)] if preview else []),
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    result: dict[str, Any] = {}
    # stderr nebenher leeren, sonst kann ein voller Puffer den Renderer anhalten
    err_task = asyncio.create_task(proc.stderr.read()) if proc.stderr else None
    try:
        assert proc.stdout is not None
        async for raw in proc.stdout:
            line = raw.decode(errors="replace").strip()
            if not line.startswith("{"):
                continue
            msg = json.loads(line)
            if "progress" in msg:
                ctx.progress(float(msg["progress"]), msg.get("stage", t("rendert", "rendering")))
            if msg.get("done"):
                result = msg
            if ctx.should_stop():
                proc.kill()
                raise asyncio.CancelledError
        err = (await err_task).decode(errors="replace") if err_task else ""
        if await proc.wait() != 0 or not out.exists():
            raise RuntimeError(t(f"Export fehlgeschlagen: {err[-400:]}", f"Export failed: {err[-400:]}"))
    finally:
        if proc.returncode is None:
            proc.kill()
        plan_path.unlink(missing_ok=True)
    meta = {"studio_project": pid, "preset": preset, **result}
    if preview is not None and preview.exists():
        meta["preview"] = preview.name
    asset = db.create_asset(kind="video", filename=name, job_id=job.id, prompt=p["name"], meta=meta)
    return [asset.id]


async def export(pid: str, preset: str) -> Job:
    p = await asyncio.to_thread(load, pid)
    await asyncio.to_thread(render_plan, p, preset)  # Fehler sofort, nicht erst im Auftrag
    return await jobs.submit("studio_export", {"project_id": pid, "preset": preset})


# --------------------------------------------------------------------------------------- Für die API

def view(p: dict[str, Any]) -> dict[str, Any]:
    """Projekt plus abgeleitete Angaben für Oberfläche und MCP."""
    out = copy.deepcopy(p)
    _resolve_chain_markers(out)  # Anschluss aus Markern anzeigen (chain_marker), ohne ihn zu speichern
    for s in out["scenes"]:
        s["status"] = scene_status(s)
    out["tps"] = TICKS_PER_SECOND
    out["edit_duration"] = edit_duration(p)
    out["composition_duration"] = composition_duration(p)
    out["history"] = history(p["id"])
    # Adresse und Art aller verwendeten Assets: Vorschaubilder und Abspielen in der Oberfläche
    used = {a for s in p["scenes"] for a in s["takes"]} | {c["asset_id"] for c in p["clips"]}
    assets = {}
    for asset_id in used:
        asset = db.get_asset(asset_id)
        if asset is not None:
            assets[asset_id] = {"url": asset.url, "kind": p.get("media", {}).get(asset_id, {}).get("kind", asset.kind),
                                "prompt": asset.prompt[:120]}
            if (asset.meta or {}).get("preview"):
                assets[asset_id]["preview"] = f"/files/{asset.meta['preview']}"
    out["assets"] = assets
    for c in out["clips"]:
        c["missing"] = c["asset_id"] not in assets  # Datei gelöscht: Clip rot, Export nennt ihn
    return out


def summary(p: dict[str, Any]) -> dict[str, Any]:
    """Kompakt für MCP: Zeiten in Sekunden, ohne Medien-Cache."""
    p = copy.deepcopy(p)
    _resolve_chain_markers(p)
    return {
        "id": p["id"], "name": p["name"], "settings": p["settings"],
        "scenes": [{"id": s["id"], "lane": s["lane"], "start_s": round(seconds(s["start"]), 3),
                    "duration_s": round(seconds(s["duration"]), 3), "title": s["title"], "prompt": s["prompt"],
                    "kind": s["kind"], "model_id": s.get("model_id"), "chain_from": s.get("chain_from"),
                    "status": scene_status(s), "waiting_for": s.get("waiting_for"), "take": s.get("take"),
                    "takes": len(s["takes"]), "error": s.get("error")} for s in p["scenes"]],
        "markers": [{"id": m["id"], "at_s": round(seconds(m["at"]), 3), "kind": m["kind"], "name": m["name"],
                     "comment": m["comment"], "params": m["params"], "done": m["done"]} for m in p["markers"]],
        "clips": [{"id": c["id"], "track": c["track"], "start_s": round(seconds(c["start"]), 3),
                   "end_s": round(seconds(clip_end(c)), 3), "asset_id": c["asset_id"], "scene_id": c.get("scene_id"),
                   "transition": c.get("transition") and round(seconds(c["transition"]["duration"]), 3)}
                  for c in p["clips"]],
        "duration_s": round(seconds(edit_duration(p)), 3),
    }
