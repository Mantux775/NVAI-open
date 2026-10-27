"""SQLite-Persistenz fuer Jobs und Assets.

Bewusst simpel gehalten: eine Verbindung, ein Lock. Der Server hat genau einen
GPU-Worker, die Schreiblast ist also minimal.
"""
from __future__ import annotations

import json
import os
import re
import sqlite3
import threading
import time
import uuid
from pathlib import Path
from typing import Any
from urllib.parse import quote

from . import config
from .i18n import t
from .schemas import Asset, Job

_lock = threading.RLock()
_conn: sqlite3.Connection | None = None

SCHEMA = """
CREATE TABLE IF NOT EXISTS jobs (
    id          TEXT PRIMARY KEY,
    kind        TEXT NOT NULL,
    status      TEXT NOT NULL,
    progress    REAL NOT NULL DEFAULT 0,
    stage       TEXT NOT NULL DEFAULT '',
    params      TEXT NOT NULL DEFAULT '{}',
    asset_ids   TEXT NOT NULL DEFAULT '[]',
    error       TEXT,
    created_at  REAL NOT NULL,
    started_at  REAL,
    finished_at REAL
);
CREATE TABLE IF NOT EXISTS assets (
    id          TEXT PRIMARY KEY,
    job_id      TEXT,
    kind        TEXT NOT NULL,
    filename    TEXT NOT NULL,
    prompt      TEXT NOT NULL DEFAULT '',
    model_id    TEXT NOT NULL DEFAULT '',
    meta        TEXT NOT NULL DEFAULT '{}',
    created_at  REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_jobs_created ON jobs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_assets_created ON assets(created_at DESC);
"""


def init() -> None:
    global _conn
    config.ensure_dirs()
    _conn = sqlite3.connect(config.DB_PATH, check_same_thread=False)
    _conn.row_factory = sqlite3.Row
    with _lock:
        _conn.executescript(SCHEMA)
        # Seit 0.5.15: Unterordner im Asset-Ordner (Studio/<Projekt>); '' = oberste Ebene, der Verlauf
        if "folder" not in {r["name"] for r in _conn.execute("PRAGMA table_info(assets)")}:
            _conn.execute("ALTER TABLE assets ADD COLUMN folder TEXT NOT NULL DEFAULT ''")
        _conn.execute("CREATE INDEX IF NOT EXISTS idx_assets_folder ON assets(folder)")
        _conn.execute("CREATE INDEX IF NOT EXISTS idx_assets_job ON assets(job_id)")
        _conn.commit()


def asset_file(name: str) -> Path | None:
    """Pfad einer Datei im Asset-Ordner aus ihrem Namen, auch in einem Unterordner wie Studio/<Projekt>/ (seit
    0.5.15). None für alles, was aus dem Ordner hinausführen könnte (.., Laufwerk, Verknüpfung nach draußen)."""
    parts = [part for part in re.split(r"[\\/]+", name or "") if part]
    if not parts or any(part in (".", "..") or ":" in part for part in parts):
        return None
    path = config.ASSET_DIR.joinpath(*parts)
    try:
        path.resolve().relative_to(config.ASSET_DIR.resolve())
    except (ValueError, OSError):
        return None
    return path


def replace_file(src: Path, dst: Path) -> None:
    """os.replace mit kurzem Wiederholen: Unter Windows scheitert es mit WinError 5 bzw. 32, solange ein anderer die
    Datei offen hat (die Weboberfläche spielt gerade ein Video, die Projektliste wird gelesen). Höchstens 2 s."""
    for attempt in range(40):
        try:
            os.replace(src, dst)
            return
        except PermissionError:
            if attempt == 39:
                raise
            time.sleep(0.05)


def _c() -> sqlite3.Connection:
    if _conn is None:
        raise RuntimeError(t("db.init() wurde nicht aufgerufen", "db.init() was not called"))
    return _conn


def new_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:12]}"


# ---------------------------------------------------------------- jobs

def create_job(kind: str, params: dict[str, Any]) -> Job:
    job = Job(id=new_id("job"), kind=kind, status="queued", params=params, created_at=time.time())
    with _lock:
        _c().execute(
            "INSERT INTO jobs (id, kind, status, params, created_at) VALUES (?,?,?,?,?)",
            (job.id, job.kind, job.status, json.dumps(params), job.created_at),
        )
        _c().commit()
    return job


def update_job(job_id: str, **fields: Any) -> None:
    if not fields:
        return
    if "asset_ids" in fields:
        fields["asset_ids"] = json.dumps(fields["asset_ids"])
    if "params" in fields:
        fields["params"] = json.dumps(fields["params"])
    cols = ", ".join(f"{k} = ?" for k in fields)
    with _lock:
        _c().execute(f"UPDATE jobs SET {cols} WHERE id = ?", (*fields.values(), job_id))
        _c().commit()


def _row_to_job(row: sqlite3.Row) -> Job:
    return Job(
        id=row["id"],
        kind=row["kind"],
        status=row["status"],
        progress=row["progress"],
        stage=row["stage"],
        params=json.loads(row["params"]),
        asset_ids=json.loads(row["asset_ids"]),
        error=row["error"],
        created_at=row["created_at"],
        started_at=row["started_at"],
        finished_at=row["finished_at"],
    )


def get_job(job_id: str) -> Job | None:
    with _lock:
        row = _c().execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
    return _row_to_job(row) if row else None


# Der allgemeine Verlauf ohne das Material der Studio-Projekte (seit 0.5.15, GET /api/jobs?folder=): ohne Aufträge des
# Studios (params.studio_project; im Prompt stünde der Schlüssel mit maskierten Anführungszeichen) und ohne Aufträge,
# deren Dateien alle in einem Projektordner liegen. „Verlauf leeren“ nimmt nur diese.
HISTORY_ONLY = (
    "instr(params, '\"studio_project\":') = 0 AND NOT ("
    "EXISTS (SELECT 1 FROM assets a WHERE a.job_id = jobs.id) AND "
    "NOT EXISTS (SELECT 1 FROM assets a WHERE a.job_id = jobs.id AND a.folder = ''))"
)


def list_jobs(limit: int = 50, offset: int = 0, exclude: str | None = None, folder: str | None = None) -> list[Job]:
    """Neueste zuerst; `exclude` laesst eine Art weg (der Verlauf zeigt keine Downloads und blaettert in
    50er-Schritten -- mitgezaehlte Downloads machten die Seiten sonst kuerzer). `folder` (seit 0.5.15): None = alle,
    auch das Material der Studio-Projekte; '' = nur der allgemeine Verlauf (HISTORY_ONLY); 'Studio/<Name>' = Aufträge
    mit Dateien in diesem Projektordner."""
    where, args = [], []
    if exclude:
        where.append("kind != ?")
        args.append(exclude)
    if folder == "":
        where.append(HISTORY_ONLY)
    elif folder:
        where.append("EXISTS (SELECT 1 FROM assets a WHERE a.job_id = jobs.id AND a.folder = ?)")
        args.append(folder.strip("/"))
    q = "SELECT * FROM jobs" + (" WHERE " + " AND ".join(where) if where else "")
    with _lock:
        rows = _c().execute(q + " ORDER BY created_at DESC LIMIT ? OFFSET ?", (*args, limit, offset)).fetchall()
    return [_row_to_job(r) for r in rows]


# -------------------------------------------------------------- assets

def create_asset(
    kind: str,
    filename: str,
    job_id: str | None = None,
    prompt: str = "",
    model_id: str = "",
    meta: dict[str, Any] | None = None,
) -> Asset:
    """`filename` relativ zum Asset-Ordner, in einem Unterordner mit / (Studio/<Projekt>/…); der Ordner folgt daraus."""
    asset_id = new_id("ast")
    created = time.time()
    meta = meta or {}
    filename = filename.replace("\\", "/")
    folder = folder_of(filename)
    with _lock:
        _c().execute(
            "INSERT INTO assets (id, job_id, kind, filename, prompt, model_id, meta, created_at, folder)"
            " VALUES (?,?,?,?,?,?,?,?,?)",
            (asset_id, job_id, kind, filename, prompt, model_id, json.dumps(meta), created, folder),
        )
        _c().commit()
    return _asset(asset_id, job_id, kind, filename, prompt, model_id, meta, created, folder)


def insert_asset(asset_id: str, kind: str, filename: str, prompt: str, model_id: str, meta: dict[str, Any],
                 created: float) -> Asset:
    """Asset unter einer vorgegebenen ID eintragen (Import eines Studio-Pakets: die Projekte verweisen auf die IDs);
    ein Eintrag ohne Datei unter derselben ID wird ersetzt."""
    filename = filename.replace("\\", "/")
    folder = folder_of(filename)
    with _lock:
        _c().execute(
            "INSERT OR REPLACE INTO assets (id, job_id, kind, filename, prompt, model_id, meta, created_at, folder)"
            " VALUES (?,?,?,?,?,?,?,?,?)",
            (asset_id, None, kind, filename, prompt, model_id, json.dumps(meta), created, folder),
        )
        _c().commit()
    return _asset(asset_id, None, kind, filename, prompt, model_id, meta, created, folder)


def folder_of(filename: str) -> str:
    """Der Unterordner aus dem Dateinamen ('' = oberste Ebene)."""
    return filename.replace("\\", "/").rpartition("/")[0]


def file_url(filename: str) -> str:
    """Adresse unter /files/, je Abschnitt kodiert (Projektnamen mit Leerzeichen, Umlauten, # oder %)."""
    return "/files/" + quote(filename.replace("\\", "/"))


def _asset(
    aid: str, job_id: str | None, kind: str, filename: str,
    prompt: str, model_id: str, meta: dict[str, Any], created: float, folder: str = "",
) -> Asset:
    url = file_url(filename)
    return Asset(
        id=aid, job_id=job_id, kind=kind, filename=filename, folder=folder,
        url=url,
        thumb_url=url if kind == "image" else None,
        prompt=prompt, model_id=model_id, meta=meta, created_at=created,
    )


def _row_to_asset(row: sqlite3.Row) -> Asset:
    return _asset(
        row["id"], row["job_id"], row["kind"], row["filename"],
        row["prompt"], row["model_id"], json.loads(row["meta"]), row["created_at"], row["folder"],
    )


def get_asset(asset_id: str) -> Asset | None:
    with _lock:
        row = _c().execute("SELECT * FROM assets WHERE id = ?", (asset_id,)).fetchone()
    return _row_to_asset(row) if row else None


# Hochgeladenes nach Endung (Uploads tragen keine Art), wie Bin.tsx `mediaKind`
UPLOAD_VIDEO = (".mp4", ".webm", ".mov", ".mkv", ".avi", ".wmv", ".flv", ".mxf", ".mts", ".m2ts", ".ts")
UPLOAD_AUDIO = (".mp3", ".wav", ".flac", ".ogg", ".m4a", ".aac", ".opus")


def _upload_ext_sql(exts: tuple[str, ...]) -> tuple[str, list[str]]:
    return "(" + " OR ".join("lower(filename) LIKE ?" for _ in exts) + ")", [f"%{e}" for e in exts]


def list_assets(kind: str | None = None, limit: int = 100, offset: int = 0, media: str | None = None,
                query: str | None = None, folder: str | None = None) -> list[Asset]:
    """Neueste zuerst. `media` (image|video|audio|all) zählt Uploads nach ihrer Endung dazu, wie das Material des
    Studios; `query` sucht ohne Groß-/Kleinschreibung in Prompt, Dateiname und Angaben (z. B. dem ursprünglichen
    Dateinamen oder der Beschreibung des Upsamplers), über alle Assets, nicht nur die geladenen. `folder`: nur dieser
    Ordner ('' = oberste Ebene, der Verlauf; None = alle)."""
    where: list[str] = []
    args: list[Any] = []
    if kind:
        where.append("kind = ?")
        args.append(kind)
    if folder is not None:
        where.append("folder = ?")
        args.append(folder.strip("/"))
    if media in ("image", "video", "audio", "all"):
        vid, vargs = _upload_ext_sql(UPLOAD_VIDEO)
        aud, aargs = _upload_ext_sql(UPLOAD_AUDIO)
        if media == "all":
            where.append("kind IN ('image', 'video', 'audio', 'upload')")
        elif media == "image":
            where.append(f"(kind = 'image' OR (kind = 'upload' AND NOT {vid} AND NOT {aud}))")
            args += vargs + aargs
        else:
            ext, eargs = (vid, vargs) if media == "video" else (aud, aargs)
            where.append(f"(kind = ? OR (kind = 'upload' AND {ext}))")
            args += [media] + eargs
    if query and query.strip():
        pattern = f"%{query.strip().lower()}%"
        where.append("(lower(prompt) LIKE ? OR lower(filename) LIKE ? OR lower(meta) LIKE ?)")
        args += [pattern, pattern, pattern]
    q = "SELECT * FROM assets" + (" WHERE " + " AND ".join(where) if where else "")
    q += " ORDER BY created_at DESC LIMIT ? OFFSET ?"
    args += [limit, offset]
    with _lock:
        rows = _c().execute(q, args).fetchall()
    return [_row_to_asset(r) for r in rows]


def assets_for_job(job_id: str) -> list[Asset]:
    with _lock:
        rows = _c().execute(
            "SELECT * FROM assets WHERE job_id = ? ORDER BY created_at", (job_id,)
        ).fetchall()
    return [_row_to_asset(r) for r in rows]


# ------------------------------------------------------------- Loeschen

def _unlink(filename: str) -> int:
    """Loescht die Datei zum Asset. Gibt die freigewordenen Bytes zurueck."""
    path = asset_file(filename)
    if path is None:
        return 0
    try:
        size = path.stat().st_size
        path.unlink()
        return size
    except OSError:
        return 0


# Angaben in meta, die eine Datei neben dem Asset nennen (relativ zum Asset-Ordner wie filename)
FILE_KEYS = ("master", "preview")


def _asset_files(asset: Asset) -> list[str]:
    """Die Datei eines Assets und, bei Videos, sein verlustfreier Master (meta.master) und seine Vorschau
    (meta.preview)."""
    meta = asset.meta or {}
    return [asset.filename] + [meta[k] for k in FILE_KEYS if meta.get(k)]


# ------------------------------------------------------------- Ordner (seit 0.5.15)

def _free_path(path: Path) -> Path:
    """Ein Dateiname, den es im Zielordner noch nicht gibt (Name-2.mp4, Name-3.mp4 …)."""
    candidate, n = path, 1
    while candidate.exists():
        n += 1
        candidate = path.with_name(f"{path.stem}-{n}{path.suffix}")
    return candidate


def move_asset(asset_id: str, folder: str) -> Asset | None:
    """Ein Asset samt verlustfreier Kopie und Vorschau in einen Unterordner des Asset-Ordners verschieben ('' = oberste
    Ebene). Scheitert eine Datei (unter Windows noch offen) oder fehlt die Hauptdatei, bleibt alles, wo es war
    (OSError)."""
    asset = get_asset(asset_id)
    folder = folder.replace("\\", "/").strip("/")
    if asset is None or asset.folder == folder:
        return asset
    target = asset_file(folder) if folder else config.ASSET_DIR
    if target is None:
        raise ValueError(t(f"Ungültiger Ordner: {folder}", f"Invalid folder: {folder}"))
    target.mkdir(parents=True, exist_ok=True)
    meta = dict(asset.meta or {})
    names = {"filename": asset.filename, **{k: meta[k] for k in FILE_KEYS if meta.get(k)}}
    moved: list[tuple[Path, Path]] = []
    renamed: dict[str, str] = {}
    try:
        for key, name in names.items():
            src = asset_file(name)
            if src is None or not src.exists():
                if key == "filename":
                    raise FileNotFoundError(name)
                continue  # Vorschau oder Kopie fehlt schon: die Angabe bleibt, wie sie ist
            dst = _free_path(target / src.name)
            replace_file(src, dst)
            moved.append((src, dst))
            renamed[key] = f"{folder}/{dst.name}" if folder else dst.name
    except OSError:
        for src, dst in reversed(moved):
            try:
                os.replace(dst, src)
            except OSError:
                pass
        raise
    meta.update({k: v for k, v in renamed.items() if k != "filename"})
    with _lock:
        _c().execute("UPDATE assets SET filename = ?, folder = ?, meta = ? WHERE id = ?",
                     (renamed["filename"], folder, json.dumps(meta), asset_id))
        _c().commit()
    return get_asset(asset_id)


def _like_prefix(folder: str) -> str:
    return folder.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "/%"


def rename_folder(old: str, new: str) -> int:
    """Unterordner umbenennen (das Studio-Projekt heißt jetzt anders) und die Einträge darin nachziehen; gibt die Zahl
    der Assets zurück. OSError, wenn Windows den Ordner nicht freigibt (eine Datei darin ist gerade offen)."""
    src, dst = asset_file(old), asset_file(new)
    if src is None or dst is None:
        raise ValueError(t(f"Ungültiger Ordner: {old} → {new}", f"Invalid folder: {old} → {new}"))
    if src.exists():
        dst.parent.mkdir(parents=True, exist_ok=True)
        replace_file(src, dst)  # auch nur Groß-/Kleinschreibung: Windows benennt den Ordner dann um
    else:
        dst.mkdir(parents=True, exist_ok=True)

    def moved(name: str) -> str:
        return new + name[len(old):] if name == old or name.startswith(old + "/") else name

    with _lock:
        rows = _c().execute("SELECT id, filename, folder, meta FROM assets WHERE folder = ? OR folder LIKE ? ESCAPE '\\'",
                            (old, _like_prefix(old))).fetchall()
        for r in rows:
            meta = json.loads(r["meta"])
            for k in FILE_KEYS:
                if meta.get(k):
                    meta[k] = moved(meta[k])
            _c().execute("UPDATE assets SET filename = ?, folder = ?, meta = ? WHERE id = ?",
                         (moved(r["filename"]), moved(r["folder"]), json.dumps(meta), r["id"]))
        _c().commit()
    return len(rows)


def folder_counts() -> dict[str, tuple[int, float]]:
    """Unterordner mit Zahl der Assets und jüngstem Eintrag."""
    with _lock:
        rows = _c().execute("SELECT folder, COUNT(*) AS n, MAX(created_at) AS last FROM assets WHERE folder != ''"
                            " GROUP BY folder").fetchall()
    return {r["folder"]: (r["n"], r["last"]) for r in rows}


def update_asset_meta(asset_id: str, changes: dict[str, Any]) -> Asset | None:
    """Angaben eines Assets ergänzen (z. B. meta.preview, wenn die Vorschau fertig ist)."""
    asset = get_asset(asset_id)
    if asset is None:
        return None
    meta = {**(asset.meta or {}), **changes}
    with _lock:
        _c().execute("UPDATE assets SET meta = ? WHERE id = ?", (json.dumps(meta), asset_id))
        _c().commit()
    return get_asset(asset_id)


def delete_asset(asset_id: str) -> tuple[bool, int]:
    """Loescht ein einzelnes Asset samt Datei."""
    asset = get_asset(asset_id)
    if asset is None:
        return False, 0
    freed = sum(_unlink(f) for f in _asset_files(asset))
    with _lock:
        _c().execute("DELETE FROM assets WHERE id = ?", (asset_id,))
        _c().commit()
    _drop_from_job(asset.job_id, asset_id)
    return True, freed


def _drop_from_job(job_id: str | None, asset_id: str) -> None:
    """Haelt die asset_ids-Liste des Jobs konsistent."""
    if job_id is None:
        return
    job = get_job(job_id)
    if job and asset_id in job.asset_ids:
        update_job(job_id, asset_ids=[a for a in job.asset_ids if a != asset_id])


def delete_job(job_id: str, keep: set[str] | frozenset[str] = frozenset(),
               keep_folders: bool = False) -> tuple[bool, int, int]:
    """Loescht einen Job mit allen zugehoerigen Assets und Dateien.
    Gibt (gefunden, Anzahl Assets, freigewordene Bytes) zurueck.

    Was in `keep` steht (von einem Studio-Projekt benutzt) und mit `keep_folders` alles in Projektordnern bleibt als
    Asset ohne Auftrag erhalten: Im Schnitt fehlte sonst der Clip, und „Verlauf leeren“ soll keine Projekte leeren."""
    job = get_job(job_id)
    if job is None:
        return False, 0, 0
    assets = assets_for_job(job_id)
    gone = [a for a in assets if a.id not in keep and not (keep_folders and a.folder)]
    freed = sum(_unlink(f) for a in gone for f in _asset_files(a))
    with _lock:
        _c().executemany("DELETE FROM assets WHERE id = ?", [(a.id,) for a in gone])
        _c().execute("UPDATE assets SET job_id = NULL WHERE job_id = ?", (job_id,))
        _c().execute("DELETE FROM jobs WHERE id = ?", (job_id,))
        _c().commit()
    return True, len(gone), freed


def clear_history(kind: str | None = None, keep: set[str] | frozenset[str] = frozenset()) -> tuple[int, int, int]:
    """Leert den Verlauf. Ohne `kind` alles, sonst nur Jobs, deren Assets
    diesen Typ haben. Download-Jobs bleiben immer erhalten -- sie sind
    Modellverwaltung, kein Generierungsverlauf. Was in Projektordnern liegt oder in `keep` steht (von einem
    Studio-Projekt benutzt), bleibt; Aufträge, die der Verlauf nicht zeigt (HISTORY_ONLY), auch.

    Gibt (Jobs, Assets, freigewordene Bytes) zurueck."""
    with _lock:
        if kind:
            rows = _c().execute(
                "SELECT DISTINCT a.job_id FROM assets a JOIN jobs ON jobs.id = a.job_id"
                f" WHERE a.kind = ? AND a.folder = '' AND {HISTORY_ONLY}", (kind,)
            ).fetchall()
            job_ids = [r["job_id"] for r in rows]
        else:
            rows = _c().execute(f"SELECT id FROM jobs WHERE kind != 'download' AND {HISTORY_ONLY}").fetchall()
            job_ids = [r["id"] for r in rows]

    jobs_deleted = assets_deleted = freed = 0
    for jid in job_ids:
        found, n, bytes_ = delete_job(jid, keep, keep_folders=True)
        if found:
            jobs_deleted += 1
            assets_deleted += n
            freed += bytes_

    # Verwaiste Assets ohne Job (z.B. Uploads) beim Komplettlauf mitnehmen.
    if not kind:
        with _lock:
            orphans = [_row_to_asset(r) for r in _c().execute(
                "SELECT * FROM assets WHERE job_id IS NULL AND folder = ''"
            ).fetchall()]
        orphans = [a for a in orphans if a.id not in keep]
        for a in orphans:
            freed += sum(_unlink(f) for f in _asset_files(a))
            assets_deleted += 1
        with _lock:
            _c().executemany("DELETE FROM assets WHERE id = ?", [(a.id,) for a in orphans])
            _c().commit()

    return jobs_deleted, assets_deleted, freed
