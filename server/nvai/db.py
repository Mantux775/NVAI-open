"""SQLite-Persistenz fuer Jobs und Assets.

Bewusst simpel gehalten: eine Verbindung, ein Lock. Der Server hat genau einen
GPU-Worker, die Schreiblast ist also minimal.
"""
from __future__ import annotations

import json
import sqlite3
import threading
import time
import uuid
from pathlib import Path
from typing import Any

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
        _conn.commit()


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


def list_jobs(limit: int = 50, offset: int = 0, exclude: str | None = None) -> list[Job]:
    """Neueste zuerst; `exclude` laesst eine Art weg (der Verlauf zeigt keine Downloads und blaettert in
    50er-Schritten -- mitgezaehlte Downloads machten die Seiten sonst kuerzer)."""
    with _lock:
        if exclude:
            rows = _c().execute(
                "SELECT * FROM jobs WHERE kind != ? ORDER BY created_at DESC LIMIT ? OFFSET ?", (exclude, limit, offset)
            ).fetchall()
        else:
            rows = _c().execute(
                "SELECT * FROM jobs ORDER BY created_at DESC LIMIT ? OFFSET ?", (limit, offset)
            ).fetchall()
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
    asset_id = new_id("ast")
    created = time.time()
    meta = meta or {}
    with _lock:
        _c().execute(
            "INSERT INTO assets (id, job_id, kind, filename, prompt, model_id, meta, created_at)"
            " VALUES (?,?,?,?,?,?,?,?)",
            (asset_id, job_id, kind, filename, prompt, model_id, json.dumps(meta), created),
        )
        _c().commit()
    return _asset(asset_id, job_id, kind, filename, prompt, model_id, meta, created)


def _asset(
    aid: str, job_id: str | None, kind: str, filename: str,
    prompt: str, model_id: str, meta: dict[str, Any], created: float,
) -> Asset:
    return Asset(
        id=aid, job_id=job_id, kind=kind, filename=filename,
        url=f"/files/{filename}",
        thumb_url=f"/files/{filename}" if kind == "image" else None,
        prompt=prompt, model_id=model_id, meta=meta, created_at=created,
    )


def _row_to_asset(row: sqlite3.Row) -> Asset:
    return _asset(
        row["id"], row["job_id"], row["kind"], row["filename"],
        row["prompt"], row["model_id"], json.loads(row["meta"]), row["created_at"],
    )


def get_asset(asset_id: str) -> Asset | None:
    with _lock:
        row = _c().execute("SELECT * FROM assets WHERE id = ?", (asset_id,)).fetchone()
    return _row_to_asset(row) if row else None


def list_assets(kind: str | None = None, limit: int = 100, offset: int = 0) -> list[Asset]:
    q = "SELECT * FROM assets"
    args: list[Any] = []
    if kind:
        q += " WHERE kind = ?"
        args.append(kind)
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
    path = config.ASSET_DIR / Path(filename).name
    try:
        size = path.stat().st_size
        path.unlink()
        return size
    except OSError:
        return 0


def _asset_files(asset: Asset) -> list[str]:
    """Die Datei eines Assets und, bei Videos, sein verlustfreier Master (meta.master) und seine Vorschau
    (meta.preview)."""
    meta = asset.meta or {}
    return [asset.filename] + [meta[k] for k in ("master", "preview") if meta.get(k)]


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


def delete_job(job_id: str) -> tuple[bool, int, int]:
    """Loescht einen Job mit allen zugehoerigen Assets und Dateien.
    Gibt (gefunden, Anzahl Assets, freigewordene Bytes) zurueck."""
    job = get_job(job_id)
    if job is None:
        return False, 0, 0
    assets = assets_for_job(job_id)
    freed = sum(_unlink(f) for a in assets for f in _asset_files(a))
    with _lock:
        _c().execute("DELETE FROM assets WHERE job_id = ?", (job_id,))
        _c().execute("DELETE FROM jobs WHERE id = ?", (job_id,))
        _c().commit()
    return True, len(assets), freed


def clear_history(kind: str | None = None) -> tuple[int, int, int]:
    """Leert den Verlauf. Ohne `kind` alles, sonst nur Jobs, deren Assets
    diesen Typ haben. Download-Jobs bleiben immer erhalten -- sie sind
    Modellverwaltung, kein Generierungsverlauf.

    Gibt (Jobs, Assets, freigewordene Bytes) zurueck."""
    with _lock:
        if kind:
            rows = _c().execute(
                "SELECT DISTINCT job_id FROM assets WHERE kind = ? AND job_id IS NOT NULL", (kind,)
            ).fetchall()
            job_ids = [r["job_id"] for r in rows]
        else:
            rows = _c().execute("SELECT id FROM jobs WHERE kind != 'download'").fetchall()
            job_ids = [r["id"] for r in rows]

    jobs_deleted = assets_deleted = freed = 0
    for jid in job_ids:
        found, n, bytes_ = delete_job(jid)
        if found:
            jobs_deleted += 1
            assets_deleted += n
            freed += bytes_

    # Verwaiste Assets ohne Job (z.B. Uploads) beim Komplettlauf mitnehmen.
    if not kind:
        with _lock:
            orphans = _c().execute(
                "SELECT * FROM assets WHERE job_id IS NULL"
            ).fetchall()
        for row in orphans:
            freed += sum(_unlink(f) for f in _asset_files(_row_to_asset(row)))
            assets_deleted += 1
        with _lock:
            _c().execute("DELETE FROM assets WHERE job_id IS NULL")
            _c().commit()

    return jobs_deleted, assets_deleted, freed
