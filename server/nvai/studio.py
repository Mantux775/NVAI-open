"""Studio: Projekte mit zwei Zeitleisten (Nutzer 26.10.2026, Anleitung docs/STUDIO.md).

Komposition: Szenen mit Prompt, Modell und Dauer auf Bahnen (Bild/Video, Sprecher, Musik, Klang), dazu Marker, die
sagen, was wohin soll. Schnitt: die echten Clips auf Spuren (V1 unten, V2 … darueber, A1, A2 …; Spuren lassen sich
hinzufuegen, entfernen, ausblenden und stumm schalten) mit In/Out, Geschwindigkeit, Uebergang und Lautstaerke. Ein
Clip bleibt mit seiner Szene verbunden: Wird sie neu erzeugt, tauscht er beim Uebernehmen sein Material und behaelt
den Schnitt, soweit das neue Material reicht.

Geschwindigkeit wie bei FilmCraft: In/Out bleiben Medienzeit, die Laenge auf der Zeitleiste ist (Out − In) durch die
Geschwindigkeit (clip_length); 0,5 = halb so schnell, doppelt so lang.

Zeit in ganzzahligen Ticks wie bei FilmCraft (254 016 000 000 je Sekunde: teilt jede Bild- und Abtastrate, kein
Rundungsfehler bei 29,97 fps). Befehle nehmen Zeiten in Ticks (`start`, `duration`, `at`, `in`, `out`) oder in
Sekunden (`start_s`, `duration_s`, `at_s` …), wie FilmCraft `time`/`seconds`.

Jede Aenderung ist ein Befehl (`apply`); Oberflaeche, REST und MCP nutzen dieselben. Rueckgaengig/Wiederholen haelt
je Projekt bis zu 100 Staende im Speicher (Sitzungszustand wie bei FilmCraft). Projekte liegen als JSON in
DATA_DIR/studio/, Geloeschtes wandert nach studio/papierkorb/. Ihr Material liegt seit 0.5.15 je Projekt in einem
eigenen Ordner assets/Studio/<Projektname> (siehe „Projektordner“).
"""
from __future__ import annotations

import asyncio
import copy
import json
import os
import re
import subprocess
import shutil
import threading
import time
import traceback
import zipfile
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
MAX_TRACKS = 8  # je Art
# Klassische Übergänge, gerechnet in Vorschau und Export (nichts davon erzeugt die KI): Überblendung, Abblende über
# Schwarz bzw. Weiß, Wischblende von links. Der Ton blendet bei allen über.
TRANSITION_KINDS = ("dissolve", "dip_black", "dip_white", "wipe")
SPEED_MIN, SPEED_MAX = 0.1, 10.0  # 10 bis 1000 %
SCALE_MIN, SCALE_MAX = 0.1, 8.0  # Skalieren (seit 0.5.16): 10 bis 800 %
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


def _replace(tmp: Path, path: Path) -> None:
    """os.replace mit kurzem Wiederholen (db.replace_file). Unter Windows scheitert es mit WinError 5, solange ein
    anderer die Datei offen hat: Gemessen 27.10.2026 im Funktionstest von 0.5.14 las die offene Weboberfläche gerade
    die Projektliste (`list_projects`), als der nächste Befehl das eben angelegte Projekt speicherte (500 statt 200)."""
    db.replace_file(tmp, path)


def _save(p: dict[str, Any]) -> None:
    path = _path(p["id"])
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(p, ensure_ascii=False, indent=1), encoding="utf-8")
    _replace(tmp, path)
    # Die Oberflaeche laedt nach, auch wenn Claude per MCP oder ein fertiger Auftrag das Projekt geaendert hat
    jobs.publish({"type": "studio.changed", "project_id": p["id"], "updated_at": p.get("updated_at")})


def load(pid: str) -> dict[str, Any]:
    path = _path(pid)
    if not path.exists():
        raise NotFound(t(f"Unbekanntes Projekt: {pid}", f"Unknown project: {pid}"))
    return json.loads(path.read_text(encoding="utf-8"))


def _read_project(f: Path) -> dict[str, Any] | None:
    """Eine Projektdatei, oder None. Neben den Projekten liegt während eines Exports dessen Plan (<job>.plan.json):
    Vor 0.5.15 brach die Projektliste daran mit KeyError ab."""
    try:
        p = json.loads(f.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return p if isinstance(p, dict) and p.get("id") and isinstance(p.get("scenes"), list) else None


def _all_projects() -> list[dict[str, Any]]:
    return [p for f in _dir().glob("*.json") if (p := _read_project(f)) is not None]


def list_projects() -> list[dict[str, Any]]:
    out = []
    for f in sorted(_dir().glob("*.json"), key=lambda f: f.stat().st_mtime, reverse=True):
        p = _read_project(f)
        if p is None:
            continue
        out.append({"id": p["id"], "name": p["name"], "updated_at": p.get("updated_at"),
                    "scenes": len(p.get("scenes", [])), "clips": len(p.get("clips", [])),
                    "duration_s": round(seconds(edit_duration(p)), 2), "folder": p.get("folder")})
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
        project_folder(p)
        _save(p)
    return p


def delete(pid: str) -> None:
    """In den Papierkorb des Studios, nicht endgueltig. Der Projektordner bleibt samt Material (im Material dann ohne
    Projekt); ist er leer, verschwindet er."""
    path = _path(pid)
    if not path.exists():
        raise NotFound(t(f"Unbekanntes Projekt: {pid}", f"Unknown project: {pid}"))
    trash = _dir() / "papierkorb"
    trash.mkdir(exist_ok=True)
    folder = (_read_project(path) or {}).get("folder")
    with _lock:
        _replace(path, trash / f"{pid}-{int(time.time())}.json")
        _undo.pop(pid, None)
        _redo.pop(pid, None)
        target = db.asset_file(folder) if folder and not db.folder_counts().get(folder) else None
        if target is not None:
            try:
                target.rmdir()  # nur ein wirklich leerer Ordner
            except OSError:
                pass


# ------------------------------------------------------------------------------ Projektordner (seit 0.5.15)
#
# Nutzer 27.10.2026: „jedes Projekt in Studio soll einen eigenen Unterordner für seine Assets bekommen, sonst wird es
# sehr unübersichtlich. Es ist egal, wenn die dann nicht im Verlauf erscheinen.“ Echte Ordner unter
# assets/Studio/<Projektname>; Umbenennen nimmt den Ordner mit. Was das Studio für ein Projekt erzeugt (Takes),
# exportiert, als letztes Bild für einen Anschluss ablegt oder was im Projektordner hochgeladen wird, landet dort; der
# Verlauf zeigt es mit dem Ordnernamen (später gewünscht: „dann soll Verlauf auch die Unterordner von Studio
# miteinbeziehen“), und Erzeugtes mit project_id kommt ebenfalls hinein. Beim ersten Start mit Ordnern (migrate_folders) wandert, was nur ein Projekt nutzt,
# hinein; was mehrere Projekte nutzen oder ein Auftrag im Verlauf als Vorlage braucht, bleibt.

FOLDER_ROOT = "Studio"
_RESERVED = {"CON", "PRN", "AUX", "NUL", *(f"COM{i}" for i in range(1, 10)), *(f"LPT{i}" for i in range(1, 10))}
# Projekte, deren Ordner noch den alten Namen trägt (Windows gab ihn beim Umbenennen nicht frei, etwa während eines
# Exports): Projekt-ID -> Zeit des letzten Versuchs; refresh versucht es wieder
_rename_later: dict[str, float] = {}
RENAME_RETRY_SECONDS = 30.0
# Asset-IDs in den Parametern eines Auftrags (ast_…, auch Uploads und Importiertes)
ASSET_ID = re.compile(r"\b[a-z]{2,5}_[0-9a-f]{12}\b")


def _folder_label(name: str) -> str:
    """Ordnername aus dem Projektnamen: ohne Zeichen, die Windows nicht erlaubt, höchstens 60 Zeichen."""
    label = re.sub(r'[<>:"/\\|?*\x00-\x1f]+', "_", name).strip().rstrip(". ")[:60].rstrip(". ") or "Projekt"
    if label.split(".")[0].upper() in _RESERVED:
        label += "_"
    return label


def _known_folders(projects: list[dict[str, Any]] | None = None) -> set[str]:
    """Belegte Projektordner: auf der Platte, in der Datenbank und in den Projekten."""
    root = config.ASSET_DIR / FOLDER_ROOT
    found = {f"{FOLDER_ROOT}/{d.name}" for d in root.iterdir() if d.is_dir()} if root.is_dir() else set()
    found |= {f for f in db.folder_counts() if f.startswith(FOLDER_ROOT + "/") and f.count("/") == 1}
    found |= {p["folder"] for p in (projects if projects is not None else _all_projects()) if p.get("folder")}
    return found


def _free_folder(label: str, current: str | None = None) -> str:
    """Ein Ordner unter Studio/, den noch kein anderes Projekt hat (Windows unterscheidet keine Groß- und
    Kleinschreibung): „Name“, sonst „Name (2)“ …"""
    taken = {f.casefold() for f in _known_folders() if f != current}
    for n in range(1, 10_000):
        candidate = f"{FOLDER_ROOT}/{label}" + (f" ({n})" if n > 1 else "")
        if candidate.casefold() not in taken:
            return candidate
    raise StudioError(t("Kein freier Ordnername.", "No free folder name."))


def project_folder(p: dict[str, Any]) -> str:
    """Der Ordner des Projekts relativ zum Asset-Ordner (Studio/<Name>), angelegt, wenn er fehlt. Einen neu vergebenen
    Namen trägt die Funktion in p ein; speichern muss der Aufrufer."""
    if not p.get("folder"):
        p["folder"] = _free_folder(_folder_label(p["name"]))
    path = db.asset_file(p["folder"])
    if path is not None:
        path.mkdir(parents=True, exist_ok=True)
    return p["folder"]


def _follow_name(p: dict[str, Any]) -> None:
    """Den Ordner nach dem Projektnamen umbenennen. Gibt Windows ihn nicht frei (eine Datei darin ist gerade offen,
    etwa beim Export), bleibt der alte Name, und refresh versucht es später wieder."""
    current = project_folder(p)
    wanted = _free_folder(_folder_label(p["name"]), current)
    if wanted != current:
        try:
            db.rename_folder(current, wanted)
        except OSError:
            _rename_later[p["id"]] = time.time()
            return
        p["folder"] = wanted
    _rename_later.pop(p["id"], None)


def folder_list() -> list[dict[str, Any]]:
    """Die Projektordner fürs Material, nach Namen: auch leere und die gelöschter Projekte (dann ohne Projekt)."""
    projects = _all_projects()
    by_folder = {p["folder"]: p for p in projects if p.get("folder")}
    counts = db.folder_counts()
    out = []
    for folder in sorted(_known_folders(projects), key=str.casefold):
        p = by_folder.get(folder)
        items, last = counts.get(folder, (0, None))
        if p is None and not items:
            continue  # leer und ohne Projekt
        out.append({"path": folder, "name": folder.split("/", 1)[1], "items": items, "updated_at": last,
                    "project_id": p["id"] if p else None, "project_name": p["name"] if p else None})
    return out


def used_asset_ids() -> set[str]:
    """Alles, was ein Studio-Projekt benutzt (Clips, Takes, Vorlagen): Den Verlauf zu leeren löscht es nicht mit."""
    return {a for p in _all_projects() for a in _used_assets(p)}


def _place_job_assets(job: Job, asset_ids: list[str]) -> None:
    """Haken für jobs.place_assets, bevor job.done rausgeht: Was ein Auftrag des Studios erzeugt hat (Takes,
    Exporte), liegt danach im Projektordner. Unter der Sperre, damit kein Umbenennen dazwischenkommt."""
    pid = (job.params or {}).get("studio_project")
    if not pid:
        return
    with _lock:
        try:
            p = load(pid)
        except NotFound:
            return  # Projekt inzwischen gelöscht: bleibt im Verlauf
        if not p.get("folder"):
            project_folder(p)
            _save(p)
        folder = project_folder(p)
        for asset_id in asset_ids:
            try:
                db.move_asset(asset_id, folder)
            except (OSError, ValueError):
                traceback.print_exc()  # bleibt im Verlauf


jobs.place_assets = _place_job_assets


def migration_plan(projects: list[dict[str, Any]]) -> dict[str, list[str]]:
    """Was der Umzug in die Projektordner verschieben würde: je Projekt-ID die Asset-IDs, die nur dieses Projekt nutzt
    (auch die Vorlagen seiner Aufträge, Exporte, letzte Bilder), ohne was ein Auftrag im Verlauf als Vorlage braucht
    und ohne was schon in einem Ordner liegt. Liest nur die Datenbank."""
    assets = {a.id: a for a in db.list_assets(limit=10_000_000)}
    refs: dict[str, set[str]] = {}

    def ref(asset_id: str, pids: set[str]) -> None:
        refs.setdefault(asset_id, set()).update(pids)

    for p in projects:  # Clips, Takes, Start- und Endbilder, vorgegebener Ton, Referenzen
        for asset_id in _used_assets(p):
            ref(asset_id, {p["id"]})
    # Aufträge des Studios: neue tragen studio_project, ältere erkennt man an ihren Takes. Ihre Vorlagen (etwa das
    # letzte Bild der Szene davor) gehören zum Projekt; was ein Auftrag im Verlauf braucht, bleibt im Verlauf.
    takes = {a for p in projects for s in p["scenes"] for a in s.get("takes") or []}
    studio_jobs = {assets[a].job_id for a in takes if a in assets and assets[a].job_id}
    history_needs: set[str] = set()
    for job in db.list_jobs(limit=10_000_000):
        if job.kind == "download":
            continue
        found = set(ASSET_ID.findall(json.dumps(job.params))) - set(job.asset_ids)
        if job.id in studio_jobs or job.params.get("studio_project") or job.kind == "studio_export":
            owners = set().union(*(refs.get(a, set()) for a in job.asset_ids))
            for asset_id in found:
                ref(asset_id, owners)
        else:
            history_needs |= found
    for a in assets.values():
        meta = a.meta or {}
        if meta.get("studio_project"):  # Export
            ref(a.id, {meta["studio_project"]})
        if meta.get("studio_last_frame_of"):  # letztes Bild für einen Anschluss, auch wenn der Auftrag scheiterte
            ref(a.id, refs.get(meta["studio_last_frame_of"], set()))
    plan: dict[str, list[str]] = {p["id"]: [] for p in projects}
    for asset_id, owners in refs.items():
        a = assets.get(asset_id)
        if len(owners) != 1 or asset_id in history_needs or a is None or a.folder \
                or a.kind not in ("image", "video", "audio", "upload"):
            continue
        (owner,) = owners
        if owner in plan:
            plan[owner].append(asset_id)
    return plan


def migrate_folders() -> dict[str, int]:
    """Beim Start: Projekte von vor 0.5.15 bekommen ihren Ordner, und was nur sie nutzen, wandert hinein (Nutzer
    27.10.2026: „Hineinverschieben“, migration_plan). Es bleibt, wo es ist: was mehrere Projekte nutzen, was ein
    Auftrag im Verlauf als Vorlage braucht (Startbild, Referenz …) und was schon in einem Ordner liegt. Gibt je Projekt
    die Zahl der verschobenen Assets zurück."""
    projects = _all_projects()
    todo = [p for p in projects if not p.get("folder")]
    if not todo:
        return {}
    plan = migration_plan(projects)
    moved: dict[str, int] = {}
    for old in todo:
        path = _path(old["id"])
        with _lock:
            p = _read_project(path)
            if p is None or p.get("folder"):
                continue
            folder = project_folder(p)
            count = 0
            for asset_id in plan.get(p["id"], []):
                try:
                    db.move_asset(asset_id, folder)
                    count += 1
                except (OSError, ValueError):
                    continue  # unter Windows gerade offen oder die Datei fehlt: bleibt im Verlauf
            mtime = path.stat().st_mtime
            _save(p)
            os.utime(path, (mtime, mtime))  # die Projektliste sortiert nach Änderung: Reihenfolge behalten
            moved[p["name"]] = count
    return moved


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


def clip_speed(c: dict[str, Any]) -> float:
    return float(c.get("speed") or 1.0)  # Projekte vor der Geschwindigkeit kennen das Feld nicht


def clip_length(c: dict[str, Any]) -> int:
    """Länge auf der Zeitleiste: Material (Out − In) durch die Geschwindigkeit."""
    return int(round((c["out"] - c["in"]) / clip_speed(c)))


def clip_end(c: dict[str, Any]) -> int:
    return c["start"] + clip_length(c)


def _media_at(c: dict[str, Any], offset: int) -> int:
    """Medienzeit, die `offset` Ticks nach dem Clipanfang auf der Zeitleiste läuft."""
    return c["in"] + int(round(offset * clip_speed(c)))


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
        _keep_folder(p, current)
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
        _keep_folder(p, current)
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


def _keep_folder(restored: dict[str, Any], current: dict[str, Any]) -> None:
    """Der Ordner ist kein Befehl: Er liegt auf der Platte, wie ihn der letzte Stand benannt hat, und folgt dann dem
    zurückgeholten Namen."""
    if current.get("folder"):
        restored["folder"] = current["folder"]
    _follow_name(restored)


def history(pid: str) -> dict[str, int]:
    return {"undo": len(_undo.get(pid) or []), "redo": len(_redo.get(pid) or [])}


@command("project.update", "Name oder Einstellungen: name, width, height, fps [num, den], video_quality (dfr|standard)")
def _project_update(p: dict[str, Any], a: dict[str, Any]) -> None:
    if "name" in a:
        p["name"] = str(a["name"]).strip() or p["name"]
        _follow_name(p)
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


@command("batch", "Mehrere Befehle als ein Schritt (ein Rückgängig), etwa beim Einfügen mehrerer Clips: commands "
         "[{command, params}]; scheitert einer, bleibt alles beim Alten")
def _batch(p: dict[str, Any], a: dict[str, Any]) -> dict[str, list[Any]]:
    results = []
    for item in a.get("commands") or []:
        name = str(item.get("command", ""))
        if name == "batch" or name not in COMMANDS:
            raise StudioError(t(f"Unbekannter Befehl im Stapel: {name}", f"Unknown command in the batch: {name}"))
        results.append(COMMANDS[name](p, dict(item.get("params") or {})))
    return {"results": results}


@command("scene.add", "Szene anlegen: lane (video|voice|music|sfx), prompt, title, kind (video|image|audio), "
         "model_id, start/start_s (sonst hinten an der Bahn), duration/duration_s (Vorgabe 5 s), params; takes und "
         "take übernehmen vorhandenes Material (Einfügen einer kopierten Szene)")
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
    takes = [str(x) for x in a.get("takes") or []]  # beim Einfügen einer kopierten Szene
    for asset_id in takes:
        _media(p, asset_id)
    take = a.get("take") if a.get("take") in takes else (takes[-1] if takes else None)
    scene = {"id": db.new_id("sc"), "lane": lane, "start": max(0, start), "duration": duration,
             "title": str(a.get("title", "")), "prompt": str(a.get("prompt", "")), "kind": kind,
             "model_id": a.get("model_id"), "lyrics": str(a.get("lyrics", "")), "params": dict(a.get("params") or {}),
             "chain_from": a.get("chain_from"), "takes": takes, "take": take, "jobs": [], "error": None}
    p["scenes"].append(scene)
    p["scenes"].sort(key=lambda s: (LANES.index(s["lane"]), s["start"]))
    return {"id": scene["id"]}


@command("scene.update", "Felder ändern: id und title, prompt, kind, model_id, lane, chain_from, params "
         "(wird zusammengeführt, z. B. image_asset_id, quality, seed), start/start_s, duration/duration_s")
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
    _apply_transition_marker(p, marker)
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
    if any(k in a for k in ("at", "at_s", "duration", "duration_s", "kind", "params")):
        _apply_transition_marker(p, m)


@command("marker.delete", "Marker löschen: id. Eine Überblendung, die er gesetzt hat, bleibt am Clip")
def _marker_delete(p: dict[str, Any], a: dict[str, Any]) -> None:
    m = _find(p["markers"], a.get("id", ""), t("Marker", "marker"))
    p["markers"].remove(m)
    for c in p["clips"]:
        if (c.get("transition") or {}).get("marker") == m["id"]:
            c["transition"].pop("marker")


def _apply_transition_marker(p: dict[str, Any], m: dict[str, Any]) -> bool:
    """Übergang-Marker wirken sofort (Nutzer 27.10.2026: „Überblendungen wirken sofort, wenn ich sie anlege“): auf
    den Videoclip, der am Marker (± eine halbe Sekunde) beginnt, untere Spur zuerst. Wandert der Marker oder ändert
    er Art oder Dauer, wandert die Überblendung mit; liegt dort noch kein Clip, setzt sie das Übernehmen."""
    for c in p["clips"]:
        if (c.get("transition") or {}).get("marker") == m["id"]:
            c["transition"] = None
    if m["kind"] != "transition":
        return False
    duration = m["duration"] or ticks(float(m["params"].get("seconds", 0.5)))
    kind = m["params"].get("transition") or "dissolve"
    half = ticks(0.5)
    video = [c for c in p["clips"] if _track(p, c["track"])["kind"] == "video"]
    for c in sorted(video, key=lambda c: (_track_number(c["track"]), c["start"])):
        if abs(c["start"] - m["at"]) <= half and c["start"] > 0:
            c["transition"] = {**_transition(p, c, {"kind": kind if kind in TRANSITION_KINDS else "dissolve",
                                                    "duration": duration}), "marker": m["id"]}
            return True
    return False


# ------------------------------------------------------------------------------------------- Schnitt

def _track(p: dict[str, Any], track_id: str) -> dict[str, Any]:
    for tr in p["tracks"]:
        if tr["id"] == track_id:
            return tr
    raise StudioError(t(f"Spur {track_id} gibt es nicht.", f"No track {track_id}."))


def _tracks_of(p: dict[str, Any], kind: str) -> list[dict[str, Any]]:
    return [tr for tr in p["tracks"] if tr["kind"] == kind]


def _track_number(track_id: str) -> int:
    return int(track_id[1:])


def _track_or_highest(p: dict[str, Any], wanted: str | None, kind: str) -> str:
    """Die gewünschte Spur, wenn es sie gibt, sonst die mit der höchsten Nummer dieser Art (A2 entfernt → A1)."""
    ids = [tr["id"] for tr in _tracks_of(p, kind)]
    return wanted if wanted in ids else max(ids, key=_track_number)


def _order_tracks(p: dict[str, Any]) -> None:
    """Videospuren von oben nach unten (V3, V2, V1), darunter die Tonspuren (A1, A2 …), wie in der Ansicht."""
    p["tracks"] = (sorted(_tracks_of(p, "video"), key=lambda tr: -_track_number(tr["id"]))
                   + sorted(_tracks_of(p, "audio"), key=lambda tr: _track_number(tr["id"])))


def _renumber(p: dict[str, Any], kind: str) -> None:
    """Spuren einer Art lückenlos nummerieren (V1 bleibt unten); Clips und Platzieren-Marker ziehen mit."""
    prefix = "V" if kind == "video" else "A"
    ordered = sorted(_tracks_of(p, kind), key=lambda tr: _track_number(tr["id"]))
    mapping = {tr["id"]: f"{prefix}{i + 1}" for i, tr in enumerate(ordered)}
    for tr in ordered:
        tr["id"] = mapping[tr["id"]]
    for c in p["clips"]:
        c["track"] = mapping.get(c["track"], c["track"])
    for m in p["markers"]:
        if m["params"].get("track") in mapping:
            m["params"]["track"] = mapping[m["params"]["track"]]


@command("track.add", "Spur hinzufügen: kind (video|audio). Eine neue Videospur kommt oben dazu (V3 über V2), eine "
         "Tonspur unten (A3 unter A2)")
def _track_add(p: dict[str, Any], a: dict[str, Any]) -> dict[str, str]:
    kind = a.get("kind", "video")
    if kind not in ("video", "audio"):
        raise StudioError(t("kind ist video oder audio.", "kind is video or audio."))
    have = _tracks_of(p, kind)
    if len(have) >= MAX_TRACKS:
        raise StudioError(t(f"Höchstens {MAX_TRACKS} Spuren je Art.", f"At most {MAX_TRACKS} tracks of each kind."))
    track = {"id": f"{'V' if kind == 'video' else 'A'}{len(have) + 1}", "kind": kind, "hidden": False, "muted": False}
    p["tracks"].append(track)
    _order_tracks(p)
    return {"id": track["id"]}


@command("track.delete", "Spur entfernen: id. Ihre Clips gehen mit (Rückgängig holt beides zurück); V1 und A1 "
         "bleiben immer (wie bei FilmCraft). Die Spuren darüber bzw. darunter rücken nach (V3 wird V2)")
def _track_delete(p: dict[str, Any], a: dict[str, Any]) -> dict[str, int]:
    tr = _track(p, a.get("id", ""))
    if _track_number(tr["id"]) == 1:
        raise StudioError(t("V1 und A1 bleiben immer.", "V1 and A1 always stay."))
    before = len(p["clips"])
    p["clips"] = [c for c in p["clips"] if c["track"] != tr["id"]]
    for m in p["markers"]:
        if m["params"].get("track") == tr["id"]:
            m["params"].pop("track")  # Platzieren-Marker fällt auf die oberste Spur zurück
    p["tracks"].remove(tr)
    _renumber(p, tr["kind"])
    _order_tracks(p)
    return {"clips_removed": before - len(p["clips"])}


@command("track.update", "Spur schalten: id, hidden (Bild der Videospur aus), muted (Ton der Spur aus, bei Videospuren "
         "der Ton ihrer Clips). Gilt für Vorschau und Export")
def _track_update(p: dict[str, Any], a: dict[str, Any]) -> None:
    tr = _track(p, a.get("id", ""))
    if "hidden" in a and tr["kind"] == "video":
        tr["hidden"] = bool(a["hidden"])
    if "muted" in a:
        tr["muted"] = bool(a["muted"])


def _overwrite(p: dict[str, Any], clip: dict[str, Any], keep_ids: set[str] | frozenset[str] = frozenset()) -> None:
    """Wie „Überschreiben“ in jedem Schnittprogramm: Was auf derselben Spur unter dem Clip liegt, wird gekürzt,
    geteilt oder entfernt. `keep_ids`: Clips, die mitverschoben werden und sich deshalb nicht gegenseitig kürzen."""
    s, e = clip["start"], clip_end(clip)
    keep = []
    for c in p["clips"]:
        if (c is clip or c["id"] in keep_ids or c["track"] != clip["track"] or clip_end(c) <= s
                or c["start"] >= e):
            keep.append(c)
            continue
        if c["start"] >= s and clip_end(c) <= e:
            continue  # ganz verdeckt
        if c["start"] < s and clip_end(c) > e:  # teilen
            tail = copy.deepcopy(c)
            tail["id"] = db.new_id("cl")
            tail["in"] = _media_at(c, e - c["start"])
            tail["start"] = e
            tail["transition"] = None
            c["out"] = _media_at(c, s - c["start"])
            keep += [c, tail]
        elif c["start"] < s:  # Ende kürzen
            c["out"] = _media_at(c, s - c["start"])
            keep.append(c)
        else:  # Anfang kürzen
            c["in"] = _media_at(c, e - c["start"])
            c["start"] = e
            c["transition"] = None
            keep.append(c)
    p["clips"] = keep
    p["clips"].sort(key=lambda c: (c["track"], c["start"]))


def _check_speed(value: Any) -> float:
    try:
        speed = float(value)
    except (TypeError, ValueError):
        raise StudioError(t("speed ist eine Zahl (1.0 = 100 %).", "speed is a number (1.0 = 100 %).")) from None
    if not SPEED_MIN <= speed <= SPEED_MAX:
        raise StudioError(t(f"Geschwindigkeit {SPEED_MIN * 100:.0f} bis {SPEED_MAX * 100:.0f} %.",
                            f"Speed {SPEED_MIN * 100:.0f} to {SPEED_MAX * 100:.0f} %."))
    return speed


# ------------------------------------------------------------------------------------------ Skalieren
# Seit 0.5.16 (Nutzer 29.10.2026: „Studio braucht ‚scale‘ tool. und keypoints um scale animation zu setzen“). Ein Clip
# hat eine Skalierung (1.0 = 100 %), einen Fokuspunkt (anchor, 0 bis 1 je Achse: der Punkt bleibt beim Skalieren an
# seiner Stelle, wie transform-origin im Browser) und wahlweise Keyframes. Die Keyframes hängen an der Medienzeit
# (wie in/out), damit sie beim Schneiden, Trimmen und bei anderem Tempo am Inhalt bleiben; dazwischen linear, davor
# und danach gilt der erste bzw. letzte Wert. Ohne Keyframes gilt `scale`.

def _check_scale(value: Any) -> float:
    try:
        scale = float(value)
    except (TypeError, ValueError):
        raise StudioError(t("scale ist eine Zahl (1.0 = 100 %).", "scale is a number (1.0 = 100 %).")) from None
    if not SCALE_MIN <= scale <= SCALE_MAX:
        raise StudioError(t(f"Skalierung {SCALE_MIN * 100:.0f} bis {SCALE_MAX * 100:.0f} %.",
                            f"Scale {SCALE_MIN * 100:.0f} to {SCALE_MAX * 100:.0f} %."))
    return scale


def _check_anchor(value: Any) -> list[float]:
    try:
        x, y = (float(v) for v in value)
    except (TypeError, ValueError):
        raise StudioError(t("anchor ist [x, y] mit Werten von 0 bis 1 (0.5, 0.5 = Mitte).",
                            "anchor is [x, y] with values from 0 to 1 (0.5, 0.5 = center).")) from None
    return [min(1.0, max(0.0, x)), min(1.0, max(0.0, y))]


def _check_keys(value: Any) -> list[dict[str, Any]]:
    """Keyframes aus einer Liste [{at: Medienzeit in Ticks oder at_s, value}], nach Zeit sortiert, ohne Doppel."""
    if not isinstance(value, list):
        raise StudioError(t("scale_keys ist eine Liste [{at_s, value}].", "scale_keys is a list [{at_s, value}]."))
    keys: dict[int, float] = {}
    for k in value:
        at = _time(k, "at") if isinstance(k, dict) else None
        if at is None:
            raise StudioError(t("Jeder Keyframe braucht at oder at_s (Medienzeit).",
                                "Each keyframe needs at or at_s (media time)."))
        keys[at] = _check_scale(k.get("value"))
    return [{"at": at, "value": keys[at]} for at in sorted(keys)]


def clip_scale_at(c: dict[str, Any], media: int) -> float:
    """Skalierung zur Medienzeit `media` (Ticks): linear zwischen Keyframes, sonst `scale`."""
    keys = c.get("scale_keys") or []
    if not keys:
        return float(c.get("scale") or 1.0)
    if media <= keys[0]["at"]:
        return keys[0]["value"]
    for a, b in zip(keys, keys[1:]):
        if media <= b["at"]:
            f = (media - a["at"]) / max(1, b["at"] - a["at"])
            return a["value"] + (b["value"] - a["value"]) * f
    return keys[-1]["value"]


def _new_clip(p: dict[str, Any], track: str, asset_id: str, start: int, length: int | None = None,
              in_point: int = 0, scene_id: str | None = None, speed: Any = 1.0,
              out_point: int | None = None) -> dict[str, Any]:
    """Neuer Clip; `length` ist die Länge auf der Zeitleiste, `out_point` (statt length) das Ende in Medienzeit."""
    tr = _track(p, track)
    media = _media(p, asset_id)
    if tr["kind"] == "audio" and media["kind"] == "image":
        raise StudioError(t("Ein Bild gehört auf eine Videospur.", "An image belongs on a video track."))
    if tr["kind"] == "video" and media["kind"] == "audio":
        raise StudioError(t("Ton gehört auf eine Tonspur.", "Audio belongs on an audio track."))
    speed = 1.0 if media["kind"] == "image" else _check_speed(speed)
    available = None if media["kind"] == "image" else (media["duration"] or 0) - in_point  # Medienzeit
    if out_point is not None:
        material = out_point - in_point
    elif length is not None:
        material = int(round(length * speed))
    else:
        material = available if available else ticks(DEFAULT_IMAGE_SECONDS)
    if available is not None:
        material = min(material, available)
    if material <= 0:
        raise StudioError(t("Der Clip hätte keine Länge.", "The clip would have no length."))
    return {"id": db.new_id("cl"), "track": track, "asset_id": asset_id, "scene_id": scene_id, "start": max(0, start),
            "in": in_point, "out": in_point + material, "speed": speed, "gain_db": 0.0, "muted": False,
            "transition": None}


def _transition(p: dict[str, Any], c: dict[str, Any], spec: dict[str, Any] | None) -> dict[str, Any] | None:
    """Übergang am Anfang eines Clips: Art und Dauer (höchstens die Länge des Clips, mindestens ein Bild)."""
    if spec is None:
        return None
    kind = spec.get("kind") or "dissolve"
    if kind not in TRANSITION_KINDS:
        raise StudioError(t(f"Übergang {kind} gibt es nicht ({', '.join(TRANSITION_KINDS)}).",
                            f"No transition {kind} ({', '.join(TRANSITION_KINDS)})."))
    duration = _time(spec, "duration", ticks(0.5))
    return {"kind": kind, "duration": max(frame_ticks(p), min(duration, clip_length(c)))}


@command("clip.add", "Clip auf eine Spur legen (überschreibt Darunterliegendes): track (V1, V2 … A1, A2 …), asset_id, "
         "start/start_s, in/in_s, duration/duration_s (Länge auf der Zeitleiste) oder out/out_s (Medienzeit); "
         "wahlweise speed, gain_db, muted, transition, scale, anchor, scale_keys, scene_id (beim Einfügen eines "
         "ausgeschnittenen Clips)")
def _clip_add(p: dict[str, Any], a: dict[str, Any]) -> dict[str, str]:
    clip = _new_clip(p, a.get("track", "V1"), a.get("asset_id", ""), _time(a, "start", edit_duration(p)),
                     _time(a, "duration"), _time(a, "in", 0), speed=a.get("speed", 1.0), out_point=_time(a, "out"))
    if "gain_db" in a:
        clip["gain_db"] = max(-60.0, min(12.0, float(a["gain_db"])))
    if "muted" in a:
        clip["muted"] = bool(a["muted"])
    _apply_scale(p, clip, a)
    if a.get("scene_id") and any(s["id"] == a["scene_id"] for s in p["scenes"]):
        clip["scene_id"] = a["scene_id"]
    if a.get("transition"):
        clip["transition"] = _transition(p, clip, a["transition"])
    p["clips"].append(clip)
    _overwrite(p, clip)
    return {"id": clip["id"]}


@command("clip.move", "Clip verschieben: id mit start/start_s und/oder track, oder mehrere zugleich mit moves "
         "[{id, start/start_s, track}]. Überschreibt am Ziel, die mitverschobenen Clips kürzen sich nicht gegenseitig")
def _clip_move(p: dict[str, Any], a: dict[str, Any]) -> None:
    moves = a.get("moves") or [{k: a[k] for k in ("id", "start", "start_s", "track") if k in a}]
    plan = []
    for mv in moves:  # erst alles prüfen, dann verschieben
        c = _find(p["clips"], mv.get("id", ""), t("Clip", "clip"))
        if mv.get("track"):
            if _track(p, mv["track"])["kind"] != _track(p, c["track"])["kind"]:
                raise StudioError(t("Video bleibt auf Video-, Ton auf Tonspuren.",
                                    "Video stays on video, audio on audio tracks."))
        plan.append((c, _time(mv, "start"), mv.get("track")))
    for c, start, track in plan:
        if start is not None:
            c["start"] = max(0, start)
        if track:
            c["track"] = track
    moved = {c["id"] for c, _, _ in plan}
    for c, _, _ in plan:
        _overwrite(p, c, moved)


@command("clip.trim", "Clip trimmen: id und edge (start|end) mit to/to_s (Zeitleistenposition), oder in/out "
         "(Medienzeit)")
def _clip_trim(p: dict[str, Any], a: dict[str, Any]) -> None:
    c = _find(p["clips"], a.get("id", ""), t("Clip", "clip"))
    media = _media(p, c["asset_id"])
    limit = None if media["kind"] == "image" else media["duration"]
    speed = clip_speed(c)
    to = _time(a, "to")
    if a.get("edge") == "start" and to is not None:
        c["in"] = _media_at(c, to - c["start"])
        c["start"] = to
    elif a.get("edge") == "end" and to is not None:
        c["out"] = _media_at(c, to - c["start"])
    else:
        if _time(a, "in") is not None:
            new_in = _time(a, "in")
            c["start"] += int(round((new_in - c["in"]) / speed))  # das Bild bleibt an seiner Stelle
            c["in"] = new_in
        if _time(a, "out") is not None:
            c["out"] = _time(a, "out")
    if c["in"] < 0:  # nicht vor den Anfang des Materials
        c["start"] -= int(round(c["in"] / speed))
        c["in"] = 0
    if limit is not None and c["out"] > limit:
        c["out"] = limit
    if c["start"] < 0:
        c["in"] -= int(round(c["start"] * speed))
        c["start"] = 0
    if clip_length(c) < frame_ticks(p):
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
            tail["in"] = _media_at(c, at - c["start"])
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
            gap = clip_length(c)
            for other in p["clips"]:
                if other["track"] == c["track"] and other["start"] >= clip_end(c):
                    other["start"] -= gap


def _set_speed(p: dict[str, Any], c: dict[str, Any], value: Any, overlap: str | None) -> None:
    """Neue Geschwindigkeit; In und Out bleiben, die Länge auf der Zeitleiste ändert sich. Wird der Clip länger und
    stößt an einen späteren Clip derselben Spur, entscheidet `overlap` (Nutzer 27.10.2026: „es soll mich warnen,
    wenn es beim Verlängern mit anderen Clips kollidiert“): clamp (endet am nächsten Clip, wie FilmCraft ohne
    Ripple), ripple (schiebt die späteren Clips der Spur nach hinten, wie FilmCraft mit Ripple) oder overwrite
    (überdeckt sie). Ohne Angabe wird abgelehnt und die Meldung nennt die betroffenen Clips; die Oberfläche fragt
    vorher nach."""
    if _media(p, c["asset_id"])["kind"] == "image":
        raise StudioError(t("Ein Standbild hat keine Geschwindigkeit; seine Länge ändert man direkt.",
                            "A still image has no speed; change its length directly."))
    speed = _check_speed(value)
    old_end = clip_end(c)
    c["speed"] = speed
    new_end = clip_end(c)
    if new_end <= old_end:
        return  # kürzer: dahinter entsteht eine Lücke
    later = [o for o in p["clips"] if o is not c and o["track"] == c["track"] and o["start"] >= c["start"]]
    hit = [o for o in later if o["start"] < new_end]
    if not hit:
        return
    if overlap == "clamp":
        c["out"] = _media_at(c, min(o["start"] for o in hit) - c["start"])
        if clip_length(c) < frame_ticks(p):
            raise StudioError(t("Bis zum nächsten Clip ist kein Platz.", "There is no room before the next clip."))
    elif overlap == "overwrite":
        _overwrite(p, c)
    elif overlap == "ripple":
        for o in later:
            o["start"] += new_end - old_end
    else:
        names = ", ".join(_clip_label(p, o) for o in hit[:3])
        raise StudioError(t(
            f"Mit {speed * 100:.0f} % wird der Clip {seconds(new_end - old_end):.2f} s länger und stößt an "
            f"{len(hit)} Clip(s) ({names}). overlap angeben: clamp (endet am nächsten Clip), ripple (die späteren "
            f"Clips der Spur rücken nach hinten) oder overwrite (überdecken).",
            f"At {speed * 100:.0f} % the clip becomes {seconds(new_end - old_end):.2f} s longer and runs into "
            f"{len(hit)} clip(s) ({names}). Give overlap: clamp (end at the next clip), ripple (push the later clips "
            f"of the track) or overwrite (cover them)."))


def _clip_label(p: dict[str, Any], c: dict[str, Any]) -> str:
    scene = next((s for s in p["scenes"] if s["id"] == c.get("scene_id")), None)
    if scene and scene.get("title"):
        return scene["title"]
    asset = db.get_asset(c["asset_id"])
    label = (asset.prompt or asset.meta.get("original_name") or asset.filename) if asset else c["asset_id"]
    return label if len(label) <= 40 else label[:39].rstrip() + "…"


def _apply_scale(p: dict[str, Any], c: dict[str, Any], a: dict[str, Any]) -> None:
    """scale, anchor und scale_keys aus einem Befehl übernehmen (nur Videospuren)."""
    if not any(k in a for k in ("scale", "anchor", "scale_keys")):
        return
    if _track(p, c["track"])["kind"] != "video":
        raise StudioError(t("Skalieren geht nur auf Videospuren.", "Scaling only works on video tracks."))
    if "scale" in a:
        c["scale"] = _check_scale(a["scale"])
    if "anchor" in a:
        c["anchor"] = _check_anchor(a["anchor"])
    if "scale_keys" in a:
        c["scale_keys"] = _check_keys(a["scale_keys"] or [])


@command("clip.update", "Clip ändern: id, gain_db, muted, transition (Übergang am Anfang: {kind: dissolve|dip_black|"
         "dip_white|wipe, duration/duration_s} oder null), speed (0.1 bis 10, 1.0 = 100 %) mit overlap "
         "(clamp|ripple|overwrite), falls der längere Clip an den nächsten stößt; Videospuren auch scale (0.1 bis 8, "
         "1.0 = 100 %, gilt ohne Keyframes), anchor [x, y] (Fokuspunkt 0 bis 1, Vorgabe Mitte) und scale_keys "
         "(alle Keyframes neu: [{at/at_s Medienzeit, value}], [] löscht sie)")
def _clip_update(p: dict[str, Any], a: dict[str, Any]) -> None:
    c = _find(p["clips"], a.get("id", ""), t("Clip", "clip"))
    if "gain_db" in a:
        c["gain_db"] = max(-60.0, min(12.0, float(a["gain_db"])))
    if "muted" in a:
        c["muted"] = bool(a["muted"])
    _apply_scale(p, c, a)
    if "speed" in a:
        _set_speed(p, c, a["speed"], a.get("overlap"))
    if "transition" in a:
        c["transition"] = _transition(p, c, a["transition"])
    elif c.get("transition"):  # die Länge kann sich geändert haben
        c["transition"]["duration"] = min(c["transition"]["duration"], clip_length(c))


@command("clip.key", "Keyframe der Skalierung: id und at/at_s (Position auf der Zeitleiste) mit value (0.1 bis 8, "
         "1.0 = 100 %) setzt oder ersetzt ihn, mit delete=true löscht ihn; clear=true löscht alle Keyframes des Clips")
def _clip_key(p: dict[str, Any], a: dict[str, Any]) -> dict[str, Any]:
    c = _find(p["clips"], a.get("id", ""), t("Clip", "clip"))
    if _track(p, c["track"])["kind"] != "video":
        raise StudioError(t("Skalieren geht nur auf Videospuren.", "Scaling only works on video tracks."))
    keys = list(c.get("scale_keys") or [])
    if a.get("clear"):
        c["scale_keys"] = []
        return {"keys": 0}
    at = _time(a, "at")
    if at is None or not c["start"] <= at <= clip_end(c):
        raise StudioError(t("at oder at_s muss im Clip liegen.", "at or at_s must lie inside the clip."))
    media = _media_at(c, at - c["start"])
    near = int(round(frame_ticks(p) * clip_speed(c) / 2))  # innerhalb eines halben Bildes gilt als derselbe
    keys = [k for k in keys if abs(k["at"] - media) > near]
    if not a.get("delete"):
        keys.append({"at": media, "value": _check_scale(a.get("value", clip_scale_at(c, media)))})
    c["scale_keys"] = sorted(keys, key=lambda k: k["at"])
    return {"keys": len(c["scale_keys"]), "at": media}


# ---------------------------------------------------------------------------------------- Übernehmen

def _conform_targets(p: dict[str, Any]) -> dict[str, tuple[int, str]]:
    """Wohin das Übernehmen jede Szene legt: Platzieren-Marker (Vorgabe V2, sonst die oberste Spur), sonst an den
    Szenenanfang auf die Spur ihrer Bahn. Audio-Marker verschieben dabei die Ton-Szene an die Marke (in `p`)."""
    scenes = {s["id"]: s for s in p["scenes"]}
    for m in p["markers"]:
        if m["kind"] == "audio" and m["params"].get("scene_id") in scenes:
            scenes[m["params"]["scene_id"]]["start"] = m["at"]
    targets = {s["id"]: (s["start"], _track_or_highest(p, LANE_TRACK[s["lane"]], "video" if s["lane"] == "video"
                                                       else "audio")) for s in p["scenes"]}
    for m in p["markers"]:
        if m["kind"] == "place" and m["params"].get("scene_id") in scenes:
            targets[m["params"]["scene_id"]] = (m["at"], _track_or_highest(p, m["params"].get("track") or "V2", "video"))
    return targets


def conform_plan(p: dict[str, Any]) -> dict[str, Any]:
    """Was „Übernehmen“ täte, ohne etwas zu ändern (Nutzer 27.10.2026: „es soll erkennen, wenn die Clips schon
    generiert worden sind … ich kann mit der Checkbox wählen, welche überschrieben werden“).

    Je Szene mit Take ein Eintrag: `create` (noch kein verbundener Clip; `overlaps` nennt die Clips, die er überdecken
    würde, `in_edit`, wenn der Take schon als Clip im Schnitt liegt), `replace` (verbundene Clips bekommen den neuen
    Take; `edited`, wenn ihre Länge nicht mehr der Szene entspricht oder sie geschnitten sind) oder `same`. `default`
    ist der Vorschlag für das Häkchen."""
    q = copy.deepcopy(p)
    targets = _conform_targets(q)
    frame = frame_ticks(q)
    in_edit = {c["asset_id"] for c in q["clips"]}
    items, without = [], 0
    for s in q["scenes"]:
        if not s.get("take"):
            without += 1
            continue
        start, track = targets[s["id"]]
        base = {"scene_id": s["id"], "title": s.get("title") or s.get("prompt", "")[:40] or s["id"],
                "lane": s["lane"], "track": track}
        linked = [c for c in q["clips"] if c.get("scene_id") == s["id"]]
        if linked:
            changed = any(c["asset_id"] != s["take"] for c in linked)
            edited = len(linked) > 1 or linked[0]["in"] != 0 or abs(clip_length(linked[0]) - s["duration"]) > frame
            items.append({**base, "action": "replace" if changed else "same", "clip_ids": [c["id"] for c in linked],
                          "track": linked[0]["track"], "start_s": round(seconds(linked[0]["start"]), 3),
                          "length_s": round(seconds(sum(clip_length(c) for c in linked)), 3),
                          "scene_s": round(seconds(s["duration"]), 3), "edited": edited,
                          "default": changed and not edited})
            continue
        try:
            clip = _new_clip(q, track, s["take"], start, s["duration"], 0, s["id"])
        except StudioError as exc:
            items.append({**base, "action": "error", "error": str(exc), "default": False})
            continue
        overlaps = [{"clip_id": c["id"], "title": _clip_label(q, c),
                     "seconds": round(seconds(min(clip_end(c), clip_end(clip)) - max(c["start"], clip["start"])), 3)}
                    for c in q["clips"] if c["track"] == track and c["start"] < clip_end(clip) and clip_end(c) > start]
        dup = s["take"] in in_edit
        items.append({**base, "action": "create", "start_s": round(seconds(start), 3),
                      "length_s": round(seconds(clip_length(clip)), 3), "overlaps": overlaps, "in_edit": dup,
                      "default": not overlaps and not dup})
    transitions = sum(1 for m in q["markers"] if m["kind"] == "transition")
    return {"items": items, "without_take": without, "transition_markers": transitions}


@command("edit.conform", "Komposition übernehmen: legt die gewählten Takes in den Schnitt, tauscht neu erzeugtes "
         "Material in verbundenen Clips aus und wertet die Marker aus (place, transition, audio). Wahlweise nur "
         "scenes [ids]; neue Clips, die andere überdecken würden, dann nur für die Szenen in overwrite [ids]. "
         "Vorher zeigt GET /api/studio/projects/{id}/conform (MCP: studio_get mit conform_plan), was passieren würde")
def _conform(p: dict[str, Any], a: dict[str, Any]) -> dict[str, Any]:
    created = updated = transitions = 0
    only = set(a["scenes"]) if isinstance(a.get("scenes"), list) else None
    allowed = set(a.get("overwrite") or [])
    skipped: list[str] = []
    targets = _conform_targets(p)
    for s in p["scenes"]:
        if not s.get("take") or (only is not None and s["id"] not in only):
            continue
        start, track = targets[s["id"]]
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
        covers = any(c["track"] == track and c["start"] < clip_end(clip) and clip_end(c) > start for c in p["clips"])
        if covers and only is not None and s["id"] not in allowed:
            skipped.append(s["id"])  # der Nutzer hat das Überschreiben hier nicht erlaubt
            continue
        p["clips"].append(clip)
        _overwrite(p, clip)
        created += 1
    # Übergang-Marker: Überblendung auf den Clip, der dort (± eine halbe Sekunde) beginnt
    for m in p["markers"]:
        if m["kind"] == "transition" and _apply_transition_marker(p, m):
            transitions += 1
    p["clips"].sort(key=lambda c: (c["track"], c["start"]))
    return {"created": created, "updated": updated, "transitions": transitions, "skipped": skipped}


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
        folder = p.get("folder")
        if not folder:
            project_folder(p)
        elif pid in _rename_later and time.time() - _rename_later[pid] > RENAME_RETRY_SECONDS:
            _follow_name(p)
        changed = changed or p.get("folder") != folder
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


def _last_frame_asset(asset_id: str, title: str = "", folder: str = "") -> str:
    """Letztes Bild eines Videos als Upload-Asset (Startbild für „Anschluss“), in der Medienleiste beschriftet; liegt
    im Projektordner."""
    path = _source_path(asset_id)
    name = f"{folder}/{db.new_id('upl')}.png" if folder else f"{db.new_id('upl')}.png"
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
        return "txt2audio", {**req.model_dump(), "studio_project": p["id"]}
    if s["kind"] == "image":
        model_id = _known_model(s.get("model_id"), "image")
        req = GenerateImageRequest(prompt=s["prompt"], model_id=model_id, **_image_size(p, params),
                                   **{k: v for k, v in params.items() if k in ("seed", "steps", "cfg",
                                                                               "negative_prompt",
                                                                               "reference_asset_ids", "loras")})
        return "txt2img", {**req.model_dump(), "studio_project": p["id"]}
    model_id = _known_model(s.get("model_id"), "video")
    fps = 24 if (model_id or "").startswith("ltx") else 16
    step = 8 if (model_id or "").startswith("ltx") else 4
    frames = max(9, int(round(secs * fps / step)) * step + 1)
    # audio_asset_id: ein vorgegebener Ton, etwa ein schon abgenommener Satz, damit die Stimme gleich bleibt (Nutzer
    # 27.10.); die Länge kommt dann vom Ton
    extra = {k: v for k, v in params.items() if k in ("seed", "steps", "cfg", "negative_prompt", "loras",
                                                      "end_image_asset_id", "quality", "motion_speed",
                                                      "audio_asset_id", "loop", "temporal_upscale", "crf")}
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
        image_id = _last_frame_asset(source["take"], source.get("title") or "", project_folder(p))
    req = GenerateVideoRequest(prompt=s["prompt"], model_id=model_id, frames=frames, fps=fps,
                               image_asset_id=image_id, **_video_size(model_id, p, params), **extra)
    return "txt2video", {**req.model_dump(), "studio_project": p["id"]}


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
    tracks = {tr["id"]: tr for tr in p["tracks"]}
    clips = []
    for c in p["clips"]:
        path = _source_path(c["asset_id"])
        media = _media(p, c["asset_id"])
        track = tracks.get(c["track"], {})
        clips.append({"track": c["track"], "path": str(path), "media": media["kind"], "audio": media.get("audio", False),
                      "start": seconds(c["start"]), "in": seconds(c["in"]), "out": seconds(c["out"]),
                      "speed": clip_speed(c), "gain_db": c.get("gain_db", 0.0),
                      # Skalieren: Keyframes in Sekunden Medienzeit, wie in/out
                      "scale": float(c.get("scale") or 1.0), "anchor": c.get("anchor") or [0.5, 0.5],
                      "scale_keys": [{"t": seconds(k["at"]), "v": k["value"]} for k in c.get("scale_keys") or []],
                      # stumm geschaltete Spur: ihr Ton fehlt, auch der Ton von Videoclips
                      "muted": bool(c.get("muted") or track.get("muted")),
                      "transition": ({"kind": c["transition"]["kind"],
                                      "seconds": seconds(c["transition"]["duration"])} if c.get("transition") else None)})
    lossless_audio = pr["codec"] in ("ffv1", "prores")  # PCM schwingt nicht über wie AAC
    # Ausgeblendete Videospuren fehlen im Bild (ihr Ton bleibt, solange die Spur nicht stumm ist)
    visible = [tr["id"] for tr in p["tracks"] if not tr.get("hidden")]
    return {"width": pr.get("width") or s["width"], "height": pr.get("height") or s["height"], "fps": s["fps"],
            "sample_rate": s.get("sample_rate", 48000), "codec": pr["codec"], "bitrate": pr["bitrate"],
            "duration": seconds(edit_duration(p)), "tracks": visible, "clips": clips,
            "loudness": -14.0, "ceiling_db": -1.0 if lossless_audio else -2.5}


# Dateien, die kein Browser abspielt: Sie bekommen eine H.264-Vorschau (meta.preview)
NO_BROWSER = {".mkv", ".mov", ".avi", ".wmv", ".flv", ".mxf", ".mts", ".m2ts", ".ts",
              ".mpg", ".mpeg", ".m2v", ".vob", ".dv"}  # MPEG-2 und DV aus VHS-Aufnahmen (seit 0.5.16)
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
        name = f"{asset.folder}/{src.stem}.preview.mp4" if asset.folder else f"{src.stem}.preview.mp4"
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
    return await jobs.submit("studio_export", {"project_id": pid, "preset": preset, "studio_project": pid})


# ------------------------------------------------------------------------ Projekt als Paket (Nutzer 27.10.2026)
#
# „+“ neben der Projektauswahl: Neu, Exportieren, Importieren. Ein Paket ist ein ZIP mit nvai-studio.json (Projekt
# und Angaben aller benutzten Assets) und den Dateien unter files/: Clips, Takes, Start- und Endbilder, vorgegebener
# Ton, die H.264-Vorschauen und auf Wunsch die verlustfreien Kopien (groß: 1080p rund 32 MB je Sekunde). Gepackt
# wird ohne Kompression (Videos sind schon komprimiert). Beim Import bleiben die Asset-IDs; was es dort schon gibt,
# wird nicht noch einmal kopiert, das Projekt bekommt eine neue ID.

PACKAGE_FORMAT = "nvai-studio"
PACKAGE_MANIFEST = "nvai-studio.json"
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,150}$")


def _used_assets(p: dict[str, Any]) -> list[str]:
    ids = {c["asset_id"] for c in p["clips"]}
    for s in p["scenes"]:
        ids.update(s.get("takes") or [])
        params = s.get("params") or {}
        ids.update(params[k] for k in ("image_asset_id", "end_image_asset_id", "audio_asset_id") if params.get(k))
        ids.update(params.get("reference_asset_ids") or [])
    return sorted(ids)


def _package_files(p: dict[str, Any], masters: bool) -> tuple[list[dict[str, Any]], list[Path]]:
    assets, files = [], []
    for asset_id in _used_assets(p):
        asset = db.get_asset(asset_id)
        if asset is None or not (config.ASSET_DIR / asset.filename).exists():
            continue  # gelöscht: im Projekt steht der Clip dann als fehlend
        meta = dict(asset.meta or {})
        names = [asset.filename] + [meta[k] for k in ("preview",) if meta.get(k)]
        if masters and meta.get("master"):
            names.append(meta["master"])
        elif "master" in meta:
            meta.pop("master")
        names = [n for n in names if (config.ASSET_DIR / n).exists()]
        if meta.get("preview") not in names:
            meta.pop("preview", None)
        for key in ("preview", "master"):  # im ZIP liegen alle Dateien unter files/<Name>, ohne Projektordner
            if meta.get(key):
                meta[key] = Path(meta[key]).name
        assets.append({"id": asset.id, "kind": asset.kind, "filename": Path(asset.filename).name,
                       "prompt": asset.prompt, "model_id": asset.model_id, "meta": meta, "created_at": asset.created_at})
        files += [config.ASSET_DIR / n for n in names]
    return assets, files


def package_info(pid: str) -> dict[str, Any]:
    """Größe eines Pakets mit und ohne verlustfreie Kopien, für die Auswahl in der Oberfläche."""
    p = load(pid)
    _, light = _package_files(p, False)
    _, full = _package_files(p, True)
    return {"name": p["name"], "files": len(light), "bytes": sum(f.stat().st_size for f in light),
            "master_bytes": sum(f.stat().st_size for f in full) - sum(f.stat().st_size for f in light)}


def build_package(pid: str, masters: bool = False) -> tuple[Path, str]:
    """ZIP auf die Platte (Studio-Ordner, Unterordner pakete) und der Dateiname zum Herunterladen."""
    p = load(pid)
    assets, files = _package_files(p, masters)
    folder = _dir() / "pakete"
    folder.mkdir(exist_ok=True)
    path = folder / f"{p['id']}-{int(time.time())}.zip"
    manifest = {"format": PACKAGE_FORMAT, "version": 1, "exported_at": time.time(), "masters": masters,
                "project": p, "assets": assets}
    with zipfile.ZipFile(path, "w", zipfile.ZIP_STORED, allowZip64=True) as z:
        z.writestr(PACKAGE_MANIFEST, json.dumps(manifest, ensure_ascii=False, indent=1))
        for f in dict.fromkeys(files):
            z.write(f, f"files/{f.name}")
    slug = re.sub(r"[^\w.-]+", "_", p["name"]).strip("._") or p["id"]
    return path, f"{slug}.nvai-studio.zip"


def _unique_name(name: str, folder: str = "") -> str:
    """Ein freier Dateiname im Ordner, relativ zum Asset-Ordner."""
    stem, suffix = Path(name).stem, Path(name).suffix

    def rel(n: str) -> str:
        return f"{folder}/{n}" if folder else n

    while (config.ASSET_DIR / rel(name)).exists():
        name = f"{stem}-{db.new_id('imp')[4:12]}{suffix}"
    return rel(name)


def import_package(path: Path) -> dict[str, Any]:
    """Paket (ZIP) oder nur das Projekt (JSON) einlesen; gibt das neue Projekt zurück."""
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as z:
            try:
                manifest = json.loads(z.read(PACKAGE_MANIFEST).decode("utf-8"))
            except KeyError:
                raise StudioError(t("Kein Studio-Paket: nvai-studio.json fehlt.",
                                    "Not a Studio package: nvai-studio.json is missing.")) from None
            members = set(z.namelist())
            p = _imported_project(manifest)
            for a in manifest.get("assets") or []:
                _import_asset(z, members, a, p["folder"])
    else:
        try:
            manifest = json.loads(path.read_text(encoding="utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise StudioError(t("Weder Studio-Paket (.zip) noch Projekt (.json).",
                                "Neither a Studio package (.zip) nor a project (.json).")) from None
        if "project" not in manifest:  # eine nackte Projektdatei aus studio/
            manifest = {"format": PACKAGE_FORMAT, "project": manifest}
        p = _imported_project(manifest)
    with _lock:
        _save(p)
    return p


def _imported_project(manifest: dict[str, Any]) -> dict[str, Any]:
    """Das Projekt aus einem Paket mit neuer ID, freiem Namen und eigenem Ordner (noch nicht gespeichert)."""
    p = manifest.get("project")
    if manifest.get("format") != PACKAGE_FORMAT or not isinstance(p, dict) or not isinstance(p.get("clips"), list):
        raise StudioError(t("Das ist kein Studio-Projekt.", "This is not a Studio project."))
    now = time.time()
    names = {info["name"] for info in list_projects()}
    name = str(p.get("name") or "Import")
    if name in names:
        name = next(f"{name} ({i})" for i in range(2, 1000) if f"{name} ({i})" not in names)
    p.update(id=db.new_id("stu"), name=name, created_at=now, updated_at=now, version=VERSION)
    p.setdefault("tracks", copy.deepcopy(TRACKS))
    p.setdefault("markers", [])
    p.setdefault("scenes", [])
    p.setdefault("media", {})
    for s in p["scenes"]:  # Aufträge gehören zur anderen Installation
        s["jobs"] = []
        s.pop("waiting_for", None)
    p.pop("folder", None)  # der Ordner der anderen Installation
    project_folder(p)
    return p


def _import_asset(z: zipfile.ZipFile, members: set[str], a: dict[str, Any], folder: str = "") -> None:
    """Ein Asset aus dem Paket: vorhandenes bleibt, sonst Dateien kopieren und unter derselben ID eintragen."""
    asset_id = str(a.get("id", ""))
    if not re.fullmatch(r"[a-z]{2,5}_[0-9a-f]{6,32}", asset_id) or a.get("kind") not in ("image", "video", "audio",
                                                                                        "upload"):
        return
    existing = db.get_asset(asset_id)
    if existing is not None and (config.ASSET_DIR / existing.filename).exists():
        _import_extras(z, members, a, existing)
        return
    meta = dict(a.get("meta") or {})
    renamed: dict[str, str] = {}
    for key in ("filename", "preview", "master"):
        name = a.get("filename") if key == "filename" else meta.get(key)
        if not name:
            continue
        if not SAFE_NAME.match(str(name)) or f"files/{name}" not in members:
            if key == "filename":
                return  # ohne Datei kein Asset
            meta.pop(key, None)
            continue
        target = _unique_name(str(name), folder)
        with z.open(f"files/{name}") as src, open(config.ASSET_DIR / target, "wb") as dst:
            shutil.copyfileobj(src, dst, 1 << 20)
        renamed[key] = target
    for key in ("preview", "master"):
        if key in renamed:
            meta[key] = renamed[key]
    meta["imported"] = True
    db.insert_asset(asset_id, a["kind"], renamed["filename"], str(a.get("prompt") or ""), str(a.get("model_id") or ""),
                    meta, float(a.get("created_at") or time.time()))


def _import_extras(z: zipfile.ZipFile, members: set[str], a: dict[str, Any], existing: Any) -> None:
    """Das Asset gibt es schon: eine fehlende verlustfreie Kopie oder Vorschau aus dem Paket ergänzen (erst ein Paket
    ohne Kopien importiert, später eins mit)."""
    have = existing.meta or {}
    changes = {}
    for key in ("master", "preview"):
        name = (a.get("meta") or {}).get(key)
        if not name or (have.get(key) and (config.ASSET_DIR / have[key]).exists()):
            continue
        if not SAFE_NAME.match(str(name)) or f"files/{name}" not in members:
            continue
        target = _unique_name(str(name), existing.folder)  # neben das vorhandene Asset
        with z.open(f"files/{name}") as src, open(config.ASSET_DIR / target, "wb") as dst:
            shutil.copyfileobj(src, dst, 1 << 20)
        changes[key] = target
    if changes:
        db.update_asset_meta(existing.id, changes)


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
                assets[asset_id]["preview"] = db.file_url(asset.meta["preview"])
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
        "folder": str(config.ASSET_DIR / p["folder"]) if p.get("folder") else None,
        "scenes": [{"id": s["id"], "lane": s["lane"], "start_s": round(seconds(s["start"]), 3),
                    "duration_s": round(seconds(s["duration"]), 3), "title": s["title"], "prompt": s["prompt"],
                    "kind": s["kind"], "model_id": s.get("model_id"), "chain_from": s.get("chain_from"),
                    "status": scene_status(s), "waiting_for": s.get("waiting_for"), "take": s.get("take"),
                    "takes": len(s["takes"]), "error": s.get("error")} for s in p["scenes"]],
        "markers": [{"id": m["id"], "at_s": round(seconds(m["at"]), 3), "kind": m["kind"], "name": m["name"],
                     "comment": m["comment"], "params": m["params"], "done": m["done"]} for m in p["markers"]],
        "tracks": [{"id": tr["id"], "kind": tr["kind"], **{k: True for k in ("hidden", "muted") if tr.get(k)}}
                   for tr in p["tracks"]],
        "clips": [{"id": c["id"], "track": c["track"], "start_s": round(seconds(c["start"]), 3),
                   "end_s": round(seconds(clip_end(c)), 3), "asset_id": c["asset_id"], "scene_id": c.get("scene_id"),
                   **({"speed": clip_speed(c)} if clip_speed(c) != 1.0 else {}),
                   **({"scale": c["scale"]} if c.get("scale") not in (None, 1.0) else {}),
                   **({"anchor": c["anchor"]} if c.get("anchor") and c["anchor"] != [0.5, 0.5] else {}),
                   **({"scale_keys": [{"at_s": round(seconds(k["at"]), 3), "value": k["value"]}
                                      for k in c["scale_keys"]]} if c.get("scale_keys") else {}),
                   "transition": c.get("transition") and {"kind": c["transition"]["kind"],
                                                          "seconds": round(seconds(c["transition"]["duration"]), 3)}}
                  for c in p["clips"]],
        "duration_s": round(seconds(edit_duration(p)), 3),
    }
