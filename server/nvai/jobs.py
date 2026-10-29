"""Job-Queue mit genau einem GPU-Worker.

Die 16 GB VRAM erlauben nur ein aktives Modell. Statt Semaphoren zu verteilen,
gibt es deshalb bewusst nur einen Consumer -- die Serialisierung ist die
Architektur, nicht ein Detail.
"""
from __future__ import annotations

import asyncio
import contextlib
import json
import random
import time
import traceback
import uuid
from pathlib import Path
from typing import Any, Awaitable, Callable

from . import comfy, config, db, flux3_prompt, gpu, i18n, imagesize, loras, mesh_workers, prompt_targets, registry, workflows

# Modellname in der Sprache der Anfrage (catalog_en.py), fuer Meldungen und Asset-Meta.
_name = registry.display_name
from .i18n import t
from .schemas import Job

Handler = Callable[[Job, "JobContext"], Awaitable[list[str]]]

# Zwei getrennte Queues: die GPU traegt nur einen Job gleichzeitig, Downloads
# sind reine Netzwerkarbeit. Wuerden sie sich eine Queue teilen, blockierte ein
# 20-GB-Download jede Generierung.
_gpu_queue: asyncio.Queue[str] | None = None
_io_queue: asyncio.Queue[str] | None = None
# Experimentell seit 0.5: Liegen die Sprachmodelle auf einer eigenen Karte, laufen
# Textjobs ("Prompt ausbauen") in einer eigenen Schlange neben den Bildjobs.
_text_queue: asyncio.Queue[str] | None = None
# Studio-Export: eigene Warteschlange, weil er Hardware-Encoder und CPU nutzt und neben dem Erzeugen laufen soll.
_render_queue: asyncio.Queue[str] | None = None
_workers: list[asyncio.Task] = []
_subscribers: set[asyncio.Queue] = set()
_loop: asyncio.AbstractEventLoop | None = None
_handlers: dict[str, Handler] = {}
_current_job_id: str | None = None
_current_download_id: str | None = None
# Laufende Jobs mit Abbruchwunsch (Downloads pruefen das bei jedem Datenblock)
_cancel_requested: set[str] = set()
# Der Task des laufenden GPU-Jobs -- nur so laesst er sich einzeln abbrechen.
_current_gpu_task: asyncio.Task | None = None
# Sprache je Job. Die Worker-Loops laufen seit dem Serverstart als eigene Tasks und
# erben deshalb nicht den contextvars-Stand der Anfrage: submit() merkt sich die
# Sprache der Anfrage, _run_one setzt sie im Task des Jobs wieder.
_job_lang: dict[str, str] = {}

IO_KINDS = {"download"}
TEXT_KINDS = {"expand_prompt"}
RENDER_KINDS = {"studio_export", "vhs_clean"}  # Render: laeuft neben GPU-Auftraegen

# Wohin die Dateien eines fertigen Auftrags gehören, bevor job.done rausgeht: Das Studio legt die seiner Projekte in
# deren Ordner (seit 0.5.15; studio.py setzt den Haken, jobs.py kennt das Studio nicht). Läuft in einem Thread.
place_assets: Callable[[Job, list[str]], None] | None = None


class JobContext:
    """Was ein Handler zum Melden von Fortschritt braucht.

    `progress` ist bewusst threadsicher: Download-Callbacks laufen in einem
    Worker-Thread (asyncio.to_thread), asyncio.Queue ist aber an den Loop gebunden.
    """

    def __init__(self, job: Job, loop: asyncio.AbstractEventLoop) -> None:
        self.job = job
        self._loop = loop

    def should_stop(self) -> bool:
        """Abbruch angefordert (POST /api/jobs/{id}/cancel)? Threadsicher: nur ein Set-Lookup."""
        return self.job.id in _cancel_requested

    def progress(self, value: float, stage: str = "") -> None:
        try:
            running = asyncio.get_running_loop()
        except RuntimeError:
            running = None
        if running is self._loop:
            self._emit(value, stage)
        else:
            self._loop.call_soon_threadsafe(self._emit, value, stage)

    def _emit(self, value: float, stage: str) -> None:
        db.update_job(self.job.id, progress=round(value, 4), stage=stage)
        _publish({"type": "job.progress", "job_id": self.job.id, "progress": value, "stage": stage})


def register(kind: str) -> Callable[[Handler], Handler]:
    def deco(fn: Handler) -> Handler:
        _handlers[kind] = fn
        return fn
    return deco


def _publish(event: dict[str, Any]) -> None:
    for q in list(_subscribers):
        with contextlib.suppress(asyncio.QueueFull):
            q.put_nowait(event)


def publish(event: dict[str, Any]) -> None:
    """Ereignis an alle Abonnenten, auch aus einem Arbeits-Thread: asyncio.Queue ist nicht thread-sicher."""
    loop = _loop
    if loop is None or loop.is_closed():
        return
    try:
        running = asyncio.get_running_loop()
    except RuntimeError:
        running = None
    if running is loop:
        _publish(event)
    else:
        loop.call_soon_threadsafe(_publish, event)


def subscribe() -> asyncio.Queue:
    q: asyncio.Queue = asyncio.Queue(maxsize=200)
    _subscribers.add(q)
    return q


def unsubscribe(q: asyncio.Queue) -> None:
    _subscribers.discard(q)


def _queue_for(kind: str) -> asyncio.Queue[str]:
    if kind in TEXT_KINDS and gpu.separate_text_backend() and _text_queue is not None:
        return _text_queue
    if kind in RENDER_KINDS and _render_queue is not None:
        return _render_queue
    q = _io_queue if kind in IO_KINDS else _gpu_queue
    assert q is not None, t("jobs.start() wurde nicht aufgerufen", "jobs.start() was not called")
    return q


async def submit(kind: str, params: dict[str, Any]) -> Job:
    if kind not in _handlers:
        raise ValueError(t(f"Unbekannter Job-Typ: {kind}", f"Unknown job type: {kind}"))
    job = db.create_job(kind, params)
    _job_lang[job.id] = i18n.lang()
    await _queue_for(kind).put(job.id)
    _publish({"type": "job.queued", "job_id": job.id, "kind": kind})
    return job


def current_job_id() -> str | None:
    """Der laufende GPU-Job. Downloads zaehlen hier bewusst nicht mit."""
    return _current_job_id


def current_download_id() -> str | None:
    return _current_download_id


def queue_depth() -> int:
    return _gpu_queue.qsize() if _gpu_queue else 0


def download_queue_depth() -> int:
    return _io_queue.qsize() if _io_queue else 0


def models_downloading() -> list[str]:
    """IDs aller Modelle, fuer die gerade ein Download laeuft oder wartet."""
    out = []
    for job in db.list_jobs(limit=200):
        if job.kind == "download" and job.status in ("queued", "running"):
            mid = (job.params.get("entry") or {}).get("id")
            if mid:
                out.append(mid)
    return out


def model_in_use(model_id: str) -> str | None:
    """Gibt die Job-ID zurueck, die dieses Modell gerade belegt -- sonst None.

    Nur so ein Job darf das Loeschen blockieren. Ein laufender Bild-Job ist
    kein Grund, ein Videomodell nicht loeschen zu duerfen.
    """
    for job in db.list_jobs(limit=200):
        if job.status not in ("queued", "running"):
            continue
        if job.kind == "download":
            if (job.params.get("entry") or {}).get("id") == model_id:
                return job.id
        elif job.params.get("model_id") == model_id:
            return job.id
    return None


def _set_current(job_kind: str, job_id: str | None) -> None:
    global _current_job_id, _current_download_id
    if job_kind in TEXT_KINDS and gpu.separate_text_backend():
        return  # laeuft auf der Textkarte, blockiert die Bildkarte nicht
    if job_kind in RENDER_KINDS:
        return  # Export laeuft neben den GPU-Jobs (Hardware-Encoder, CPU)
    if job_kind in IO_KINDS:
        _current_download_id = job_id
    else:
        _current_job_id = job_id


async def _run_one(job_id: str) -> None:
    i18n.set_lang(_job_lang.pop(job_id, "en"))
    job = db.get_job(job_id)
    if job is None or job.status == "cancelled":
        return

    _set_current(job.kind, job_id)
    db.update_job(job_id, status="running", started_at=time.time(),
                  stage=t("startet", "starting"))
    _publish({"type": "job.started", "job_id": job_id})
    ctx = JobContext(job, asyncio.get_running_loop())
    try:
        asset_ids = await _handlers[job.kind](job, ctx)
        if place_assets is not None and asset_ids:
            try:
                await asyncio.to_thread(place_assets, job, asset_ids)
            except Exception:  # noqa: BLE001 - dann bleibt das Material eben im Verlauf
                traceback.print_exc()
        db.update_job(
            job_id, status="done", progress=1.0, stage=t("fertig", "done"),
            asset_ids=asset_ids, finished_at=time.time(),
        )
        _publish({"type": "job.done", "job_id": job_id, "asset_ids": asset_ids})
    except asyncio.CancelledError:
        db.update_job(job_id, status="cancelled", finished_at=time.time())
        _publish({"type": "job.cancelled", "job_id": job_id})
        raise
    except registry.DownloadCancelled:
        db.update_job(job_id, status="cancelled", finished_at=time.time(),
                      stage=t("vom Nutzer abgebrochen", "cancelled by the user"))
        _publish({"type": "job.cancelled", "job_id": job_id})
    except Exception as exc:  # noqa: BLE001 - Fehler gehoert in den Job, nicht in den Worker
        detail = f"{type(exc).__name__}: {exc}"
        traceback.print_exc()
        db.update_job(job_id, status="error", error=detail, finished_at=time.time())
        _publish({"type": "job.error", "job_id": job_id, "error": detail})
    finally:
        _set_current(job.kind, None)
        _cancel_requested.discard(job_id)


async def _worker_loop(queue: asyncio.Queue[str], name: str) -> None:
    global _current_gpu_task
    while True:
        job_id = await queue.get()
        # Der Job laeuft als eigener Task, damit er einzeln abgebrochen werden
        # kann, ohne den Worker-Loop mitzureissen.
        task = asyncio.create_task(_run_one(job_id), name=f"nvai-job-{job_id}")
        if name == "gpu":
            _current_gpu_task = task
        try:
            await task
        except asyncio.CancelledError:
            # Wurde der Loop selbst abgebrochen (Shutdown)? Dann durchreichen.
            if not task.cancelled():
                raise
        except Exception:  # noqa: BLE001 - der Worker darf nie sterben
            traceback.print_exc()
        finally:
            if name == "gpu":
                _current_gpu_task = None
            queue.task_done()


async def cancel_job(job_id: str) -> dict[str, Any]:
    """Einen einzelnen Job abbrechen: wartend sofort, laufender GPU-Job wie cancel_current,
    laufender Download beim naechsten Datenblock (siehe registry.DownloadCancelled)."""
    job = db.get_job(job_id)
    if job is None:
        return {"ok": False, "reason": t(f"Unbekannter Job: {job_id}", f"Unknown job: {job_id}")}
    if job.status not in ("queued", "running"):
        return {"ok": False, "job_id": job_id,
                "reason": t("Der Job ist schon beendet.", "The job has already finished.")}
    if job.status == "queued":
        db.update_job(job_id, status="cancelled", finished_at=time.time(),
                      stage=t("vom Nutzer abgebrochen", "cancelled by the user"))
        _publish({"type": "job.cancelled", "job_id": job_id})
        return {"ok": True, "job_id": job_id, "stopped": []}
    if job_id == _current_job_id:
        return await cancel_current()
    # Laufender Download (oder Text-Job auf eigener Karte): Flag setzen, der Job endet selbst.
    _cancel_requested.add(job_id)
    db.update_job(job_id, stage=t("bricht ab …", "cancelling …"))
    _publish({"type": "job.progress", "job_id": job_id, "progress": job.progress,
              "stage": t("bricht ab …", "cancelling …")})
    return {"ok": True, "job_id": job_id, "stopped": [], "pending": True}


async def cancel_current() -> dict[str, Any]:
    """Bricht den laufenden GPU-Job ab und gibt den Speicher frei.

    Reihenfolge ist wichtig: erst das Backend anhalten, dann den Task abbrechen.
    Sonst rechnet ComfyUI weiter, obwohl niemand mehr auf das Ergebnis wartet.
    """
    job_id = _current_job_id
    if job_id is None:
        return {"ok": False,
                "reason": t("Es laeuft gerade kein Job.", "No job is running right now.")}

    job = db.get_job(job_id)
    stopped: list[str] = []

    if job and job.kind == "img23d":
        # Mesh-Worker rechnen in einem blockierenden HTTP-Aufruf; nur ein
        # Prozessende bricht das wirklich ab.
        for w in mesh_workers.all_workers():
            if await w.is_running():
                w.stop()
                stopped.append(w.name)
    elif await comfy.interrupt():
        stopped.append("ComfyUI")

    task = _current_gpu_task
    if task is not None and not task.done():
        task.cancel()

    db.update_job(job_id, status="cancelled", finished_at=time.time(),
                  stage=t("vom Nutzer gestoppt", "stopped by the user"))
    _publish({"type": "job.cancelled", "job_id": job_id})
    return {"ok": True, "job_id": job_id, "stopped": stopped}


async def _requeue_orphans() -> None:
    """Nach einem Serverneustart haengen Jobs in der DB auf 'queued'/'running',
    obwohl die Queues leer sind.

    Nichts wird automatisch fortgesetzt -- auch keine Downloads. Ein Job, den der
    Server von selbst wieder anwirft, ist ein Job, den niemand gestartet hat; der
    Teilfortschritt bleibt im HF-Cache erhalten, ein Klick auf 'Neu laden' setzt
    also ohne Verlust fort.
    """
    for job in db.list_jobs(limit=500):
        if job.status not in ("queued", "running"):
            continue
        db.update_job(
            job.id, status="cancelled", finished_at=time.time(),
            stage=t("durch Serverneustart unterbrochen - nicht automatisch fortgesetzt",
                    "interrupted by a server restart - not resumed automatically"),
        )


async def start() -> None:
    global _gpu_queue, _io_queue, _text_queue, _render_queue, _loop
    _loop = asyncio.get_running_loop()
    _gpu_queue = asyncio.Queue()
    _io_queue = asyncio.Queue()
    _text_queue = asyncio.Queue()
    _render_queue = asyncio.Queue()
    _workers.append(asyncio.create_task(_worker_loop(_render_queue, "render"), name="nvai-render-worker"))
    _workers.append(asyncio.create_task(_worker_loop(_text_queue, "text"), name="nvai-text-worker"))
    _workers.append(asyncio.create_task(_worker_loop(_gpu_queue, "gpu"), name="nvai-gpu-worker"))
    _workers.append(asyncio.create_task(_worker_loop(_io_queue, "io"), name="nvai-io-worker"))
    await _requeue_orphans()


async def shutdown() -> None:
    for w in _workers:
        w.cancel()
    for w in _workers:
        with contextlib.suppress(asyncio.CancelledError):
            await w
    _workers.clear()


# --------------------------------------------------------- Handler

def _same_gpu(a: str, b: str) -> bool:
    """Teilen sich zwei Aufgaben (gpu.ROLES) eine Karte? Mit einer Karte immer."""
    if not gpu.multi_gpu():
        return True
    roles = gpu.assignment()
    return roles[a] == roles[b]


async def _ensure_backend(ctx: JobContext) -> None:
    # Ein Mesh-Worker haelt sein Modell im VRAM, bis er entladen wird. Bliebe er
    # stehen, faende ein grosses Video-Modell keinen Platz mehr -- die Gegenrichtung
    # macht _img23d bereits. Rechnet 3D auf einer anderen Karte, darf er bleiben.
    for w in mesh_workers.all_workers():
        if _same_gpu("mesh", "image") and await w.is_running():
            ctx.progress(0.0, t(f"entlade {w.name}", f"unloading {w.name}"))
            await w.unload()

    ctx.progress(0.0, t("GPU-Backend wird gestartet", "starting GPU backend"))
    if not await comfy.is_running():
        comfy.start()
        if not await comfy.wait_until_ready():
            raise RuntimeError(t(
                "ComfyUI ist nicht gestartet (Timeout). Details: /api/backend/log",
                "ComfyUI did not start (timeout). Details: /api/backend/log",
            ))


def _resolve_model(p: dict[str, Any], kind: str) -> dict[str, Any]:
    model_id = p.get("model_id") or registry.get_active_model(kind)
    if not model_id:
        raise RuntimeError(t(
            f"Kein {kind}-Modell installiert. Erst eines unter 'Modelle' herunterladen.",
            f"No {kind} model installed. Download one under 'Models' first.",
        ))
    entry = registry.get_entry(model_id)
    if entry is None:
        raise RuntimeError(t(f"Unbekanntes Modell: {model_id}", f"Unknown model: {model_id}"))
    if not registry.is_installed(entry):
        # Snapshot-Modelle (ganze Repos wie TRELLIS.2) haben kein "file", nur "repo".
        missing = [f.get("file") or f["repo"] for f in entry["files"]
                   if not f.get("optional") and not registry.file_path(f).exists()]
        raise RuntimeError(t(
            f"Modell '{model_id}' unvollstaendig. Fehlt: {', '.join(missing)}",
            f"Model '{model_id}' is incomplete. Missing: {', '.join(missing)}",
        ))
    if entry.get("workflow") is None:
        raise RuntimeError(t(
            f"Fuer '{model_id}' gibt es noch keinen Workflow-Builder.",
            f"There is no workflow builder for '{model_id}' yet.",
        ))
    return entry


def _resolve_loras(p: dict[str, Any], entry: dict[str, Any]) -> list[dict[str, Any]]:
    """LoRA-Angaben der Anfrage pruefen und in Dateinamen fuer loras.apply uebersetzen."""
    out = []
    for ref in p.get("loras") or []:
        lora = registry.get_entry(ref["model_id"])
        if lora is None or lora.get("kind") != "lora":
            raise RuntimeError(t(f"Unbekannte LoRA: {ref['model_id']}", f"Unknown LoRA: {ref['model_id']}"))
        if not registry.is_installed(lora):
            raise RuntimeError(t(f"LoRA '{lora['name']}' ist nicht geladen.",
                                 f"LoRA '{lora['name']}' is not downloaded."))
        if not loras.compatible(lora, entry):
            raise RuntimeError(t(
                f"LoRA '{lora['name']}' ist für {loras.BASES.get(lora['family'], lora['family'])} "
                f"und passt nicht zu {_name(entry)}.",
                f"LoRA '{lora['name']}' is for {loras.BASES.get(lora['family'], lora['family'])} "
                f"and does not fit {_name(entry)}."))
        name = workflows.file_name(lora["files"][0])
        out.append({"model_id": lora["id"], "file": name, "strength": float(ref.get("strength", 1.0)),
                    "expert": loras.expert_of(name)})
    return out


async def _run_generation(job: Job, ctx: JobContext, kind: str, extra_meta: dict[str, Any]) -> list[str]:
    """Gemeinsamer Pfad fuer Bild, Audio und Video: Modell aufloesen, Graph bauen,
    ausfuehren, Ergebnisse in die Library legen."""
    p = job.params
    entry = _resolve_model(p, kind)
    await _ensure_backend(ctx)
    if kind == "video" and p.get("master", True) and not await comfy.has_node(workflows.MASTER_NODE):
        # ComfyUI lief schon, bevor der Knoten dazukam: diesmal nur das MP4, ab dem naechsten Start mit Master
        p = {**p, "master": False}

    graph, seed = workflows.build(entry, p)
    lora_files = _resolve_loras(p, entry)
    if lora_files:
        loras.apply(graph, lora_files)
        extra_meta = {**extra_meta, "loras": [
            {"model_id": lo["model_id"], "strength": lo["strength"]} for lo in lora_files]}
    comfy.set_loaded_model(_name(entry))  # fuer die VRAM-Anzeige
    ctx.progress(0.02, t("generiert", "generating"))

    def on_progress(frac: float, stage: str) -> None:
        # 2..98 % bleiben fuer das Sampling, der Rest fuer Start und Speichern.
        ctx.progress(0.02 + frac * 0.96, stage)

    # Video braucht deutlich mehr Luft: Wan 2.2 A14B laedt mitten im Lauf den
    # zweiten Experten nach, das allein kostet Minuten.
    timeout = 3600.0 if kind == "video" else 900.0
    masters: list[Path] = []
    if p.get("outpaint_passes"):
        paths, outpaint_meta = await _outpaint_passes(ctx, entry, p, lora_files, seed)
        extra_meta = {**extra_meta, **outpaint_meta}
    elif p.get("inpaint_reference"):
        paths, fill_meta = await _inpaint_by_reference(entry, p, graph, lora_files, seed, on_progress)
        extra_meta = {**extra_meta, **fill_meta}
    else:
        paths = await comfy.run_workflow(graph, on_progress=on_progress, timeout=timeout, masters=masters)
    ctx.progress(0.99, t("speichert", "saving"))

    if not paths:
        raise RuntimeError(t("ComfyUI lieferte keine Ausgabedatei zurueck.",
                             "ComfyUI returned no output file."))

    d = workflows.defaults_for(entry["workflow"])
    asset_ids = []
    for i, path in enumerate(paths):
        meta = {
            "seed": seed,
            "steps": p.get("steps") or d["steps"],
            "cfg": p.get("cfg") if p.get("cfg") is not None else d["cfg"],
            "negative_prompt": p.get("negative_prompt", ""),
            "model_name": _name(entry),
            **extra_meta,
        }
        if i < len(masters) and comfy.kind_for(path) == "video":
            meta["master"] = masters[i].name  # verlustfreie Fassung (FFV1/MKV) neben dem MP4
        asset = db.create_asset(
            kind=comfy.kind_for(path),
            filename=path.name,
            job_id=job.id,
            prompt=p.get("prompt", ""),
            model_id=entry["id"],
            meta=meta,
        )
        asset_ids.append(asset.id)
    return asset_ids


def master_path(asset: Any) -> Path | None:
    """Der verlustfreie Master eines Video-Assets, wenn es einen gibt (meta.master)."""
    name = (asset.meta or {}).get("master") if asset is not None else None
    path = config.ASSET_DIR / name if name else None
    return path if path is not None and path.exists() else None


# Reserve beim Erweitern (Anteil der Bildseite) und Mindest-Korrelation, darunter wird neu gerechnet.
OUTPAINT_RESERVE = 0.08
OUTPAINT_MIN_SCORE = 0.9


async def _outpaint_passes(ctx: JobContext, entry: dict[str, Any], p: dict[str, Any],
                           lora_files: list[dict[str, Any]], seed: int) -> tuple[list[Path], dict[str, Any]]:
    """Outpainting per Referenzbild: je Durchgang Rand anlegen, rechnen, ausrichten (_prepare_outpaint).

    Der erste Durchgang rechnet alle Varianten in einem Lauf, ein zweiter (andere Achse) jede
    Variante einzeln weiter. Gerechnet wird mit 8 % Reserve auf den neuen Seiten; sie faengt den
    Versatz von FLUX ab und wird nach dem Ausrichten abgeschnitten (ohne sie blieben Streifen).
    Variante stark umgebaut statt nur verschoben (Korrelation unter 0,9, gemessen 0,82 mit
    doppelten Beinen): einmal mit anderem Seed neu, die bessere bleibt.
    """
    is_flux3 = entry["workflow"] in workflows.FLUX3_WORKFLOWS
    input_dir = config.COMFY_ROOT / "input"
    passes = p["outpaint_passes"]
    batch = int(p.get("batch_size") or 1)
    runs, done = 1 + (len(passes) - 1) * batch, 0
    sources, measured, caption = [p["outpaint_original"]], [], None
    paths: list[Path] = []
    for i, edges in enumerate(passes):
        left, top, right, bottom = edges
        last = i == len(passes) - 1
        produced: list[Path] = []
        for j, src in enumerate(sources):
            dims = imagesize.size(input_dir / src)
            if dims is None:
                raise RuntimeError(t("Zwischenbild nicht lesbar.", "Intermediate image not readable."))
            reserve = [round(OUTPAINT_RESERVE * dims[k % 2]) if edges[k] else 0 for k in range(4)]
            gen_edges = [e + r for e, r in zip(edges, reserve)]
            ctx.progress(0.02 + 0.96 * done / runs, t("legt den Rand an", "adding the border"))
            padded = await comfy.run_workflow(workflows.outpaint_pad_graph(src, gen_edges))
            if not padded:
                raise RuntimeError(t("ComfyUI lieferte das erweiterte Bild nicht.",
                                     "ComfyUI did not return the extended image."))
            ref = comfy.stage_input(padded[0])
            for path in padded:
                path.unlink(missing_ok=True)
            # Ergebnis nach dem Abschneiden: im letzten Durchgang das Zielformat, davor Bild plus Rand.
            size = ((int(p["width"]), int(p["height"])) if last
                    else (dims[0] + left + right, dims[1] + top + bottom))
            pp = {**p, "outpaint": gen_edges, "reference_images": [ref], "caption": None,
                  "width": max(256, round((dims[0] + gen_edges[0] + gen_edges[2]) / 16) * 16),
                  "height": max(256, round((dims[1] + gen_edges[1] + gen_edges[3]) / 16) * 16)}
            if is_flux3:
                # Eigener Cache-Schluessel je Randbild, sonst kaeme eine fremde Beschreibung zurueck.
                await _flux3_caption(pp, entry, [f"outpaint:{ref}"], ctx)
                caption = pp.get("caption") or caption

            async def render(n: int, s: int, done: int = done, pp: dict[str, Any] = pp) -> list[Path]:
                graph, _ = workflows.build(entry, {**pp, "seed": s, "batch_size": n})
                if lora_files:
                    loras.apply(graph, lora_files)

                def on_progress(frac: float, stage: str) -> None:
                    ctx.progress(0.02 + 0.96 * (done + frac) / runs, stage)
                return await comfy.run_workflow(graph, on_progress=on_progress, timeout=900.0)

            outs = await render(batch if i == 0 else 1, seed + j)
            done += 1
            for k, out in enumerate(outs):
                info = await _align_outpaint(out, input_dir / src, gen_edges, reserve, size)
                if info["score"] < OUTPAINT_MIN_SCORE:
                    retry = await render(1, seed + 1000 + 10 * j + k)
                    if retry:
                        second = await _align_outpaint(retry[0], input_dir / src, gen_edges, reserve, size)
                        if second["score"] > info["score"]:
                            retry[0].replace(out)
                            info = {**second, "retried": True}
                        else:
                            retry[0].unlink(missing_ok=True)
                measured.append(info)
            produced.extend(outs)
        if not last:
            sources = [comfy.stage_input(path) for path in produced]
            for path in produced:
                path.unlink(missing_ok=True)
        else:
            paths = produced
    meta: dict[str, Any] = {"outpaint_align": measured, "upsampled": caption is not None}
    if caption:
        meta["caption"] = caption
    return paths, meta


async def _align_script(target: Path, *args: Any) -> dict[str, Any]:
    """outpaint_align.py im ComfyUI-venv (numpy, Pillow) aufrufen; `target` muss danach existieren."""
    script = Path(__file__).with_name("outpaint_align.py")
    proc = await asyncio.create_subprocess_exec(
        str(comfy.comfy_python()), "-I", str(script), *(str(a) for a in args),
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    out, err = await proc.communicate()
    if proc.returncode != 0 or not target.exists():
        raise RuntimeError(t(f"Ausrichten fehlgeschlagen: {err.decode(errors='replace')[-300:]}",
                             f"Aligning failed: {err.decode(errors='replace')[-300:]}"))
    return json.loads(out.decode().strip().splitlines()[-1])


async def _align_outpaint(result: Path, original: Path, edges: list[int], reserve: list[int],
                          size: tuple[int, int]) -> dict[str, Any]:
    """Versatz messen, Original deckungsgleich zuruecklegen, Reserve abschneiden, auf `size` bringen."""
    tmp = result.with_name(result.stem + "_aligned.png")
    info = await _align_script(tmp, result, original, *(int(v) for v in edges), tmp,
                               *(int(v) for v in reserve), size[0], size[1])
    tmp.replace(result)
    return info


async def _inpaint_by_reference(entry: dict[str, Any], p: dict[str, Any], graph: dict[str, Any],
                                lora_files: list[dict[str, Any]], seed: int,
                                on_progress: Any) -> tuple[list[Path], dict[str, Any]]:
    """Fuellen per Referenzbild (_prepare_inpaint_reference): rechnen, jede Variante am Bild
    ausrichten und nur den Maskenbereich einsetzen. Wie beim Erweitern: stark umgebaut
    (Korrelation unter 0,9) -> einmal mit anderem Seed neu, die bessere bleibt."""
    input_dir = config.COMFY_ROOT / "input"
    fill = p["inpaint_reference"]
    original, mask = input_dir / fill["original"], input_dir / fill["mask"]

    async def align(path: Path) -> dict[str, Any]:
        tmp = path.with_name(path.stem + "_filled.png")
        info = await _align_script(tmp, "--inpaint", path, original, mask, tmp)
        tmp.replace(path)
        return info

    outs = await comfy.run_workflow(graph, on_progress=on_progress, timeout=900.0)
    measured = []
    for k, out in enumerate(outs):
        info = await align(out)
        if info["score"] < OUTPAINT_MIN_SCORE:
            retry_graph, _ = workflows.build(entry, {**p, "seed": seed + 1000 + k, "batch_size": 1})
            if lora_files:
                loras.apply(retry_graph, lora_files)
            retry = await comfy.run_workflow(retry_graph, timeout=900.0)
            if retry:
                second = await align(retry[0])
                if second["score"] > info["score"]:
                    retry[0].replace(out)
                    info = {**second, "retried": True}
                else:
                    retry[0].unlink(missing_ok=True)
        measured.append(info)
    return outs, {"inpaint_align": measured, "width": fill["size"][0], "height": fill["size"][1]}


def _stage_image(asset_id: str, wofuer: str) -> str:
    """Asset-Bild nach ComfyUIs input/ legen und den dortigen Dateinamen zurueckgeben.

    ComfyUIs LoadImage kennt nur diesen Ordner -- ein absoluter Pfad funktioniert
    nicht. Genutzt fuer Startbilder (img2img, Bild-zu-Video) und ControlNet-Vorlagen.
    """
    asset = db.get_asset(asset_id)
    if asset is None:
        raise RuntimeError(t(f"{wofuer} nicht gefunden: {asset_id}",
                             f"{wofuer} not found: {asset_id}"))
    src = config.ASSET_DIR / asset.filename
    if not src.exists():
        raise RuntimeError(t(f"Bilddatei fehlt: {src}", f"Image file missing: {src}"))
    return comfy.stage_input(src)


# Was eine Karte fuer die Upsampler-Fassung mindestens an Grafikspeicher haben sollte: Dateigroesse
# auf Hugging Face (black-forest-labs/flux-3-image-klein-comfy) plus Luft fuer ComfyUI und Windows.
UPSAMPLER_NEED_GB = {"w4a8": 6.72 + 1.2, "int8": 9.75 + 1.5, "bf16": 18.82 + 1.5}


def _upsampler_variant(f: dict[str, Any]) -> str:
    name = f.get("file", "")
    return "w4a8" if "w4a8" in name else "bf16" if "bf16" in name else "int8"


def prompt_upsampler() -> dict[str, Any] | None:
    """Die Upsampler-Datei von FLUX 3 (Qwen3.5-9B, Apache-2.0), passend zur Karte der Sprachmodelle.

    Sie baut auch fuer die anderen Bildmodelle einen knappen Prompt zur vollen Bildbeschreibung aus
    ("Prompt ausbauen"). Es gibt sie als int8 (9,75 GB, Standard) und w4a8 (6,72 GB). Passt int8
    nicht in die Karte, nimmt NVAI-open w4a8, wenn sie geladen ist. Gemessen 23.10.2026 auf einer RTX 4060
    mit 8 GB: "Prompt ausbauen" mit int8 134-203 s, weil ComfyUI die Gewichte fuer jedes erzeugte Wort
    erneut ueber PCIe holen musste; mit w4a8 7,5-8,6 s (RTX 5060 Ti mit int8: 10,8-11,0 s).
    """
    found: dict[str, dict[str, Any]] = {}
    for entry in registry.all_entries():
        for f in entry.get("files", []):
            if "upsampler" in f.get("file", "") and registry.file_path(f).exists():
                found.setdefault(_upsampler_variant(f), f)
    if not found:
        return None
    vram = gpu.card_vram_gb(gpu.assignment()["text"])
    for variant in ("int8", "bf16", "w4a8"):
        if variant in found and (vram is None or UPSAMPLER_NEED_GB[variant] <= vram):
            return found[variant]
    # Nichts passt ganz: die kleinste vorhandene Fassung, sie laedt am wenigsten nach.
    return found.get("w4a8") or found.get("int8") or next(iter(found.values()))


def upsampler_fit() -> dict[str, Any] | None:
    """Welche Upsampler-Fassung die Karte der Sprachmodelle bekommt und ob sie ganz hineinpasst
    (Hinweis unter "Grafikkarten"). None, wenn kein Upsampler geladen ist."""
    f = prompt_upsampler()
    if f is None:
        return None
    card = gpu.assignment()["text"]
    vram = gpu.card_vram_gb(card)
    need = UPSAMPLER_NEED_GB[_upsampler_variant(f)]
    return {"variant": _upsampler_variant(f), "need_gb": round(need, 1), "card": card, "card_gb": vram,
            "fits": vram is None or need <= vram}


async def _upsample(prompt: str, upsampler: dict[str, Any], ref_ids: list[str],
                    ref_images: list[str], width: int, height: int,
                    ctx: JobContext) -> str:
    """Laesst den FLUX-3-Upsampler den Prompt zur vollen Bildbeschreibung ausbauen
    (Hintergrund in flux3_prompt.py). Gleiche Anfrage -> Zwischenspeicher."""
    upsampler_file = workflows.file_name(upsampler)
    key, user, locked = flux3_prompt.plan(prompt, len(ref_ids), width, height)
    cache_key = flux3_prompt.cache_key(upsampler_file, key, user, ref_ids)
    caption = flux3_prompt.cache_get(cache_key)
    if caption is None:
        # Mit eigener Textkarte startet run_text_workflow dieses ComfyUI selbst.
        if comfy.text_backend() is comfy.MAIN:
            await _ensure_backend(ctx)
        ctx.progress(0.0, t("Upsampler baut den Prompt aus", "upsampler is expanding the prompt"))
        graph = flux3_prompt.build_graph(upsampler_file, key, user, ref_images)
        texts = await comfy.run_text_workflow(graph)
        caption = (texts[-1] if texts else "").strip()
        if not caption:
            raise RuntimeError(t(
                "Der Prompt-Upsampler von FLUX 3 lieferte keinen Text. Ohne ihn: "
                "upsample_prompt=false und eine volle Bildbeschreibung als Prompt.",
                "The FLUX 3 prompt upsampler returned no text. To work without it: "
                "upsample_prompt=false and a full image description as the prompt.",
            ))
        if locked:
            caption = flux3_prompt.reconcile(caption, locked)
        flux3_prompt.cache_put(cache_key, caption)
    return caption


async def _flux3_caption(p: dict[str, Any], entry: dict[str, Any], ref_ids: list[str],
                         ctx: JobContext) -> dict[str, Any]:
    """FLUX 3: den Prompt vom mitgelieferten Upsampler zur vollen Bildbeschreibung
    ausbauen lassen, bevor das Bild entsteht.

    Legt das Ergebnis unter p["caption"] ab und gibt die Angaben fuer die Asset-Metadaten
    zurueck. Der eingegebene Prompt bleibt in p["prompt"] -- er ist es, den man spaeter
    wiederverwenden will.
    """
    prompt = p["prompt"]
    if p.get("upsample_prompt") is False:
        return {"upsampled": False}
    # Schon eine fertige Upsampler-Antwort (Box-Tabelle voll zitiert): BFL schickt die
    # unveraendert ans Bildmodell, wir auch.
    if flux3_prompt.is_finished(prompt):
        return {"upsampled": False}

    upsampler = prompt_upsampler() or next((f for f in entry["files"] if "upsampler" in f.get("file", "")), None)
    if upsampler is None:
        return {"upsampled": False}
    caption = await _upsample(prompt, upsampler, ref_ids, p.get("reference_images") or [],
                              int(p.get("width", 1024)), int(p.get("height", 1024)), ctx)
    p["caption"] = caption
    return {"upsampled": True, "caption": caption}


async def _moss_caption(p: dict[str, Any], entry: dict[str, Any], ctx: JobContext) -> dict[str, Any]:
    """MOSS-Image: den Prompt vorher von seinem eigenen Text-Encoder (Qwen3.5-9B) zur vollen Bildbeschreibung
    ausbauen lassen, wie in ComfyUIs Vorlage (workflows.moss_caption_graph). Die Beschreibung steht danach in
    p["caption"] und im Asset. Layout-JSON (beginnt mit "{") und upsample_prompt=False gehen unveraendert ans
    Modell; laut ComfyUI-Anleitung wuerde der Ausbau die Boxen verwerfen. Gleiche Anfrage -> Zwischenspeicher."""
    prompt = (p.get("prompt") or "").strip()
    if p.get("upsample_prompt") is False or not prompt or prompt.startswith("{"):
        return {"upsampled": False}
    encoder = workflows._file_by_target(entry, "text_encoders")
    cache_key = flux3_prompt.cache_key(encoder, "moss_image", prompt, [])
    caption = flux3_prompt.cache_get(cache_key)
    if caption is None:
        if comfy.text_backend() is comfy.MAIN:
            await _ensure_backend(ctx)
        ctx.progress(0.0, t("MOSS-Image baut den Prompt aus", "MOSS-Image is expanding the prompt"))
        texts = await comfy.run_text_workflow(workflows.moss_caption_graph(encoder, prompt))
        caption = (texts[-1] if texts else "").strip()
        if not caption:
            raise RuntimeError(t(
                "Der Prompt-Ausbau von MOSS-Image lieferte keinen Text. Ohne ihn: upsample_prompt=false und "
                "eine volle Bildbeschreibung als Prompt.",
                "MOSS-Image's prompt expansion returned no text. To work without it: upsample_prompt=false and "
                "a full image description as the prompt."))
        flux3_prompt.cache_put(cache_key, caption)
    p["caption"] = caption
    return {"upsampled": True, "caption": caption}


async def _expand_other(p: dict[str, Any], upsampler: dict[str, Any], ref_images: list[str],
                        ctx: JobContext) -> str:
    """Prompt ausbauen fuer Video, Ton und 3D: derselbe Upsampler mit NVAI-opens eigenen
    Systemprompts (prompt_targets.py)."""
    target = prompt_targets.ALIASES.get(p["target"], p["target"])
    upsampler_file = workflows.file_name(upsampler)
    system = prompt_targets.SYSTEM[target]
    user = prompt_targets.user_text(target, p["prompt"])
    images = ref_images[:1] if target in prompt_targets.WITH_IMAGE else []
    cache_key = flux3_prompt.cache_key(upsampler_file, target, user, p.get("reference_asset_ids") or [])
    text = flux3_prompt.cache_get(cache_key)
    if text is None:
        if comfy.text_backend() is comfy.MAIN:
            await _ensure_backend(ctx)
        ctx.progress(0.0, t("Upsampler baut den Prompt aus", "upsampler is expanding the prompt"))
        graph = flux3_prompt.build_graph(upsampler_file, "i2i" if images else "t2i", user, images,
                                         system_text=system)
        texts = await comfy.run_text_workflow(graph)
        text = prompt_targets.clean(target, texts[-1] if texts else "")
        if not text:
            raise RuntimeError(t("Der Upsampler lieferte keinen Text.", "The upsampler returned no text."))
        flux3_prompt.cache_put(cache_key, text)
    return text


@register("expand_prompt")
async def _expand_prompt(job: Job, ctx: JobContext) -> list[str]:
    """"Prompt ausbauen" fuer jedes Modell: nur Text, kein Bild. Das Ergebnis steht
    danach in job.params["expanded"]. target waehlt Bild, Video, Ton oder 3D."""
    p = job.params
    upsampler = prompt_upsampler()
    if upsampler is None:
        raise RuntimeError(t(
            "Prompt ausbauen braucht den Upsampler von FLUX 3 Image Klein. Bitte "
            "flux3-klein-nvfp4 (RTX 50) oder flux3-klein-int8 herunterladen.",
            "Expanding a prompt needs the FLUX 3 Image Klein upsampler. Please download "
            "flux3-klein-nvfp4 (RTX 50) or flux3-klein-int8.",
        ))
    ref_ids = [a for a in (p.get("reference_asset_ids") or []) if a]
    if len(ref_ids) > flux3_prompt.MAX_REFERENCES:
        raise RuntimeError(t(f"Hoechstens {flux3_prompt.MAX_REFERENCES} Referenzbilder.",
                             f"At most {flux3_prompt.MAX_REFERENCES} reference images."))
    ref_images = [_stage_image(a, t(f"Referenzbild {i + 1}", f"Reference image {i + 1}"))
                  for i, a in enumerate(ref_ids)]
    target = p.get("target", "image")
    # Bilder mit Referenzen oder Box-Tabelle brauchen BFLs Systemprompts (Bearbeiten,
    # Platzierung); ein schlichter Bildprompt nimmt NVAI-opens kurzen.
    if target == "image" and not ref_ids and flux3_prompt.detect(p["prompt"]) is None:
        p["target"] = target
        p["expanded"] = await _expand_other(p, upsampler, [], ctx)
    elif target != "image":
        p["expanded"] = await _expand_other(p, upsampler, ref_images, ctx)
    else:
        p["expanded"] = await _upsample(p["prompt"], upsampler, ref_ids, ref_images,
                                        int(p.get("width", 1024)), int(p.get("height", 1024)), ctx)
    db.update_job(job.id, params=p)
    return []


# Bearbeitungsmodelle bekommen das Bild mit grauem Rand und diese Anweisung vor dem Prompt.
OUTPAINT_INSTRUCTION = ("Extend the picture into the flat grey border: continue the scene seamlessly "
                        "with the same light, perspective and style, and keep the existing picture "
                        "unchanged.")


async def _prepare_outpaint(p: dict[str, Any], entry: dict[str, Any], ref_ids: list[str],
                            ctx: JobContext) -> None:
    """Outpainting vorbereiten: Zielformat aus Bild plus Rand, je nach Modell auf zwei Wegen.

    Maskenmodelle (Qwen-Image-2512 u. a.): Rand und weiche Maske legt ImagePadForOutpaint im
    Graphen an. Das Modell malt den Rand aber oft als eigene Szene an -- gemessen eine harte
    Kante, auch mit 128 und 256 px Uebergang.
    Bearbeitungsmodelle (FLUX 3, Qwen-Image 2.1, Boogu Edit, HiDream-O1): bekommen das Bild mit
    grauem Rand als Referenz und fuehren die Szene weiter (_outpaint_passes). Rand auf beiden
    Achsen geht in zwei Durchgaengen: Rundum zoomte FLUX 3 um 25-42 % ins Bild, statt den Rahmen zu
    fuellen (der Upsampler beschreibt dann nur das innere Bild); je Achse blieb es bei Faktor
    0,98-1,015. Nach jedem Durchgang misst outpaint_align.py den Versatz und legt das Original
    deckungsgleich zurueck.
    """
    feats = registry.features_for(entry)
    by_reference = feats.get("references", 0) > 0
    if not by_reference and not feats.get("mask"):
        raise RuntimeError(t(
            f"'{_name(entry)}' kann nicht erweitern. FLUX 3 liefert dafuer die nahtlosesten "
            "Uebergaenge, Qwen-Image-2512 voll geht auch.",
            f"'{_name(entry)}' cannot extend images. FLUX 3 gives the most seamless transitions; "
            "the full Qwen-Image-2512 works too.",
        ))
    source_id = ref_ids[0] if by_reference and ref_ids else p.get("image_asset_id")
    if not source_id:
        raise RuntimeError(t("Outpainting braucht ein Ausgangsbild (image_asset_id).",
                             "Outpainting needs a source image (image_asset_id)."))
    if p.get("mask_asset_id"):
        raise RuntimeError(t("Outpainting und eigene Maske gehen nicht zusammen.",
                             "Outpainting and a custom mask cannot be combined."))
    if len(ref_ids) > 1:
        raise RuntimeError(t("Outpainting nimmt genau ein Bild, keine weiteren Referenzen.",
                             "Outpainting takes exactly one image, no further references."))
    asset = db.get_asset(source_id)
    dims = imagesize.size(config.ASSET_DIR / asset.filename) if asset else None
    if dims is None:
        raise RuntimeError(t("Groesse des Ausgangsbildes nicht lesbar (PNG, JPEG oder WebP).",
                             "Cannot read the source image size (PNG, JPEG or WebP)."))
    left, top, right, bottom = (int(v) for v in p["outpaint"])
    # Auf Vielfache von 16 runden: das verlangen FLUX-artige Latents, und die paar
    # Pixel Abweichung gleicht das ImageScale nach dem Rand aus.
    width = max(256, round((dims[0] + left + right) / 16) * 16)
    height = max(256, round((dims[1] + top + bottom) / 16) * 16)
    if width > 2560 or height > 2560:
        raise RuntimeError(t(
            f"Erweitert waere das Bild {width} x {height} px, erlaubt sind hoechstens 2560. "
            "Weniger Rand waehlen oder das Bild vorher verkleinern.",
            f"Extended, the image would be {width} x {height} px; at most 2560 is allowed. "
            "Choose a smaller border or scale the image down first.",
        ))
    p["outpaint"] = [left, top, right, bottom]
    p["width"], p["height"] = width, height
    p["denoise"] = 1.0
    if not by_reference:
        return

    p["outpaint_original"] = p["reference_images"][0]
    both_axes = (left or right) and (top or bottom)
    p["outpaint_passes"] = ([[left, 0, right, 0], [0, top, 0, bottom]] if both_axes
                            else [[left, top, right, bottom]])
    if not p["prompt"].startswith(OUTPAINT_INSTRUCTION):
        p["prompt"] = f"{OUTPAINT_INSTRUCTION} {p['prompt']}".strip()


# Fuellen mit Bearbeitungsmodellen: der Maskenbereich ist grau, diese Anweisung steht vor dem Prompt.
INPAINT_INSTRUCTION = ("Fill the flat grey area with new content that blends seamlessly into the picture, "
                       "with the same light, perspective and style, and keep everything outside the grey "
                       "area unchanged.")
# So viele Pixel bekommt der Ausschnitt um die Maske beim Fuellen (FLUX 3 rechnet nativ bei 1 MP);
# kleine Masken werden dafuer vergroessert, grosse verkleinert, eingesetzt wird in Originalgroesse.
INPAINT_PIXELS = 1_000_000


async def _prepare_inpaint_reference(p: dict[str, Any], ref_ids: list[str]) -> None:
    """Fuellen (Maske) mit einem Bearbeitungsmodell wie FLUX 3, das selbst keine Maske nimmt.

    Wie beim Erweitern: Ein Ausschnitt um die Maske (35 % Umgebung) kommt mit grau gefaerbtem
    Maskenbereich als Referenz, davor INPAINT_INSTRUCTION. Danach misst outpaint_align.py den Versatz
    ausserhalb des Graus (FLUX gibt das Bild nie pixelgenau wieder), rueckt das Ergebnis zurueck und
    setzt nur den Maskenbereich mit weichem Rand ein; ausserhalb bleibt das Bild pixelgleich
    (_inpaint_by_reference). Gemessen am Fischmarkt: Kisten entfernt mit durchlaufendem Pflaster,
    Moewe aufs Wasser gesetzt. Vorhandenes umschreiben (Schild) gelingt besser ohne Grau, als
    Bearbeitung mit Referenzbild ("Ueberarbeiten" im Add-on); grau malte FLUX ein neues Schild.
    """
    if len(ref_ids) != 1 or p.get("image_asset_id"):
        raise RuntimeError(t("Fuellen mit einer Maske nimmt genau ein Bild (image_asset_id), keine "
                             "weiteren Referenzen.",
                             "Filling with a mask takes exactly one image (image_asset_id), no further "
                             "references."))
    asset = db.get_asset(ref_ids[0])
    dims = imagesize.size(config.ASSET_DIR / asset.filename) if asset else None
    if dims is None:
        raise RuntimeError(t("Groesse des Ausgangsbildes nicht lesbar (PNG, JPEG oder WebP).",
                             "Cannot read the source image size (PNG, JPEG or WebP)."))
    mask = _stage_image(p["mask_asset_id"], t("Maske", "Mask"))
    original = p["reference_images"][0]
    input_dir = config.COMFY_ROOT / "input"
    grey = input_dir / f"nvai_fill_{uuid.uuid4().hex[:8]}.png"
    try:
        prep = await _align_script(grey, "--inpaint-prepare", input_dir / original, input_dir / mask, grey)
    except RuntimeError as exc:
        if "Maske ist leer" in str(exc):
            raise RuntimeError(t("Die Maske ist leer: weiss markiert, was neu entstehen soll.",
                                 "The mask is empty: white marks what should be created anew.")) from exc
        raise
    cw, ch = prep["size"]
    scale = (INPAINT_PIXELS / (cw * ch)) ** 0.5
    p["width"] = min(2048, max(256, round(cw * scale / 16) * 16))
    p["height"] = min(2048, max(256, round(ch * scale / 16) * 16))
    p["reference_images"] = [grey.name]
    p["inpaint_reference"] = {"original": original, "mask": mask, "size": list(dims)}
    prompt = p.get("prompt", "").strip()
    if not prompt.startswith(INPAINT_INSTRUCTION):
        p["prompt"] = (f"{INPAINT_INSTRUCTION} Fill it with: {prompt}" if prompt else
                       f"{INPAINT_INSTRUCTION} Continue the surrounding scene so that the area fits in naturally.")


@register("txt2img")
async def _txt2img(job: Job, ctx: JobContext) -> list[str]:
    p = job.params
    entry = _resolve_model(p, "image")
    wf = entry["workflow"]
    is_flux3 = wf in workflows.FLUX3_WORKFLOWS

    # FLUX 3 und Qwen-Image 2.1 bearbeiten ueber Referenzbilder, nicht ueber ein
    # angerauschtes Startbild -- dafuer sind sie trainiert. Ein Startbild wird dort
    # deshalb zur ersten Referenz.
    feats = registry.features_for(entry)
    by_reference = feats.get("references", 0) > 0
    style_refs = feats.get("reference_kind") == "style"
    ref_ids = [a for a in (p.get("reference_asset_ids") or []) if a]
    # Stil-Referenzen (Krea 2) bearbeiten nichts: Ein Startbild bleibt dort Bild-zu-Bild.
    if by_reference and not style_refs and p.get("image_asset_id") and not ref_ids:
        ref_ids = [p.pop("image_asset_id")]
    if ref_ids and not by_reference and "style_reference" in (feats.get("missing") or {}):
        raise RuntimeError(t(
            f"'{_name(entry)}' nimmt Referenzbilder als Stilvorlage erst mit der Stil-LoRA von ostris "
            "(0,46 GB): unter „Modelle“ beim Modell „Zusätze laden“.",
            f"'{_name(entry)}' takes reference images as a style template only with ostris' style LoRA "
            "(0.46 GB): “Download extras” for the model under “Models”.",
        ))
    if ref_ids and not by_reference:
        raise RuntimeError(t(
            f"Referenzbilder verarbeiten nur Modelle mit Referenzbild-Unterstuetzung (FLUX 3, "
            f"Qwen-Image 2.1, Boogu-Image Edit, HiDream-O1; Krea 2 als Stilvorlage), nicht '{_name(entry)}'. "
            "Fuer ein vorhandenes Bild als Ausgangspunkt: image_asset_id mit denoise.",
            f"Only models with reference support (FLUX 3, Qwen-Image 2.1, Boogu-Image Edit, "
            f"HiDream-O1; Krea 2 as a style template) process reference images, not '{_name(entry)}'. "
            "To start from an existing image: image_asset_id with denoise.",
        ))
    max_refs = min(flux3_prompt.MAX_REFERENCES, feats.get("references") or flux3_prompt.MAX_REFERENCES)
    if len(ref_ids) > max_refs:
        raise RuntimeError(t(f"Hoechstens {max_refs} Referenzbilder.",
                             f"At most {max_refs} reference images."))
    if ref_ids:
        p["reference_images"] = [
            _stage_image(a, t(f"Referenzbild {i + 1}", f"Reference image {i + 1}"))
            for i, a in enumerate(ref_ids)
        ]

    if p.get("image_asset_id"):
        p["start_image"] = _stage_image(p["image_asset_id"], t("Startbild", "Start image"))

    # Inpainting: Die Maske legt fest, wo neu gerechnet wird (weiss) und wo das Startbild
    # bleibt (schwarz). Maskenmodelle haengen sie am Startbild-Pfad an; Bearbeitungsmodelle
    # (features.mask == "reference", FLUX 3) fuellen ueber ein grau markiertes Referenzbild.
    mask_mode = registry.features_for(entry).get("mask") if p.get("mask_asset_id") else None
    if p.get("mask_asset_id") and not mask_mode:
        raise RuntimeError(t(f"'{_name(entry)}' kann keine Masken (Inpainting).",
                             f"'{_name(entry)}' cannot use masks (inpainting)."))
    if mask_mode == "reference":
        if any(p.get("outpaint") or []):
            raise RuntimeError(t("Outpainting und eigene Maske gehen nicht zusammen.",
                                 "Outpainting and a custom mask cannot be combined."))
        await _prepare_inpaint_reference(p, ref_ids)
    elif mask_mode:
        if not p.get("start_image"):
            raise RuntimeError(t(
                "Eine Maske (mask_asset_id) braucht ein Ausgangsbild (image_asset_id).",
                "A mask (mask_asset_id) needs a source image (image_asset_id).",
            ))
        p["mask_image"] = _stage_image(p["mask_asset_id"], t("Maske", "Mask"))

    if any(p.get("outpaint") or []):
        await _prepare_outpaint(p, entry, ref_ids, ctx)
    else:
        p["outpaint"] = None

    # Qwens Modellkarte rechnet mit ihrem Negativprompt. Hier eingesetzt statt erst im
    # Builder, damit er in den Asset-Metadaten steht.
    if wf == "qwen_image" and not p.get("negative_prompt"):
        p["negative_prompt"] = workflows.QWEN_IMAGE_NEGATIVE

    # Beim Outpainting per Referenz baut jeder Durchgang seinen Prompt selbst aus (_outpaint_passes).
    # Beim Fuellen beschreibt der Upsampler das grau markierte Bild: eigener Cache-Schluessel.
    caption_ids = [f"fill:{p['reference_images'][0]}"] if p.get("inpaint_reference") else ref_ids
    caption_meta = (await _flux3_caption(p, entry, caption_ids, ctx)
                    if is_flux3 and not p.get("outpaint_passes") else {})
    if wf == "moss_image":
        # Wie bei Qwen: der empfohlene Negativprompt soll in den Asset-Metadaten stehen.
        if not p.get("negative_prompt"):
            p["negative_prompt"] = workflows.MOSS_IMAGE_NEGATIVE
        caption_meta = await _moss_caption(p, entry, ctx)

    # ControlNet: Modelldatei aufloesen und Referenzbild bereitstellen. Beides muss
    # da sein -- sonst laesst der Builder das ControlNet stillschweigend weg.
    cn_id = p.get("controlnet_model_id")
    if cn_id:
        cn_entry = registry.get_entry(cn_id)
        if cn_entry is None:
            raise RuntimeError(t(f"Unbekanntes ControlNet: {cn_id}",
                                 f"Unknown ControlNet: {cn_id}"))
        if not registry.is_installed(cn_entry):
            raise RuntimeError(t(
                f"ControlNet '{_name(cn_entry)}' ist nicht heruntergeladen.",
                f"ControlNet '{_name(cn_entry)}' is not downloaded.",
            ))
        # ControlNets sind an die Architektur gebunden. Ein SD3-Netz an einem
        # Chroma- oder FLUX-Modell laedt entweder gar nicht oder liefert Matsch --
        # lieber hier klar abbrechen.
        img_entry = _resolve_model(p, "image")
        if cn_entry.get("family") != img_entry.get("family"):
            raise RuntimeError(t(
                f"'{_name(cn_entry)}' passt nicht zu '{_name(img_entry)}': "
                f"ControlNets funktionieren nur mit der Modellfamilie, fuer die sie "
                f"trainiert wurden ({cn_entry.get('family')} statt "
                f"{img_entry.get('family')}).",
                f"'{_name(cn_entry)}' does not match '{_name(img_entry)}': "
                f"ControlNets only work with the model family they were trained for "
                f"({cn_entry.get('family')} instead of {img_entry.get('family')}).",
            ))
        if not p.get("controlnet_image_asset_id"):
            raise RuntimeError(t(
                "Fuer ein ControlNet wird ein Referenzbild gebraucht "
                "(controlnet_image_asset_id).",
                "A ControlNet needs a reference image (controlnet_image_asset_id).",
            ))
        p["controlnet_file"] = workflows.file_name(cn_entry["files"][0])
        p["controlnet_image"] = _stage_image(
            p["controlnet_image_asset_id"],
            t("ControlNet-Referenzbild", "ControlNet reference image"),
        )

    return await _run_generation(job, ctx, "image", {
        "width": p.get("width"), "height": p.get("height"),
        "sampler": p.get("sampler"), "scheduler": p.get("scheduler"),
        "hires": bool(p.get("hires")),
        "hires_scale": p.get("hires_scale") if p.get("hires") else None,
        "hires_denoise": p.get("hires_denoise") if p.get("hires") else None,
        "slg": bool(p.get("slg")),
        "slg_scale": p.get("slg_scale") if p.get("slg") else None,
        "image_asset_id": p.get("image_asset_id"),
        "denoise": p.get("denoise") if p.get("image_asset_id") else None,
        "mask_asset_id": p.get("mask_asset_id"),
        "outpaint": p.get("outpaint"),
        "controlnet_model_id": cn_id,
        "controlnet_strength": p.get("controlnet_strength") if cn_id else None,
        "reference_asset_ids": ref_ids or None,
        **caption_meta,
    })


# ------------------------------------------------------- Foto restaurieren

# Anweisungen an das Bearbeitungsmodell; die Hinweise des Nutzers (notes) haengen hinten an.
RESTORE_REPAIR = (
    "Restore this old damaged photograph: remove all scratches, dust spots, cracks, stains, creases, tears "
    "and emulsion damage, and fill damaged areas so they blend in seamlessly. Keep the composition, every "
    "person, their faces, expressions, poses and clothing, and the original tones of the photograph exactly "
    "the same.")
RESTORE_COLORIZE = (
    "Colorize this black-and-white photograph with natural, realistic colors. Keep the composition, every "
    "person, their faces, expressions and poses and every detail exactly the same.")
# Arbeitsgroesse des Bearbeitungsmodells (Referenzbild und Ausgabe gleich gross): so gross wie das Foto,
# mindestens 1 MP (darauf ist FLUX 3 trainiert), hoechstens dieser Wert. Einfaerben braucht weniger: Von dort
# kommt nur die Farbe, die Helligkeit behaelt die volle Aufloesung.
RESTORE_MEGAPIXELS = 2.0
COLORIZE_MEGAPIXELS = 1.0
# Darunter hat das Modell das Bild umgebaut statt nur bereinigt: nicht verschieben, nur skalieren.
RESTORE_MIN_SCORE = 0.5
# Automatisch (Vorgabe): Der Upsampler von FLUX 3 (Qwen3.5-9B, sieht das Foto) beantwortet vor dem Lauf diese
# Frage. Ja -> gruendlich, nein -> schonend. Sie fragt genau nach dem, was schonend nicht erkennt. Gemessen an
# 21 Testfotos (25.10.2026): 20 wie erwartet (alle 8 stark gealterten ja, alle 8 leicht gealterten nein,
# Ferrotypie ja, Baseballspieler, Iwo Jima und Flugzeugwrack nein; nur die Tauben in Paris ja, dort waere
# schonend schaerfer gewesen). Der Wortlaut zaehlt: "Does this photograph show ...?" traf 18, "Is this photograph
# damaged by ...?" nur 14 von 21; "OVERALL oder SEPARATE" bekam 16-mal OVERALL. Rund 2,5 s.
RESTORE_KIND_SYSTEM = "You are an expert in restoring old photographs. Answer with one word: yes or no."
RESTORE_KIND_QUESTION = ("Are there water stains, rings left by water, or crack networks (craquelure) in this "
                         "photograph? Answer yes or no.")


def _restore_model(p: dict[str, Any]) -> dict[str, Any]:
    """Bearbeitungsmodell fuer Schaeden und Farbe: das gewaehlte, sonst FLUX 3 (destilliert) vor den
    anderen Modellen mit Referenzbildern; Stilvorlagen (Krea 2) bearbeiten nichts."""
    def edits(e: dict[str, Any]) -> bool:
        f = registry.features_for(e)
        return (f.get("references") or 0) > 0 and f.get("reference_kind") != "style"

    if p.get("model_id"):
        entry = _resolve_model({"model_id": p["model_id"]}, "image")
        if not edits(entry):
            raise RuntimeError(t(
                f"'{_name(entry)}' bearbeitet keine Bilder. Restaurieren und Einfärben brauchen ein Modell mit "
                "Referenzbildern, am besten FLUX 3.",
                f"'{_name(entry)}' does not edit images. Restoring and colorizing need a model with reference "
                "images, ideally FLUX 3."))
        return entry
    candidates = [e for e in registry.all_entries()
                  if e.get("kind") == "image" and e.get("workflow") and registry.is_installed(e) and edits(e)]
    if not candidates:
        raise RuntimeError(t(
            "Restaurieren und Einfärben brauchen ein Bearbeitungsmodell: bitte FLUX 3 Image Klein laden "
            "(flux3-klein-nvfp4 auf RTX 50, sonst flux3-klein-int8).",
            "Restoring and colorizing need an editing model: please download FLUX 3 Image Klein "
            "(flux3-klein-nvfp4 on RTX 50, otherwise flux3-klein-int8)."))
    active = registry.get_active_model("image")
    candidates.sort(key=lambda e: (e["workflow"] != "flux3_klein", e["workflow"] not in workflows.FLUX3_WORKFLOWS,
                                   e["id"] != active, not registry.gpu_advice(e).get("recommended")))
    return candidates[0]


def _restore_size(dims: tuple[int, int], megapixels: float) -> tuple[int, int]:
    """Arbeitsformat im Seitenverhaeltnis des Fotos: Vielfache von 16, je Seite hoechstens 2048."""
    w0, h0 = dims
    target = min(megapixels, max(1.0, w0 * h0 / 2 ** 20)) * 2 ** 20
    k = min((target / (w0 * h0)) ** 0.5, 2048 / max(w0, h0))
    return max(256, round(w0 * k / 16) * 16), max(256, round(h0 * k / 16) * 16)


async def _restore_script(target: Path, *args: Any) -> dict[str, Any]:
    """restore_tools.py im ComfyUI-venv aufrufen (numpy, Pillow, scipy); `target` muss danach existieren."""
    script = Path(__file__).with_name("restore_tools.py")
    proc = await asyncio.create_subprocess_exec(
        str(comfy.comfy_python()), "-I", str(script), *(str(a) for a in args),
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    out, err = await proc.communicate()
    if proc.returncode != 0 or not target.exists():
        raise RuntimeError(t(f"Bildbearbeitung fehlgeschlagen: {err.decode(errors='replace')[-300:]}",
                             f"Image processing failed: {err.decode(errors='replace')[-300:]}"))
    return json.loads(out.decode().strip().splitlines()[-1])


async def _restore_kind(ref: str, source_id: str, ctx: JobContext) -> dict[str, Any]:
    """Automatisch: Fragt den Upsampler nach Wasserflecken und Rissnetzen (RESTORE_KIND_QUESTION).
    "no" -> schonend, alles andere -> gruendlich (auch ohne Upsampler oder bei unklarer Antwort: gruendlich
    laesst keine Schaeden stehen). Die Antwort wird je Foto zwischengespeichert."""
    upsampler = prompt_upsampler()
    if upsampler is None:
        return {"auto": "thorough", "answer": None}
    upsampler_file = workflows.file_name(upsampler)
    cache_key = flux3_prompt.cache_key(upsampler_file, "restore_kind", RESTORE_KIND_QUESTION, [source_id])
    answer = flux3_prompt.cache_get(cache_key)
    if answer is None:
        if comfy.text_backend() is comfy.MAIN:
            await _ensure_backend(ctx)
        graph = flux3_prompt.build_graph(upsampler_file, "i2i", RESTORE_KIND_QUESTION, [ref],
                                         system_text=RESTORE_KIND_SYSTEM)
        graph["3"]["inputs"]["max_length"] = 8
        texts = await comfy.run_text_workflow(graph)
        answer = (texts[-1] if texts else "").strip()
        flux3_prompt.cache_put(cache_key, answer)
    gentle = answer.lower().lstrip("\"'“„ ").startswith("no")
    return {"auto": "gentle" if gentle else "thorough", "answer": answer[:80]}


@register("restore")
async def _restore(job: Job, ctx: JobContext) -> list[str]:
    """Foto restaurieren (seit 0.5.11): Schaeden entfernen, einfaerben, schaerfen -- je Schritt schaltbar.

    1. Schaeden: Das Bearbeitungsmodell (FLUX 3) rechnet das Foto mit RESTORE_REPAIR neu; restore_tools.py
       --align rueckt das Ergebnis deckungsgleich aufs Original (FLUX gibt ein Bild nie pixelgenau wieder).
       Gruendlich nimmt das ganze Bild vom Modell (in dessen Arbeitsgroesse). Schonend setzt --merge nur die
       gefundenen Schaeden ins Foto in voller Aufloesung ein: Beim Baseballspieler von 1911 aenderte FLUX in
       einer von zwei Varianten das Gesicht (breiter, anderes Laecheln); schonend blieb es das des Originals.
       Kontrast und Verblassen kommen dabei von FLUX. Gemessen an Testfotos mit bekannter Vorlage (SSIM der
       Helligkeit, Viertelgroesse): stark beschaedigt unbearbeitet 0,601, schonend 0,648, gruendlich 0,689 --
       schonend liess Craquele, feine Kratzer und Wasserraender stehen (Nutzer: „schaut nur eingefaerbt aus“);
       leicht beschaedigt 0,921 / 0,932 / 0,911 -- gruendlich zeichnete Gesichter in Gruppen anders. Es kommt auf
       die Art des Schadens an. Automatisch (Vorgabe) fragt deshalb vorher den Upsampler nach Wasserflecken und
       Rissnetzen (_restore_kind). Verworfen, weil sie die Art nicht trafen: die Schadflaeche von --merge (der
       echte Baseballspieler lag mit 3,1-4,6 % zwischen leicht 0,5-0,9 und stark 5,2-10,4 %), Korn, Feindetail-
       Anteil und -Korrelation zwischen Foto und FLUX, ein zweiter Erkennungslauf auf dem schonenden Ergebnis.
    2. Farbe: FLUX 3 faerbt ein, uebernommen wird nur die Farbe (Lab a/b) -- auf die Helligkeit des Fotos in
       voller Aufloesung bzw. des restaurierten Bildes. Gesichter und Detail bleiben so exakt erhalten;
       gemessen am Baseballspieler von 1911: FLUX allein glaettete Haut und Laecheln, mit der Uebertragung
       blieb das Gesicht das des Originals.
    3. Schaerfen: SeedVR2 bringt jede Variante auf Foto x scale (hoechstens features.max_pixels).
    """
    p = job.params
    repair, colorize, sharpen = bool(p.get("repair")), bool(p.get("colorize")), bool(p.get("sharpen"))
    if not (repair or colorize or sharpen):
        raise RuntimeError(t("Bitte mindestens einen Schritt wählen: Schäden entfernen, Einfärben oder Schärfen.",
                             "Please choose at least one step: remove damage, colorize or sharpen."))
    source = db.get_asset(p["image_asset_id"])
    src = config.ASSET_DIR / source.filename if source else None
    dims = imagesize.size(src) if src and src.exists() else None
    if dims is None:
        raise RuntimeError(t("Foto nicht gefunden oder nicht lesbar (PNG, JPEG oder WebP).",
                             "Photo not found or not readable (PNG, JPEG or WebP)."))
    edit = _restore_model(p) if repair or colorize else None
    sharp = _resolve_model({"model_id": p.get("upscale_model_id")}, "upscale") if sharpen else None
    if sharp is not None and sharp.get("workflow") not in workflows.UPSCALE_WORKFLOWS:
        raise RuntimeError(t(f"'{_name(sharp)}' ist kein Modell zum Schärfen.",
                             f"'{_name(sharp)}' is not a model for sharpening."))
    await _ensure_backend(ctx)

    batch = int(p.get("batch_size") or 1)
    seed = int(p["seed"]) if p.get("seed") is not None else random.randint(0, 2 ** 31 - 1)
    notes = (p.get("notes") or "").strip()
    # Nur Schaerfen kennt keine Varianten: SeedVR2 rechnet dasselbe Foto mit jedem Seed fast gleich.
    if sharpen and not (repair or colorize):
        batch = 1
    # Laeufe fuer den Fortschrittsbalken: ein Modelllauf je Schritt, Einfaerben nach dem Restaurieren und
    # Schaerfen je Variante.
    runs = int(repair) + (batch if colorize and repair else int(colorize)) + (batch if sharpen else 0)
    done = 0
    meta: dict[str, Any] = {"restore": {"repair": repair, "colorize": colorize, "sharpen": sharpen},
                            "source_asset_id": source.id, "source_size": list(dims)}
    timings: dict[str, float] = {}

    def progress(stage: str) -> Callable[[float, str], None]:
        def on_progress(frac: float, step: str) -> None:
            ctx.progress(0.02 + 0.94 * (done + frac) / runs, f"{stage} · {step}")
        return on_progress

    async def edit_run(instruction: str, ref: str, dims_ref: tuple[int, int], megapixels: float, n: int,
                       run_seed: int, cache_id: str, stage: str) -> tuple[list[Path], dict[str, Any]]:
        """Ein Lauf des Bearbeitungsmodells mit dem Foto als Referenz; Ergebnisse in data/assets/."""
        width, height = _restore_size(dims_ref, megapixels)
        prompt = f"{instruction} {notes}".strip()
        pp: dict[str, Any] = {"prompt": prompt, "negative_prompt": "", "reference_images": [ref],
                              "width": width, "height": height, "batch_size": n, "seed": run_seed,
                              "reference_megapixels": round(width * height / 2 ** 20, 2),
                              "upsample_prompt": p.get("upsample_prompt")}
        info: dict[str, Any] = {"width": width, "height": height}
        if edit["workflow"] in workflows.FLUX3_WORKFLOWS:
            ctx.progress(0.02 + 0.94 * done / runs, t(f"{stage} · Upsampler baut die Anweisung aus",
                                                      f"{stage} · upsampler is expanding the instruction"))
            info |= await _flux3_caption(pp, edit, [cache_id], ctx)
        graph, _ = workflows.build(edit, pp)
        comfy.set_loaded_model(_name(edit))
        t0 = time.time()
        outs = await comfy.run_workflow(graph, on_progress=progress(stage), timeout=900.0)
        if not outs:
            raise RuntimeError(t("ComfyUI lieferte kein Bild zurück.", "ComfyUI returned no image."))
        info["seconds"] = round(time.time() - t0, 1)
        return outs, info

    async def align(path: Path, original: Path) -> dict[str, Any]:
        tmp = path.with_name(path.stem + "_al.png")
        info = await _restore_script(tmp, "--align", path, original, tmp, RESTORE_MIN_SCORE)
        tmp.replace(path)
        return info

    made: list[Path] = []          # alles, was dieser Auftrag in data/assets/ anlegt
    current: list[Path] = []       # Ergebnis je Variante nach dem letzten Schritt
    try:
        # 1) Schaeden entfernen
        if repair:
            t0 = time.time()
            ref = comfy.stage_input(src)
            mode = p.get("repair_mode") or "auto"
            kind: dict[str, Any] = {}
            if mode == "auto":
                ctx.progress(0.02 + 0.94 * done / runs, t("Schäden entfernen · prüft die Art der Schäden",
                                                          "Removing damage · checking the kind of damage"))
                kind = await _restore_kind(ref, source.id, ctx)
            outs, info = await edit_run(RESTORE_REPAIR, ref, dims, float(p.get("megapixels") or RESTORE_MEGAPIXELS),
                                        batch, seed, f"restore:{source.id}", t("Schäden entfernen", "Removing damage"))
            made += outs
            current = outs
            info["align"] = [await align(out, src) for out in outs]
            info["mode"] = mode
            if kind:
                info["auto"], info["auto_answer"] = kind["auto"], kind["answer"]
            if kind.get("auto", mode) == "gentle":
                # Schonend: Foto in voller Aufloesung, nur die Schaeden aus dem Ergebnis des Modells.
                ctx.progress(0.02 + 0.94 * (done + 0.98) / runs, t("Schäden entfernen · setzt ein",
                                                                   "Removing damage · merging"))
                merged = []
                for out in outs:
                    target = config.ASSET_DIR / f"{uuid.uuid4().hex[:12]}_nvai_restored.png"
                    made.append(target)
                    info.setdefault("merge", []).append(await _restore_script(target, "--merge", out, src, target))
                    merged.append(target)
                current = merged
            meta["repair"] = info
            timings["repair"] = round(time.time() - t0, 1)
            done += 1

        # 2) Einfaerben: Farbe vom Modell, Helligkeit vom Foto bzw. vom restaurierten Bild
        if colorize:
            t0 = time.time()
            stage = t("Einfärben", "Colorizing")
            # Je Variante: das restaurierte Bild einzeln einfaerben; ohne Restaurieren alle Varianten in einem Lauf.
            pairs: list[tuple[Path, Path]] = []      # (eingefaerbt, Helligkeitsquelle)
            infos: list[dict[str, Any]] = []
            if repair:
                for k, base in enumerate(current):
                    ref = comfy.stage_input(base)
                    outs, info = await edit_run(RESTORE_COLORIZE, ref, imagesize.size(base) or dims,
                                                COLORIZE_MEGAPIXELS, 1, seed + 101 + k, f"colorize:{ref}", stage)
                    made += outs
                    pairs.append((outs[0], base))
                    infos.append(info)
                    done += 1
            else:
                outs, info = await edit_run(RESTORE_COLORIZE, comfy.stage_input(src), dims, COLORIZE_MEGAPIXELS,
                                            batch, seed, f"colorize:{source.id}", stage)
                made += outs
                pairs = [(out, src) for out in outs]
                infos = [info] * len(outs)
                done += 1
            ctx.progress(0.02 + 0.94 * done / runs, t(f"{stage} · überträgt die Farbe",
                                                      f"{stage} · transferring the color"))
            results: list[Path] = []
            for (color, base), info in zip(pairs, infos):
                aligned = await align(color, base)
                target = config.ASSET_DIR / f"{uuid.uuid4().hex[:12]}_nvai_color.png"
                made.append(target)
                transfer = await _restore_script(target, "--colorize", color, base, target)
                info.setdefault("align", []).append(aligned)
                info.setdefault("transfer", []).append(transfer)
                results.append(target)
            current = results
            meta["colorize"] = infos if repair else infos[0]
            timings["colorize"] = round(time.time() - t0, 1)

        # 3) Schaerfen und vergroessern: auf Foto x scale, hoechstens max_pixels
        if sharpen:
            t0 = time.time()
            feats = registry.features_for(sharp)
            scale = float(p.get("scale") or feats.get("scale") or 2.0)
            width, height = round(dims[0] * scale), round(dims[1] * scale)
            limit = float(feats.get("max_pixels") or 16_000_000)
            if width * height > limit:
                k = (limit / (width * height)) ** 0.5
                width, height = int(width * k), int(height * k)
            stage = t("Schärfen", "Sharpening")
            results = []
            for k, base in enumerate(current or [src]):
                graph = workflows.seedvr2_graph(sharp, comfy.stage_input(base), width, height, seed + 201 + k)
                comfy.set_loaded_model(_name(sharp))
                outs = await comfy.run_workflow(graph, on_progress=progress(stage), timeout=1800.0)
                made += outs
                if not outs:
                    raise RuntimeError(t("ComfyUI lieferte kein Bild zurück.", "ComfyUI returned no image."))
                results.append(outs[0])
                done += 1
            current = results
            meta["sharpen"] = {"model_id": sharp["id"], "width": width, "height": height, "scale": scale}
            timings["sharpen"] = round(time.time() - t0, 1)
    except BaseException:
        for path in made:
            path.unlink(missing_ok=True)
        raise
    for path in made:
        if path not in current:
            path.unlink(missing_ok=True)

    ctx.progress(0.99, t("speichert", "saving"))
    # Im Verlauf soll stehen, wie restauriert wurde (bei "auto" die getroffene Wahl): gruendlich und schonend
    # sehen verschieden aus.
    used = (meta.get("repair") or {}).get("auto") or (meta.get("repair") or {}).get("mode")
    repaired = {"thorough": t("gründlich restauriert", "restored thoroughly"),
                "gentle": t("schonend restauriert", "restored gently")}.get(used, t("restauriert", "restored"))
    steps = [name for name, on in ((repaired, repair), (t("eingefärbt", "colorized"), colorize),
                                   (t("geschärft", "sharpened"), sharpen)) if on]
    label = t("Foto ", "Photo ") + ", ".join(steps)
    model = edit or sharp
    asset_ids = []
    for k, path in enumerate(current):
        size = imagesize.size(path)
        asset = db.create_asset(
            kind="image", filename=path.name, job_id=job.id,
            prompt=f"{label}: {notes}" if notes else label, model_id=model["id"],
            meta={**meta, "seed": seed, "model_name": _name(model),
                  "upscale_model_name": _name(sharp) if sharp else None, "notes": notes,
                  "width": size[0] if size else None, "height": size[1] if size else None,
                  "variant": k + 1, "seconds": timings})
        asset_ids.append(asset.id)
    return asset_ids


@register("txt2audio")
async def _txt2audio(job: Job, ctx: JobContext) -> list[str]:
    p = job.params
    return await _run_generation(job, ctx, "audio", {
        "seconds": p.get("seconds"), "lyrics": p.get("lyrics", ""), "bpm": p.get("bpm"),
    })


def _check_video_options(p: dict[str, Any], entry: dict[str, Any]) -> None:
    """Die Zusatzwege von LTX-2.5 (features des Modells) nur dort, wo es sie gibt -- und mit einer
    Meldung, die sagt, was fehlt, statt eines ComfyUI-Fehlers mitten im Lauf."""
    feats = registry.features_for(entry)
    asked = [k for k, v in (("end_image", p.get("end_image_asset_id") or p.get("loop")),
                            ("dfr", p.get("quality") == "dfr"),
                            ("temporal_upscale", p.get("temporal_upscale")),
                            ("auto_duration", p.get("auto_duration")),
                            ("audio_input", p.get("audio_asset_id")),
                            ("motion_speed", float(p.get("motion_speed") or 1.0) < 1.0)) if v]
    if asked and entry.get("family") != "ltx25":
        raise RuntimeError(t(
            f"{_name(entry)} kann das nicht ({', '.join(asked)}) — das geht mit LTX-2.5.",
            f"{_name(entry)} cannot do that ({', '.join(asked)}) — LTX-2.5 can."))
    missing = feats.get("missing") or {}
    texts = {
        "dfr": t("Für „Höchste Qualität (DFR)“ fehlt das Detail-IC-LoRA",
                 "“Best quality (DFR)” needs the detail IC-LoRA"),
        "temporal_upscale": t("Für 48 fps fehlt der zeitliche Hochskalierer",
                              "48 fps needs the temporal upscaler"),
        "auto_duration": t("Für „Länge automatisch“ fehlt der Längenkopf",
                           "“Automatic length” needs the duration head"),
    }
    for name in asked:
        if name in texts and not feats.get(name):
            url = missing.get(name, "")
            raise RuntimeError(texts[name] + t(
                f". Lizenz auf {url} akzeptieren und unter „Modelle“ bei LTX-2.5 „Zusätze laden“ "
                "(lädt nur, was fehlt).",
                f". Accept the license on {url} and use “Download extras” for LTX-2.5 under “Models” "
                "(only what is missing is downloaded)."))
    if p.get("temporal_upscale") and p.get("quality") != "dfr":
        raise RuntimeError(t("48 fps (zeitlich verdoppelt) gibt es nur mit „Höchste Qualität (DFR)“.",
                             "48 fps (temporal upscale) is only available with “Best quality (DFR)”."))
    if (p.get("end_image_asset_id") or p.get("loop")) and p.get("quality") == "dfr":
        raise RuntimeError(t("Start- und Endbild bzw. Schleife gehen nur ohne DFR.",
                             "Start and end image or a loop only work without DFR."))


AUDIO_UPLOAD_SUFFIXES = {".wav", ".mp3", ".flac", ".ogg", ".m4a", ".aac", ".opus"}


def _stage_audio(asset_id: str) -> tuple[str, float | None]:
    """Ton-Asset nach ComfyUIs input/ (LoadAudio) und seine Laenge in Sekunden, soweit bekannt:
    aus den Metadaten der Erzeugung, bei WAV aus dem Dateikopf. Auch ein hochgeladener Ton geht (Nutzer 27.10.:
    eine schon abgenommene Stimme einem neuen Clip vorgeben, damit sie gleich klingt)."""
    asset = db.get_asset(asset_id)
    uploaded_audio = (asset is not None and asset.kind == "upload"
                      and Path(asset.filename).suffix.lower() in AUDIO_UPLOAD_SUFFIXES)
    if asset is None or not (asset.kind == "audio" or uploaded_audio):
        raise RuntimeError(t(f"Ton nicht gefunden: {asset_id}", f"Audio not found: {asset_id}"))
    src = config.ASSET_DIR / asset.filename
    if not src.exists():
        raise RuntimeError(t(f"Tondatei fehlt: {src}", f"Audio file missing: {src}"))
    seconds = (asset.meta or {}).get("seconds")
    if seconds is None and src.suffix.lower() == ".wav":
        import wave
        with contextlib.suppress(wave.Error, OSError), wave.open(str(src)) as w:
            seconds = w.getnframes() / float(w.getframerate())
    return comfy.stage_input(src), float(seconds) if seconds else None


async def _video_tool(*args: Any) -> dict[str, Any]:
    """video_tools.py im ComfyUI-venv (PyAV) aufrufen, wie _align_script; liefert dessen JSON-Zeile."""
    script = Path(__file__).with_name("video_tools.py")
    proc = await asyncio.create_subprocess_exec(
        str(comfy.comfy_python()), "-I", str(script), *(str(a) for a in args),
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    out, err = await proc.communicate()
    if proc.returncode != 0:
        raise RuntimeError(t(f"Videowerkzeug fehlgeschlagen: {err.decode(errors='replace')[-300:]}",
                             f"Video tool failed: {err.decode(errors='replace')[-300:]}"))
    return json.loads(out.decode().strip().splitlines()[-1])


async def _prepare_extension(job: Job, p: dict[str, Any], entry: dict[str, Any]) -> tuple[Any, Path]:
    """Video verlaengern (seit 0.5.10): Der letzte Frame des Originals wird Startbild, Format und Bildrate
    kommen vom Original, damit sich das neue Stueck nahtlos anfuegen laesst (_txt2video haengt es an)."""
    if entry.get("family") != "ltx25":
        raise RuntimeError(t("Verlängern geht mit LTX-2.5.", "Extending works with LTX-2.5."))
    if p.get("image_asset_id") or p.get("loop") or p.get("audio_asset_id"):
        raise RuntimeError(t(
            "Beim Verlängern ist der letzte Frame des Videos das Startbild; ein eigenes Startbild, eine "
            "Schleife oder ein vorgegebener Ton gehen dabei nicht.",
            "When extending, the last frame of the video is the start image; your own start image, a loop or "
            "a given sound cannot be used with it."))
    source = db.get_asset(p["extend_asset_id"])
    if source is None or source.kind != "video":
        raise RuntimeError(t(f"Video nicht gefunden: {p['extend_asset_id']}",
                             f"Video not found: {p['extend_asset_id']}"))
    path = config.ASSET_DIR / source.filename
    if not path.exists():
        raise RuntimeError(t(f"Videodatei fehlt: {path}", f"Video file missing: {path}"))
    info = await _video_tool("info", path)
    if info["fps"] > 30:
        # 48 fps entstehen nur mit DFR und zeitlicher Verdopplung; das neue Stueck muss dieselbe Rate haben.
        if not (p.get("quality") == "dfr" and p.get("temporal_upscale")):
            raise RuntimeError(t(
                f"Das Video hat {info['fps']:g} fps. Mit derselben Rate fortsetzen geht nur mit „Höchste "
                "Qualität (DFR)“ und 48 fps.",
                f"The video has {info['fps']:g} fps. Continuing at the same rate needs “Best quality (DFR)” "
                "with 48 fps."))
        p["fps"] = info["fps"] / 2
    else:
        p["fps"] = info["fps"]
    p["width"] = max(256, int(info["width"]) // 64 * 64)
    p["height"] = max(256, int(info["height"]) // 64 * 64)
    frame = config.DATA_DIR / "tmp" / f"{job.id}_last_frame.png"
    frame.parent.mkdir(parents=True, exist_ok=True)
    # Startbild aus dem verlustfreien Master, sonst wanderten die H.264-Fehler ins neue Stueck
    await _video_tool("last-frame", master_path(source) or path, frame)
    try:
        p["start_image"] = comfy.stage_input(frame)
    finally:
        frame.unlink(missing_ok=True)
    return source, path


@register("txt2video")
async def _txt2video(job: Job, ctx: JobContext) -> list[str]:
    p = job.params
    entry = _resolve_model(p, "video")
    wf = entry["workflow"]
    _check_video_options(p, entry)
    extension = await _prepare_extension(job, p, entry) if p.get("extend_asset_id") else None
    fps = float(p.get("fps", 16))
    frames = workflows.normalize_frames(int(p.get("frames", 49)), wf)

    # Bild-zu-Video: das Startbild muss in ComfyUIs input/ liegen, damit LoadImage
    # es findet. Der Workflow-Builder bekommt nur den Dateinamen.
    if p.get("image_asset_id"):
        p["start_image"] = _stage_image(p["image_asset_id"], t("Startbild", "Start image"))
    elif wf in workflows.I2V_WORKFLOWS:
        raise RuntimeError(t(
            f"{_name(entry)} ist ein Bild-zu-Video-Modell — bitte ein Startbild angeben.",
            f"{_name(entry)} is an image-to-video model — please provide a start image.",
        ))
    # LTX-2.5: Endbild bzw. Schleife (das Startbild auch als Endbild) und vorgegebener Ton.
    if p.get("loop"):
        if not p.get("start_image"):
            raise RuntimeError(t("Eine Schleife braucht ein Startbild.", "A loop needs a start image."))
        p["end_image"] = p["start_image"]
    elif p.get("end_image_asset_id"):
        p["end_image"] = _stage_image(p["end_image_asset_id"], t("Endbild", "End image"))
    if p.get("audio_asset_id"):
        p["audio_input"], seconds = _stage_audio(p["audio_asset_id"])
        if seconds:
            # Das Video ist hoechstens so lang wie der Ton (und hoechstens 20 s).
            frames = workflows.ltx_frames_for_seconds(min(seconds, workflows.LTX25_MAX_SECONDS), fps,
                                                      at_most=True)
        p["auto_duration"] = False
    p["frames"] = frames

    temporal = p.get("quality") == "dfr" and bool(p.get("temporal_upscale"))
    fps_out = fps * (2 if temporal else 1)
    frames_out = (frames - 1) * 2 + 1 if temporal else frames
    ids = await _run_generation(job, ctx, "video", {
        "width": p.get("width"), "height": p.get("height"),
        # Mit "Laenge automatisch" waehlt das Modell die Laenge erst im Lauf.
        "frames": None if p.get("auto_duration") else frames_out, "fps": fps_out,
        "duration_s": None if p.get("auto_duration") else round(frames / max(fps, 1), 2),
        "image_asset_id": p.get("image_asset_id"),
        "end_image_asset_id": p.get("end_image_asset_id"), "loop": bool(p.get("loop")),
        "quality": p.get("quality") or "standard", "auto_duration": bool(p.get("auto_duration")),
        "audio_asset_id": p.get("audio_asset_id"),
        "motion_speed": float(p.get("motion_speed") or 1.0),
        "extend_asset_id": p.get("extend_asset_id"),
    })
    if extension is None:
        return ids
    # Neues Stueck anfuegen: dessen erster Frame ist der letzte des Originals und faellt weg.
    source, source_path = extension
    segment = db.get_asset(ids[0])
    ctx.progress(0.995, t("fügt an", "joining"))
    out_name = f"{Path(segment.filename).stem}_extended.mp4"
    crf = p.get("crf") if p.get("crf") is not None else workflows.VIDEO_CRF
    joined = await _video_tool("concat", source_path, config.ASSET_DIR / segment.filename,
                               config.ASSET_DIR / out_name, crf, 1)
    meta = {"model_name": _name(entry), "extended_from": source.id, "segment_asset": segment.id,
            "seconds": joined["seconds"], "frames": joined["frames"], "fps": joined["fps"],
            "width": joined["width"], "height": joined["height"], "audio": joined["audio"],
            "duration_s": joined["seconds"]}
    first_master, second_master = master_path(source), master_path(segment)
    if first_master and second_master:
        master_name = f"{Path(segment.filename).stem}_extended_master.mkv"
        await _video_tool("concat-master", first_master, second_master, config.ASSET_DIR / master_name, 1)
        meta["master"] = master_name
    combined = db.create_asset(
        kind="video", filename=out_name, job_id=job.id, prompt=p.get("prompt", ""), model_id=entry["id"],
        meta=meta,
    )
    return [combined.id, *ids]


@register("img23d")
async def _img23d(job: Job, ctx: JobContext) -> list[str]:
    """Bild zu Mesh ueber einen der Mesh-Worker (TripoSG oder TRELLIS.2).

    Laeuft ausserhalb von ComfyUI, teilt sich aber dieselbe GPU -- deshalb raeumt
    ComfyUI vorher, und der jeweils andere Mesh-Worker ebenfalls.
    """
    p = job.params
    entry = _resolve_model(p, "3d")
    worker = mesh_workers.get(entry["workflow"])

    asset = db.get_asset(p["image_asset_id"])
    if asset is None:
        raise RuntimeError(t(f"Bild-Asset nicht gefunden: {p.get('image_asset_id')}",
                             f"Image asset not found: {p.get('image_asset_id')}"))
    src = config.ASSET_DIR / asset.filename
    if not src.exists():
        raise RuntimeError(t(f"Bilddatei fehlt: {src}", f"Image file missing: {src}"))

    if not worker.is_set_up():
        raise RuntimeError(t(
            f"{worker.name}-Worker ist nicht eingerichtet. "
            f"scripts/setup_{worker.key}.ps1 ausfuehren.",
            f"{worker.name} worker is not set up. "
            f"Run scripts/setup_{worker.key}.ps1.",
        ))

    # 16 GB tragen nur ein Modell -- auf derselben Karte. Mit eigener 3D-Karte bleibt
    # das Bildmodell geladen.
    if _same_gpu("mesh", "image") and await comfy.is_running():
        ctx.progress(0.02, t("gebe VRAM von ComfyUI frei", "freeing ComfyUI's VRAM"))
        await comfy.MAIN.free_memory()
    if (gpu.separate_text_backend() and _same_gpu("mesh", "text")
            and await comfy.TEXT.is_running(timeout=1.0)):
        await comfy.TEXT.free_memory()
    for other in mesh_workers.all_workers():
        if other is not worker and await other.is_running():
            ctx.progress(0.03, t(f"entlade {other.name}", f"unloading {other.name}"))
            await other.unload()

    ctx.progress(0.05, t(f"starte {worker.name}", f"starting {worker.name}"))
    model_dir = registry.file_path(entry["files"][0])
    worker.start(model_dir)
    if not await worker.wait_until_ready():
        raise RuntimeError(t(
            f"{worker.name} nicht gestartet (Timeout). "
            f"Details: /api/backend/log?worker={worker.key}",
            f"{worker.name} did not start (timeout). "
            f"Details: /api/backend/log?worker={worker.key}",
        ))

    ctx.progress(0.15, t("erzeuge Mesh", "generating mesh"))
    out_name = f"{db.new_id('msh')}.glb"
    payload: dict[str, Any] = {
        "image_path": str(src),
        "output_path": str(config.ASSET_DIR / out_name),
        "seed": p.get("seed"),
        "remove_background": bool(p.get("remove_background", True)),
        "project_front": bool(p.get("project_front")),
    }
    if entry["workflow"] == "trellis2":
        payload |= {
            "resolution": int(p.get("resolution") or 512),
            "texture_size": int(p.get("texture_size") or 2048),
            "faces": int(p.get("faces") or 100_000),
            "background_mode": p.get("background_mode") or "birefnet",
            "clean_specks": bool(p.get("clean_specks", True)),
            "speck_ratio": float(p.get("speck_ratio", 0.02)),
        }
    else:
        payload |= {
            "num_inference_steps": int(p.get("steps") or 50),
            "guidance_scale": float(p.get("guidance") if p.get("guidance") is not None else 7.0),
            "faces": int(p.get("faces") or -1),
        }

    result = await worker.generate(payload)

    ctx.progress(0.97, t("speichert", "saving"))

    # Das freigestellte Bild als eigenes Asset ablegen: daran laesst sich
    # nachvollziehen, was tatsaechlich ins Mesh eingegangen ist.
    cutout_id = None
    cutout = result.get("cutout_path")
    if cutout and Path(cutout).exists():
        cutout_asset = db.create_asset(
            kind="image",
            filename=Path(cutout).name,
            job_id=job.id,
            prompt=t(f"Freistellung fuer {asset.filename}", f"Cutout for {asset.filename}"),
            model_id=entry["id"],
            meta={"cutout_for": asset.id, "background_mode": result.get("background_mode")},
        )
        cutout_id = cutout_asset.id

    mesh_asset = db.create_asset(
        kind="mesh",
        filename=out_name,
        job_id=job.id,
        prompt=asset.prompt or p.get("prompt", ""),
        model_id=entry["id"],
        meta={
            "source_asset": asset.id,
            "source_image": asset.filename,
            "vertices": result.get("vertices"),
            "faces": result.get("faces"),
            "seconds": result.get("seconds"),
            "seed": p.get("seed"),
            "model_name": _name(entry),
            "textured": bool(result.get("textured")),
            "texture_size": result.get("texture_size"),
            "resolution": result.get("resolution"),
            "specks_removed": result.get("specks_removed"),
            "background_mode": result.get("background_mode"),
            "cutout_asset": cutout_id,
            "front_projection": result.get("front_projection"),
        },
    )
    return [mesh_asset.id]


@register("download")
async def _download(job: Job, ctx: JobContext) -> list[str]:
    entry = job.params["entry"]
    clean = bool(job.params.get("clean"))
    ctx.progress(0.0, t(f"lade {_name(entry)}", f"downloading {_name(entry)}"))
    await asyncio.to_thread(registry.download, entry, ctx.progress, clean, ctx.should_stop)
    # ComfyUI cached die Modellliste -- nach dem Download neu einlesen lassen.
    if await comfy.is_running():
        await comfy.list_checkpoints()
    return []

