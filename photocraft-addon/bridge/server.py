"""HTTP-Schnittstelle der Brücke: liefert das Panel aus und steuert die Aufträge."""
from __future__ import annotations

import logging
import os
import threading
import time
from typing import Any, Callable, Literal

from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from . import __version__, config, i18n, launcher
from .i18n import t
from .nvai import NVAI, NVAIError, NVAIIncompatible
from .photocraft import NotConnected, PhotoCraft, PhotoCraftError
from .planning import WEAK_PROMPT_WORKFLOWS, capable
from .tasks import BusyError, TaskManager

log = logging.getLogger(__name__)

pc = PhotoCraft(config.PHOTOCRAFT_PORT, config.TOKEN_FILE)
nv = NVAI(config.NVAI_URL, config.NVAI_TOKEN)
tasks = TaskManager(pc, nv)

# Vom Panel-Fenster gesetzt: holt es nach vorn (für einen zweiten Start der Verknüpfung) bzw.
# passt seinen Titel nach einem Sprachwechsel an.
focus_window: Callable[[], None] | None = None
retitle_window: Callable[[], None] | None = None

app = FastAPI(title="ArtCraft-LocalAI", version=__version__)


class _Cache:
    """Kurzlebige Zwischenablage für Statusabfragen – das Panel fragt jede Sekunde."""

    def __init__(self) -> None:
        self._data: dict[str, tuple[float, Any]] = {}
        self._lock = threading.Lock()

    def get(self, key: str, ttl: float, produce: Callable[[], Any]) -> Any:
        with self._lock:
            hit = self._data.get(key)
            if hit and time.monotonic() - hit[0] < ttl:
                return hit[1]
        value = produce()
        with self._lock:
            self._data[key] = (time.monotonic(), value)
        return value

    def drop(self, key: str) -> None:
        with self._lock:
            self._data.pop(key, None)


cache = _Cache()
_last_document: dict[str, Any] = {}


# ------------------------------------------------------------------- Status

def _photocraft_state() -> dict[str, Any]:
    global _last_document
    if tasks.pc_busy and _last_document:
        # Während Erfassen/Einfügen sind kurz Hilfsdokumente aktiv – den letzten Stand zeigen.
        return _last_document
    # Installiert? Welche Version? Neu nachgesehen, damit eine Nachinstallation ohne Neustart greift.
    install = cache.get("pc-install", 5.0, launcher.photocraft_install)
    try:
        ui = pc.inspect()
    except NotConnected as exc:
        others = cache.get("pids", 5.0, launcher.photocraft_pids)
        return {"connected": False, "error": str(exc), "uncontrolled_running": bool(others), **install}
    except PhotoCraftError as exc:
        return {"connected": False, "error": str(exc), "uncontrolled_running": False, **install}
    doc = ui.get("document")
    session = ui.get("session") or {}
    state = {
        **install,
        "connected": True,
        "error": None,
        "documents": len(session.get("documents") or []),
        "dialog_open": bool(ui.get("dialogs")),
        "document": None if not doc else {
            "name": doc.get("name"),
            "width": doc.get("width"),
            "height": doc.get("height"),
            "mode": doc.get("mode"),
            "depth": doc.get("depth"),
            "hasSelection": doc.get("hasSelection"),
            "selectionBounds": doc.get("selectionBounds"),
        },
    }
    _last_document = state
    return state


def _nvai_state() -> dict[str, Any]:
    where = {"url": config.NVAI_URL, "local": config.nvai_is_local(), "settings_file": str(config.SETTINGS_FILE)}
    try:
        h = nv.health()
    except NVAIError as exc:
        local = where["local"]
        return {"connected": False, "error": str(exc), **where,
                # Ohne Setup und ohne Entwicklungsordner gibt es nichts zu starten.
                "startable": local and launcher.nvai_starter() is not None,
                "starting": local and launcher.nvai_start_pending()}
    # Versionsangaben gibt es erst ab NV-AI 0.2.0; ältere Server bleiben wie bisher nutzbar.
    info: dict[str, Any] | None = None
    problem = None
    try:
        info = nv.check_compatible()
    except NVAIIncompatible as exc:
        info, problem = nv.version(), str(exc)
    except NVAIError:
        pass
    try:
        masks = nv.supports_masks()
    except NVAIError:
        masks = False
    try:
        expand = nv.supports_expand()
    except NVAIError:
        expand = False
    try:
        downloads = nv.downloads()
    except NVAIError:
        downloads = []
    return {
        "connected": True,
        "error": None,
        "version": (info or {}).get("version"),
        "api": (info or {}).get("api"),
        "auth": (info or {}).get("auth"),
        "authorized": (info or {}).get("authorized", True),
        "problem": problem,
        "active_model": (h.get("active_models") or {}).get("image"),
        "loaded": [m.get("model") for m in h.get("vram_loaded") or []],
        "busy": bool(h.get("current_job")),
        "queue_depth": h.get("queue_depth", 0),
        "comfy_running": h.get("comfy_running"),
        "gpu": h.get("gpu"),
        "masks": masks,
        "expand": expand,
        "downloads": downloads,
        **where,
    }


@app.get("/api/state")
def state() -> dict[str, Any]:
    current = tasks.current
    return {
        "bridge": {"version": __version__},
        # Wirksame Sprache („de“/„en“) und die Wahl dahinter („auto“, „en“, „de“).
        "lang": i18n.lang(),
        "language": i18n.choice(),
        "photocraft": cache.get("pc", 0.8, _photocraft_state),
        "nvai": cache.get("nv", 2.5, _nvai_state),
        "task": current.public() if current else None,
    }


@app.get("/api/models")
def models() -> list[dict[str, Any]]:
    def produce() -> list[dict[str, Any]]:
        nv.check_compatible()  # sonst endet ein fehlender Token in einem nackten „401“
        active = (nv.health().get("active_models") or {}).get("image")
        masks = nv.supports_masks()
        out = []
        for m in nv.image_models():
            if not m.get("runnable"):
                continue
            features = m.get("features") or {}
            out.append({
                "id": m["id"], "name": m["name"], "workflow": m.get("workflow"),
                "vram_gb": m.get("vram_gb"), "commercial_ok": m.get("commercial_ok"),
                "warning": m.get("warning") or "", "best_for": m.get("best_for") or "",
                "active": m["id"] == active,
                # Was das Modell in den drei Modi kann (Generieren können alle).
                "img2img": capable(m, "img2img", masks),
                "refine": capable(m, "refine", masks),
                "mask": capable(m, "mask", masks),
                "reference_edit": capable(m, "refine", masks) and not capable(m, "img2img", masks),
                "weak_prompt": m.get("workflow") in WEAK_PROMPT_WORKFLOWS,
                # Bedienhinweise aus NV-AI (BILDMODELLE.md, Abschnitt 7).
                "negative_prompt": bool(features.get("negative_prompt", True)),
                "hires": bool(features.get("hires", True)),
                "upsampler": bool(features.get("upsampler", False)),
                "prompt_hint": features.get("prompt_hint") or "",
                "placeholder": features.get("placeholder") or "",
            })
        return out

    try:
        return cache.get("models", 20.0, produce)
    except NVAIError as exc:
        raise HTTPException(503, str(exc)) from exc


# ---------------------------------------------------------------- Aufträge

class GenerateRequest(BaseModel):
    mode: Literal["fill", "generate", "refine"]
    prompt: str = Field("", max_length=4000)
    negative_prompt: str = Field("", max_length=2000)
    model_id: str | None = None
    variants: int = Field(1, ge=1, le=4)
    strength: float = Field(0.5, ge=0.05, le=1.0, description="Refine only: denoise")
    steps: int | None = Field(None, ge=1, le=150)
    cfg: float | None = Field(None, ge=0.0, le=30.0)
    seed: int | None = Field(None, ge=0)
    margin: float = Field(0.35, ge=0.0, le=1.5, description="Fill only: context margin relative to the selection")
    hires: bool = False
    native: bool = Field(False, description="Work at the model's native resolution (more detail, about twice the time)")
    auto_place: bool = True


class PlaceRequest(BaseModel):
    variant: int = Field(0, ge=0)
    replace: bool = True


@app.post("/api/generate")
def generate(req: GenerateRequest) -> dict[str, Any]:
    try:
        task = tasks.start(req.model_dump())
    except BusyError as exc:
        raise HTTPException(409, str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    return task.public()


class ExpandRequest(BaseModel):
    prompt: str = Field(..., min_length=1, max_length=4000)


@app.post("/api/expand")
def expand(req: ExpandRequest) -> dict[str, Any]:
    """„Prompt ausbauen“: NV-AI macht aus wenigen Worten eine volle Bildbeschreibung."""
    nv.check_compatible()
    if not nv.supports_expand():
        raise HTTPException(409, t(
            "Diese NV-AI-Version kann Prompts noch nicht ausbauen. Bitte NV-AI aktualisieren.",
            "This NV-AI version cannot expand prompts yet. Please update NV-AI.",
        ))
    result = nv.expand_prompt(req.prompt)
    return {"expanded": result["expanded"], "seconds": result.get("seconds")}


@app.get("/api/tasks")
def task_list() -> list[dict[str, Any]]:
    return [t.public() for t in tasks.history()]


@app.get("/api/tasks/{task_id}")
def task_get(task_id: str) -> dict[str, Any]:
    task = tasks.get(task_id)
    if not task:
        raise HTTPException(404, t("Auftrag nicht gefunden.", "Job not found."))
    return task.public()


@app.post("/api/tasks/{task_id}/cancel")
def task_cancel(task_id: str) -> dict[str, Any]:
    return {"cancelled": tasks.cancel(task_id)}


@app.post("/api/tasks/{task_id}/place")
def task_place(task_id: str, req: PlaceRequest) -> dict[str, Any]:
    task = tasks.get(task_id)
    if not task:
        raise HTTPException(404, t("Auftrag nicht gefunden.", "Job not found."))
    try:
        layer = tasks.place(task, req.variant, replace=req.replace)
    except (PhotoCraftError, ValueError) as exc:
        raise HTTPException(409, str(exc)) from exc
    cache.drop("pc")
    return {"layer": layer, "task": task.public()}


# ------------------------------------------------------------ Programme

@app.post("/api/photocraft/start")
def photocraft_start(force: bool = False) -> dict[str, Any]:
    try:
        message = launcher.start_photocraft(force=force)
    except launcher.LaunchError as exc:
        raise HTTPException(409, str(exc)) from exc
    cache.drop("pc")
    cache.drop("pids")
    return {"message": message}


@app.post("/api/photocraft/focus")
def photocraft_focus() -> dict[str, Any]:
    try:
        pc.call("ui.focus")
    except PhotoCraftError as exc:
        raise HTTPException(409, str(exc)) from exc
    return {"ok": True}


@app.post("/api/nvai/start")
def nvai_start() -> dict[str, Any]:
    try:
        message = launcher.start_nvai()
    except launcher.LaunchError as exc:
        raise HTTPException(409, str(exc)) from exc
    cache.drop("nv")
    return {"message": message}


@app.post("/api/nvai/downloads/{job_id}/cancel")
def nvai_download_cancel(job_id: str) -> dict[str, Any]:
    """Einen NV-AI-Download aus dem Panel abbrechen (fertige Teile bleiben zum Fortsetzen)."""
    try:
        nv.cancel_download(job_id)
    except NVAIError as exc:
        raise HTTPException(exc.status or 502, str(exc)) from exc
    cache.drop("nv")
    return {"cancelled": True, "job": job_id}


@app.post("/api/nvai/check")
def nvai_check() -> dict[str, Any]:
    """„Erneut prüfen“: Token neu einlesen und NV-AI frisch nach Version und Zugriff fragen."""
    nv.set_token(config.load_nvai_token())
    cache.drop("nv")
    cache.drop("models")
    return cache.get("nv", 2.5, _nvai_state)


class LanguageRequest(BaseModel):
    language: Literal["auto", "en", "de"]


@app.post("/api/language")
def set_language(req: LanguageRequest) -> dict[str, Any]:
    """Sprache wählen und in settings.json merken. NV-AI liefert seine Modelltexte danach neu."""
    i18n.set_choice(req.language)
    config.save_settings(language=req.language)
    for key in ("pc", "nv", "models"):
        cache.drop(key)
    if retitle_window:
        retitle_window()
    return state()


@app.post("/api/open/nvai")
def open_nvai() -> dict[str, Any]:
    os.startfile(config.NVAI_URL)  # noqa: S606 – feste lokale Adresse
    return {"ok": True}


@app.post("/api/open/photocraft-download")
def open_photocraft_download() -> dict[str, Any]:
    os.startfile(config.PHOTOCRAFT_DOWNLOAD_URL)  # noqa: S606 – feste Adresse
    return {"ok": True}


@app.post("/api/panel/focus")
def panel_focus() -> dict[str, Any]:
    if focus_window:
        focus_window()
    return {"ok": focus_window is not None}


@app.exception_handler(PhotoCraftError)
def _pc_error(_request: Any, exc: PhotoCraftError) -> JSONResponse:
    return JSONResponse({"detail": str(exc)}, status_code=409)


@app.exception_handler(NVAIError)
def _nv_error(_request: Any, exc: NVAIError) -> JSONResponse:
    return JSONResponse({"detail": str(exc)}, status_code=503)


def mount_static() -> None:
    """Statische Dateien zuletzt einhängen, damit sie die API-Routen nicht verdecken."""
    config.ensure_dirs()
    app.mount("/jobs", StaticFiles(directory=str(config.JOBS_DIR)), name="jobs")
    app.mount("/", StaticFiles(directory=str(config.PANEL_DIR), html=True), name="panel")
