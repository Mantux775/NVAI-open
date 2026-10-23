"""Job-Queue mit genau einem GPU-Worker.

Die 16 GB VRAM erlauben nur ein aktives Modell. Statt Semaphoren zu verteilen,
gibt es deshalb bewusst nur einen Consumer -- die Serialisierung ist die
Architektur, nicht ein Detail.
"""
from __future__ import annotations

import asyncio
import contextlib
import time
import traceback
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
_workers: list[asyncio.Task] = []
_subscribers: set[asyncio.Queue] = set()
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


def subscribe() -> asyncio.Queue:
    q: asyncio.Queue = asyncio.Queue(maxsize=200)
    _subscribers.add(q)
    return q


def unsubscribe(q: asyncio.Queue) -> None:
    _subscribers.discard(q)


def _queue_for(kind: str) -> asyncio.Queue[str]:
    if kind in TEXT_KINDS and gpu.separate_text_backend() and _text_queue is not None:
        return _text_queue
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
    global _gpu_queue, _io_queue, _text_queue
    _gpu_queue = asyncio.Queue()
    _io_queue = asyncio.Queue()
    _text_queue = asyncio.Queue()
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
        missing = [f.get("file") or f["repo"] for f in entry["files"] if not registry.file_path(f).exists()]
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
    paths = await comfy.run_workflow(graph, on_progress=on_progress, timeout=timeout)
    ctx.progress(0.99, t("speichert", "saving"))

    if not paths:
        raise RuntimeError(t("ComfyUI lieferte keine Ausgabedatei zurueck.",
                             "ComfyUI returned no output file."))

    d = workflows.defaults_for(entry["workflow"])
    asset_ids = []
    for path in paths:
        asset = db.create_asset(
            kind=comfy.kind_for(path),
            filename=path.name,
            job_id=job.id,
            prompt=p.get("prompt", ""),
            model_id=entry["id"],
            meta={
                "seed": seed,
                "steps": p.get("steps") or d["steps"],
                "cfg": p.get("cfg") if p.get("cfg") is not None else d["cfg"],
                "negative_prompt": p.get("negative_prompt", ""),
                "model_name": _name(entry),
                **extra_meta,
            },
        )
        asset_ids.append(asset.id)
    return asset_ids


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


def prompt_upsampler() -> dict[str, Any] | None:
    """Die Upsampler-Datei von FLUX 3, falls ein FLUX-3-Eintrag sie geladen hat.

    Qwen3.5-9B, Apache-2.0. Sie baut auch fuer die anderen Bildmodelle einen knappen
    Prompt zur vollen Bildbeschreibung aus ("Prompt ausbauen").
    """
    for entry in registry.all_entries():
        for f in entry.get("files", []):
            if "upsampler" in f.get("file", "") and registry.file_path(f).exists():
                return f
    return None


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

    upsampler = next((f for f in entry["files"] if "upsampler" in f.get("file", "")), None)
    if upsampler is None:
        return {"upsampled": False}
    caption = await _upsample(prompt, upsampler, ref_ids, p.get("reference_images") or [],
                              int(p.get("width", 1024)), int(p.get("height", 1024)), ctx)
    p["caption"] = caption
    return {"upsampled": True, "caption": caption}


async def _expand_other(p: dict[str, Any], upsampler: dict[str, Any], ref_images: list[str],
                        ctx: JobContext) -> str:
    """Prompt ausbauen fuer Video, Ton und 3D: derselbe Upsampler mit NV-AIs eigenen
    Systemprompts (prompt_targets.py)."""
    target = p["target"]
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
    # Platzierung); ein schlichter Bildprompt nimmt NV-AIs kurzen.
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
    grauem Rand als Referenz und fuehren die Szene nahtlos weiter; danach legt der Graph das
    Original pixelgenau zurueck (workflows._composite_original).
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

    # Referenzweg: Bild mit grauem Rand als eigene Datei, damit auch der Upsampler von
    # FLUX 3 sieht, was zu fuellen ist.
    await _ensure_backend(ctx)
    ctx.progress(0.01, t("legt den Rand an", "adding the border"))
    p["outpaint_source"] = p["reference_images"][0]
    padded = await comfy.run_workflow(workflows.outpaint_pad_graph(p["outpaint_source"], p["outpaint"]))
    if not padded:
        raise RuntimeError(t("ComfyUI lieferte das erweiterte Bild nicht.",
                             "ComfyUI did not return the extended image."))
    p["reference_images"] = [comfy.stage_input(padded[0])]
    for path in padded:
        path.unlink(missing_ok=True)
    if not p["prompt"].startswith(OUTPAINT_INSTRUCTION):
        p["prompt"] = f"{OUTPAINT_INSTRUCTION} {p['prompt']}".strip()


@register("txt2img")
async def _txt2img(job: Job, ctx: JobContext) -> list[str]:
    p = job.params
    entry = _resolve_model(p, "image")
    wf = entry["workflow"]
    is_flux3 = wf in workflows.FLUX3_WORKFLOWS

    # FLUX 3 und Qwen-Image 2.1 bearbeiten ueber Referenzbilder, nicht ueber ein
    # angerauschtes Startbild -- dafuer sind sie trainiert. Ein Startbild wird dort
    # deshalb zur ersten Referenz.
    by_reference = registry.features_for(entry).get("references", 0) > 0
    ref_ids = [a for a in (p.get("reference_asset_ids") or []) if a]
    if by_reference and p.get("image_asset_id") and not ref_ids:
        ref_ids = [p.pop("image_asset_id")]
    if ref_ids and not by_reference:
        raise RuntimeError(t(
            f"Referenzbilder verarbeiten nur Modelle mit Referenzbild-Unterstuetzung (FLUX 3, "
            f"Qwen-Image 2.1, Boogu-Image Edit, HiDream-O1), nicht '{_name(entry)}'. "
            "Fuer ein vorhandenes Bild als Ausgangspunkt: image_asset_id mit denoise.",
            f"Only models with reference support (FLUX 3, Qwen-Image 2.1, Boogu-Image Edit, "
            f"HiDream-O1) process reference images, not '{_name(entry)}'. "
            "To start from an existing image: image_asset_id with denoise.",
        ))
    if len(ref_ids) > flux3_prompt.MAX_REFERENCES:
        raise RuntimeError(t(f"Hoechstens {flux3_prompt.MAX_REFERENCES} Referenzbilder.",
                             f"At most {flux3_prompt.MAX_REFERENCES} reference images."))
    if ref_ids:
        p["reference_images"] = [
            _stage_image(a, t(f"Referenzbild {i + 1}", f"Reference image {i + 1}"))
            for i, a in enumerate(ref_ids)
        ]

    if p.get("image_asset_id"):
        p["start_image"] = _stage_image(p["image_asset_id"], t("Startbild", "Start image"))

    # Inpainting: Die Maske legt fest, wo neu gerechnet wird (weiss) und wo das Startbild
    # bleibt (schwarz). Sie haengt am Startbild-Pfad -- ohne Bild-zu-Bild keine Maske.
    if p.get("mask_asset_id"):
        if not registry.features_for(entry).get("mask"):
            raise RuntimeError(t(f"'{_name(entry)}' kann keine Masken (Inpainting).",
                                 f"'{_name(entry)}' cannot use masks (inpainting)."))
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

    caption_meta = await _flux3_caption(p, entry, ref_ids, ctx) if is_flux3 else {}

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


@register("txt2audio")
async def _txt2audio(job: Job, ctx: JobContext) -> list[str]:
    p = job.params
    return await _run_generation(job, ctx, "audio", {
        "seconds": p.get("seconds"), "lyrics": p.get("lyrics", ""), "bpm": p.get("bpm"),
    })


@register("txt2video")
async def _txt2video(job: Job, ctx: JobContext) -> list[str]:
    p = job.params
    entry = _resolve_model(p, "video")
    wf = entry["workflow"]
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

    return await _run_generation(job, ctx, "video", {
        "width": p.get("width"), "height": p.get("height"),
        "frames": frames, "fps": p.get("fps"),
        "duration_s": round(frames / max(p.get("fps", 16), 1), 2),
        "image_asset_id": p.get("image_asset_id"),
    })


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

