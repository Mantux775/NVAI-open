"""FastAPI-Orchestrator. Einziger Einstiegspunkt fuer Frontend und MCP-Server."""
from __future__ import annotations

import asyncio
import contextlib
import hmac
import ipaddress
import shutil
import signal
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from fastapi import FastAPI, HTTPException, Request, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

import httpx

from . import __version__, comfy, config, db, hfsearch, i18n, jobs, mesh_workers, registry
from .i18n import t
from . import gpu as gpu_info
from .schemas import (
    Asset,
    DeleteResult,
    DownloadRequest,
    ExpandPromptRequest,
    ExpandPromptResult,
    Generate3DRequest,
    GenerateAudioRequest,
    GenerateImageRequest,
    GenerateVideoRequest,
    Job,
    ModelInfo,
    VersionInfo,
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    config.ensure_dirs()
    db.init()
    await jobs.start()
    yield
    await jobs.shutdown()
    comfy.stop()
    mesh_workers.stop_all()


app = FastAPI(title="NV-AI", version=__version__, lifespan=lifespan)

# Vertragsversion der REST-API (GET /api/version). Steigt nur, wenn bestehende
# Clients brechen: ein Endpunkt oder Feld faellt weg oder bedeutet etwas anderes.
# Neue Endpunkte und Felder lassen sie stehen -- die meldet API_FEATURES, damit ein
# Client nicht Felder schickt, die ein aelterer Server stillschweigend ignoriert.
# Den Stand haelt server/openapi.json fest; `python -m nvai.vertrag` prueft dagegen.
API_VERSION = 1
API_FEATURES = [
    "model_features",  # GET /api/models: je Modell "features" (Regler, Formate, Faehigkeiten)
    "mask",            # generate/image: mask_asset_id (Inpainting)
    "references",      # generate/image: reference_asset_ids (FLUX 3)
    "upsampler",       # generate/image: upsample_prompt; Asset-meta "caption"
    "upload",          # POST /api/upload
    "model_search",    # GET /api/models/search und /inspect: Hugging Face mit Pruefung
    "expand_prompt",   # POST /api/prompt/expand: Prompt fuer jedes Bildmodell ausbauen
    "gpus",            # GET/PUT /api/gpus: mehrere Karten, Aufgaben je Karte (experimentell)
]


# ------------------------------------------------------- Zugriffsschutz
#
# Der eigene Rechner braucht keinen Token -- Weboberflaeche und MCP-Server schicken
# keinen mit. Andere Geraete (Mac-App, PhotoCraft-Bruecke, iOS-App) brauchen ihn im
# Header X-NVAI-Token, fuer alles ausser /api/health und /api/version: auch fuer
# /files und den Live-Feed /ws. Ist kein Token gesetzt, bedient der Server nur den
# eigenen Rechner, egal an welche Adresse uvicorn ihn bindet.
#
# Bis 0.1 galt der Token nur fuer /api/ und auch fuer den eigenen Rechner: mit
# gesetztem Token bekamen Weboberflaeche und MCP 401, /files und /ws waren offen.
OPEN_PATHS = ("/api/health", "/api/version")
_LOCAL_NAMES = {"localhost", "127.0.0.1", "::1"}
# Ein Proxy auf diesem Rechner (etwa `tailscale serve`) reicht fremde Anfragen ueber
# 127.0.0.1 weiter und setzt dabei einen dieser Header. Einen reinen TCP-Weiterleiter
# (netsh portproxy) erkennt man nicht -- fuer den Netzbetrieb gibt es start.ps1 -Lan.
_PROXY_HEADERS = ("forwarded", "x-forwarded-for", "x-forwarded-host", "x-real-ip",
                  "tailscale-user-login")


def _hostname(value: str | None) -> str | None:
    """Rechnername aus einem Host- oder Origin-Header, ohne Port und Klammern."""
    if not value:
        return None
    return urlparse(value if "//" in value else f"//{value}").hostname


def _is_local(headers: Any, client: Any) -> bool:
    """Kommt die Anfrage wirklich von diesem Rechner?

    Neben dem Proxy gibt es zwei Faelle, die lokal aussehen und es nicht sind: eine
    fremde Webseite im Browser des Nutzers ruft 127.0.0.1 auf (der Origin-Header
    verraet sie), und beim DNS-Rebinding zeigt ein fremder Name auf 127.0.0.1 (der
    Host-Header verraet ihn).
    """
    try:
        ip = ipaddress.ip_address(client.host if client else "")
    except ValueError:
        return False
    if ip.version == 6 and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    if not ip.is_loopback or any(h in headers for h in _PROXY_HEADERS):
        return False
    if _hostname(headers.get("host")) not in _LOCAL_NAMES:
        return False
    origin = headers.get("origin")
    return origin is None or _hostname(origin) in _LOCAL_NAMES


def _token_ok(given: str | None) -> bool:
    if not (config.API_TOKEN and given):
        return False
    return hmac.compare_digest(given.encode(), config.API_TOKEN.encode())


def _authorized(headers: Any, client: Any) -> bool:
    return _is_local(headers, client) or _token_ok(headers.get("x-nvai-token"))


@app.middleware("http")
async def _require_token(request, call_next):
    if (request.method != "OPTIONS" and request.url.path not in OPEN_PATHS
            and not _authorized(request.headers, request.client)):
        if config.API_TOKEN:
            return JSONResponse({"detail": t("Zugriff verweigert: Token fehlt oder falsch.", "Access denied: token missing or wrong.")},
                                status_code=401)
        return JSONResponse(
            {"detail": t("NV-AI bedient ohne Token nur den eigenen Rechner. "
                         "Für andere Geräte mit scripts\\start.ps1 -Lan starten.",
                         "Without a token NV-AI only serves this computer. "
                         "Start it with scripts\\start.ps1 -Lan for other devices.")},
            status_code=403)
    return await call_next(request)


# Die Weboberflaeche selbst nie aus dem Browser-Cache: index.html verweist auf die
# Bundle-Dateien mit Hash im Namen. Hielt Chrome eine alte index.html vor, lief nach
# einem Frontend-Update stillschweigend das alte Bundle weiter (am 2026-10-18 gemessen).
# Die gehashten Bundles duerfen gecacht bleiben -- sie aendern bei jedem Build den Namen.
@app.middleware("http")
async def _no_cache_html(request, call_next):
    response = await call_next(request)
    if response.headers.get("content-type", "").startswith("text/html"):
        response.headers["Cache-Control"] = "no-cache"
    return response


# Zuletzt angemeldet = aeusserste Middleware: so gilt die Sprache schon fuer die
# Meldungen des Zugriffsschutzes. ?lang=de|en ueberstimmt den Header (Links, Tests).
@app.middleware("http")
async def _language(request, call_next):
    i18n.set_lang(request.query_params.get("lang")
                  or i18n.from_header(request.headers.get("accept-language")))
    return await call_next(request)


app.add_middleware(
    CORSMiddleware,
    # Im LAN-Betrieb kommt die App als eigener Ursprung -- deshalb offen,
    # der Schutz liegt beim Token.
    allow_origins=["*"] if config.API_TOKEN else
    ["http://localhost:5173", "http://127.0.0.1:5173"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ----------------------------------------------------------- System

async def _port_open(port: int, timeout: float = 0.3) -> bool:
    """Lauscht auf diesem Port ueberhaupt jemand?

    Gemessen: eine HTTP-Anfrage an einen toten lokalen Port laeuft hier in den
    vollen Timeout (~1,5 s), weil die Verbindung verworfen statt abgelehnt wird.
    Ein blosser TCP-Verbindungsversuch scheitert in einem Bruchteil davon.
    """
    try:
        _, writer = await asyncio.wait_for(
            asyncio.open_connection("127.0.0.1", port), timeout
        )
        writer.close()
        with contextlib.suppress(Exception):
            await writer.wait_closed()
        return True
    except (OSError, asyncio.TimeoutError):
        return False


@app.get("/api/version", response_model=VersionInfo)
async def version(request: Request) -> VersionInfo:
    """Wer antwortet hier, mit welchem Vertrag? Ohne Token abrufbar, damit ein Client
    vor der Anmeldung pruefen kann, ob er richtig ist -- und mit Token, ob er gilt."""
    return VersionInfo(
        name="NV-AI",
        version=__version__,
        api=API_VERSION,
        features=API_FEATURES,
        comfyui=comfy.installed_version(),
        auth="token" if config.API_TOKEN else "local",
        authorized=_authorized(request.headers, request.client),
        instance=config.INSTANCE_ID,
    )


@app.post("/api/shutdown")
async def shutdown(request: Request) -> dict[str, Any]:
    """Beendet NV-AI samt ComfyUI -- fuer den Beenden-Eintrag im Startmenue.
    Nur vom eigenen Rechner, auch mit gueltigem Token nicht von aussen."""
    if not _is_local(request.headers, request.client):
        raise HTTPException(403, t("Beenden geht nur vom eigenen Rechner aus.", "Shutdown is only allowed from this computer."))
    from . import serve
    if serve.server is not None:
        serve.server.should_exit = True
    else:
        # Gestartet ueber `uvicorn nvai.main:app` (start.ps1): wirkt wie Strg+C.
        signal.raise_signal(signal.SIGINT)
    return {"ok": True}


@app.get("/api/health")
async def health() -> dict[str, Any]:
    # Die Statusabfragen gehen an Dienste, die meist gar nicht laufen -- ComfyUI und
    # die beiden Mesh-Worker. Nacheinander liefen sie jeweils in ihren Timeout und
    # summierten sich auf ueber acht Sekunden, waehrend das Frontend beim Start
    # darauf wartet. Jetzt zuerst ein schneller Portcheck, und nur wer antwortet,
    # wird ueberhaupt gefragt -- alles gleichzeitig.
    workers = mesh_workers.all_workers()
    comfy_port = urlparse(config.COMFY_URL).port or 8188
    open_flags = await asyncio.gather(
        _port_open(comfy_port), *(_port_open(w.port) for w in workers)
    )
    comfy_up, worker_up = open_flags[0], open_flags[1:]

    async def _worker_health(w: Any, up: bool) -> dict[str, Any] | None:
        return await w.health(timeout=1.5) if up else None

    async def _comfy_stats(up: bool) -> dict[str, Any] | None:
        return await comfy.system_stats(timeout=1.5) if up else None

    stats, *worker_health = await asyncio.gather(
        _comfy_stats(comfy_up),
        *(_worker_health(w, up) for w, up in zip(workers, worker_up)),
    )

    # Karte per nvidia-smi erkennen -- das geht auch ohne laufendes ComfyUI und ist
    # die Grundlage dafuer, dass die Modellliste sagen kann, was hier hineinpasst.
    card = gpu_info.detect()
    gpu = None
    if stats and stats.get("devices"):
        d = stats["devices"][0]
        gpu = {
            "name": d.get("name"),
            "vram_total_mb": round(d.get("vram_total", 0) / 1024 / 1024),
            "vram_free_mb": round(d.get("vram_free", 0) / 1024 / 1024),
        }
    elif card:
        # Backend aus: Gesamtspeicher kennen wir trotzdem, den freien nicht.
        gpu = {"name": card["name"], "vram_total_mb": card["vram_total_mb"],
               "vram_free_mb": None}

    # Was liegt tatsaechlich im VRAM? ComfyUI verraet das nicht ueber die API,
    # deshalb fuehrt comfy.py selbst Buch; die Mesh-Worker melden es direkt.
    loaded: list[dict[str, str]] = []
    if stats is not None and comfy.loaded_model():
        loaded.append({"backend": "ComfyUI", "model": comfy.loaded_model()})
    for w, h in zip(workers, worker_health):
        if h and h.get("loaded"):
            loaded.append({"backend": w.name, "model": w.name})

    return {
        "vram_loaded": loaded,
        "ok": True,
        "comfy_running": stats is not None,
        "gpu": gpu,
        "active_models": registry.get_active_models(),
        "queue_depth": jobs.queue_depth(),
        "current_job": jobs.current_job_id(),
        "download_queue_depth": jobs.download_queue_depth(),
        "current_download": jobs.current_download_id(),
        "hf_token": registry.hf_token() is not None,
        # Alle Karten (experimentell seit 0.5): Hersteller, Speicher, wofuer sie rechnen.
        "gpus": _gpus_overview(),
        "text_backend": {
            "separate": gpu_info.separate_text_backend(),
            "running": gpu_info.separate_text_backend() and await comfy.TEXT.is_running(timeout=0.5),
            "loaded": comfy.TEXT.loaded if gpu_info.separate_text_backend() else None,
        },
        # Wieviel VRAM einem Modell realistisch bleibt, und ab wann es eng wird.
        "vram_budget_gb": gpu_info.budget_gb(),
        # Eine Antwort des Workers heisst: er laeuft. Eine zweite Anfrage dafuer
        # waere nur ein weiterer Timeout.
        "mesh_workers": {
            w.key: {"name": w.name, "ready": w.is_set_up(), "running": h is not None}
            for w, h in zip(workers, worker_health)
        },
    }


@app.post("/api/backend/start")
async def backend_start() -> dict[str, Any]:
    if await comfy.is_running():
        return {"started": False, "reason": "laeuft bereits"}
    comfy.start()
    ready = await comfy.wait_until_ready()
    return {"started": ready}


@app.get("/api/backend/log")
async def backend_log(lines: int = 60, worker: str = "comfy") -> dict[str, str]:
    """Letzte Logzeilen eines Backends -- erster Anlaufpunkt, wenn ein Job scheitert."""
    if worker in mesh_workers.BY_WORKFLOW:
        tail = mesh_workers.BY_WORKFLOW[worker].log_tail(lines)
    elif worker == "text":
        tail = comfy.TEXT.log_tail(lines)
    else:
        tail = comfy.log_tail(lines)
    return {"log": tail, "worker": worker}


# ------------------------------------------------------------- Grafikkarten

def _gpus_overview() -> list[dict[str, Any]]:
    """Alle Karten mit Belegung und den Aufgaben, die sie gerade haben."""
    cards = gpu_info.list_gpus()
    used = gpu_info.usage()
    roles = gpu_info.assignment()
    out = []
    for c in cards:
        out.append({
            **c,
            "vram_used_mb": used.get(c["index"]),
            "roles": [r for r in gpu_info.ROLES if roles[r] == c["index"]] if len(cards) > 1
            else list(gpu_info.ROLES),
        })
    return out


@app.get("/api/gpus")
async def get_gpus() -> dict[str, Any]:
    """Karten und Zuordnung: image (Bildmodelle), text (Sprachmodelle: Prompt-Upsampler,
    Prompt ausbauen), mesh (3D). Experimentell seit 0.5."""
    return {"gpus": _gpus_overview(), "assignment": gpu_info.assignment(),
            "vendor": gpu_info.vendor(),
            "separate_text_backend": gpu_info.separate_text_backend()}


@app.put("/api/gpus")
async def put_gpus(body: dict[str, int]) -> dict[str, Any]:
    """Neue Zuordnung speichern. Laufende Backends werden beendet und starten beim
    naechsten Job auf der neuen Karte -- deshalb nur, wenn gerade nichts rechnet."""
    if jobs.current_job_id():
        raise HTTPException(409, t("Gerade läuft ein Job. Danach noch einmal versuchen.",
                                   "A job is running. Please try again afterwards."))
    try:
        new = gpu_info.set_assignment(body)
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    comfy.stop()
    for w in mesh_workers.all_workers():
        if await w.is_running():
            await w.unload()
        w.stop()
    return {"assignment": new, "separate_text_backend": gpu_info.separate_text_backend()}


@app.post("/api/backend/free")
async def backend_free() -> dict[str, Any]:
    """Gibt den VRAM frei: ComfyUI entladen, Mesh-Worker entladen."""
    await comfy.free_memory()
    freed = ["ComfyUI"]
    for w in mesh_workers.all_workers():
        if await w.is_running():
            await w.unload()
            freed.append(w.name)
    return {"ok": True, "freed": freed}


@app.post("/api/jobs/current/cancel")
async def cancel_current_job() -> dict[str, Any]:
    """Stoppt den laufenden GPU-Job. Downloads bleiben unberuehrt."""
    return await jobs.cancel_current()


# ----------------------------------------------------------- Modelle

@app.get("/api/models", response_model=list[ModelInfo])
async def get_models(kind: str | None = None) -> list[ModelInfo]:
    return registry.list_models(kind=kind)


@app.get("/api/settings/hf-token")
async def hf_token_status() -> dict[str, Any]:
    """Ist ein Hugging-Face-Token hinterlegt, und fuer wen? Fuer gated Repos wie FLUX 3."""
    token = registry.hf_token()
    if not token:
        return {"logged_in": False, "name": None}
    try:
        from huggingface_hub import whoami
        info = await asyncio.to_thread(whoami, token)
        return {"logged_in": True, "name": info.get("name")}
    except Exception:   # Netz weg oder Token ungueltig -- beides ist hier keine Ausnahme
        return {"logged_in": True, "name": None}


@app.post("/api/settings/hf-token")
async def set_hf_token(request: Request, body: dict[str, str]) -> dict[str, Any]:
    """Prueft den Token bei Hugging Face und speichert ihn wie `hf auth login`.
    Nur vom eigenen Rechner -- ein Token ist ein Geheimnis des Nutzers."""
    if not _is_local(request.headers, request.client):
        raise HTTPException(403, t("Den Token nur am eigenen Rechner eintragen.", "Enter the token on this computer only."))
    token = (body.get("token") or "").strip()
    from huggingface_hub import login, whoami
    try:
        info = await asyncio.to_thread(whoami, token)
    except Exception as e:
        raise HTTPException(400, t("Hugging Face lehnt den Token ab.", "Hugging Face rejected the token.")) from e
    await asyncio.to_thread(login, token=token, add_to_git_credential=False,
                            skip_if_logged_in=False)
    return {"logged_in": True, "name": info.get("name")}


@app.delete("/api/settings/hf-token")
async def delete_hf_token(request: Request) -> dict[str, Any]:
    if not _is_local(request.headers, request.client):
        raise HTTPException(403, t("Nur vom eigenen Rechner.", "Only from this computer."))
    from huggingface_hub import logout
    try:
        await asyncio.to_thread(logout)
    except Exception:   # war gar keiner gespeichert
        pass
    return {"logged_in": bool(registry.hf_token()), "name": None}


@app.get("/api/models/search")
async def search_models(q: str, limit: int = 20) -> list[dict[str, Any]]:
    """Weitere Modelle auf Hugging Face -- Repos samt Checkpoint-Dateien."""
    try:
        return await hfsearch.search(q, min(max(limit, 1), 50))
    except httpx.HTTPError as e:
        raise HTTPException(502, t(f"Hugging Face nicht erreichbar: {e}", f"Hugging Face not reachable: {e}")) from e


@app.get("/api/models/inspect")
async def inspect_model(repo: str, file: str) -> dict[str, Any]:
    """Prueft eine Datei vor dem Laden: Architektur aus dem safetensors-Kopf, Groesse."""
    return await hfsearch.inspect(repo, file)


@app.post("/api/models/download", response_model=Job)
async def download_model(req: DownloadRequest) -> Job:
    if req.model_id:
        entry = registry.get_entry(req.model_id)
        if entry is None:
            raise HTTPException(404, t(f"Unbekanntes Modell: {req.model_id}", f"Unknown model: {req.model_id}"))
    elif req.repo and req.file:
        entry = registry.register_custom(
            req.repo, req.file, req.target, req.kind, req.family, req.workflow,
            license_=req.license, size_gb=req.size_gb,
        )
    else:
        raise HTTPException(400, t("model_id oder repo+file erforderlich", "model_id or repo+file required"))
    return await jobs.submit(
        "download", {"entry": entry, "name": entry["name"], "clean": req.clean}
    )


@app.delete("/api/models/{model_id}", response_model=DeleteResult)
async def delete_model(model_id: str, forget: bool = False) -> DeleteResult:
    """Loescht die Modelldateien. `forget=true` entfernt zusaetzlich einen
    selbst hinzugefuegten Katalogeintrag."""
    entry = registry.get_entry(model_id)
    if entry is None:
        raise HTTPException(404, t(f"Unbekanntes Modell: {model_id}", f"Unknown model: {model_id}"))
    # Nur ein Job, der genau dieses Modell benutzt, darf blockieren.
    blocking = jobs.model_in_use(model_id)
    if blocking:
        raise HTTPException(409, t(f"Modell wird gerade von Job {blocking} benutzt.", f"Model is in use by job {blocking}."))

    # Dateien, die ein laufender Download gerade braucht, bleiben unangetastet.
    result = registry.delete(entry, protect_ids=jobs.models_downloading())
    if forget and entry.get("custom"):
        registry.remove_custom(model_id)
    return DeleteResult(model_id=model_id, **result)


@app.post("/api/downloads/cancel")
async def cancel_downloads() -> dict[str, Any]:
    """Bricht alle wartenden und den laufenden Download ab.

    Wartende Jobs werden uebersprungen, sobald sie drankommen. Der laufende
    Download steckt in einem Thread und laeuft bis zum Dateiende weiter --
    danach wird er nicht mehr fortgesetzt.
    """
    cancelled, running = [], None
    for job in db.list_jobs(limit=300):
        if job.kind != "download" or job.status not in ("queued", "running"):
            continue
        db.update_job(job.id, status="cancelled", finished_at=time.time(),
                      stage="vom Nutzer abgebrochen")
        cancelled.append(job.id)
        if job.status == "running":
            running = job.id
    return {
        "ok": True, "cancelled": len(cancelled), "was_running": running,
        "note": "Ein bereits laufender Dateidownload endet erst nach der aktuellen Datei.",
    }


@app.post("/api/models/cleanup")
async def cleanup_partial() -> dict[str, Any]:
    """Loescht unvollstaendige Modellinstallationen samt Fragmenten und HF-Cache."""
    active = set(jobs.models_downloading())
    cleaned = []
    for info in registry.list_models():
        if not info.partially_installed or info.id in active:
            continue
        entry = registry.get_entry(info.id)
        if entry is None:
            continue
        before = info.disk_gb
        removed = registry.clean_partial(entry)
        cleaned.append({"model_id": info.id, "name": info.name,
                        "removed_items": removed, "freed_gb": before})
    return {"ok": True, "cleaned": cleaned,
            "freed_gb": round(sum(c["freed_gb"] for c in cleaned), 2)}


@app.post("/api/models/{model_id}/favorite")
async def toggle_favorite(model_id: str, payload: dict[str, bool] | None = None) -> dict[str, Any]:
    """Setzt oder entfernt die Favoriten-Markierung. Ohne Rumpf wird umgeschaltet."""
    if registry.get_entry(model_id) is None:
        raise HTTPException(404, t(f"Unbekanntes Modell: {model_id}", f"Unknown model: {model_id}"))
    value = (payload or {}).get("favorite")
    if value is None:
        value = model_id not in registry.get_favorites()
    return {"model_id": model_id, "favorite": registry.set_favorite(model_id, bool(value))}


@app.post("/api/models/active")
async def set_active(payload: dict[str, str]) -> dict[str, Any]:
    model_id = payload.get("model_id", "")
    entry = registry.get_entry(model_id)
    if entry is None:
        raise HTTPException(404, t(f"Unbekanntes Modell: {model_id}", f"Unknown model: {model_id}"))
    if not registry.is_installed(entry):
        raise HTTPException(409, t(f"Modell '{model_id}' ist nicht vollständig heruntergeladen", f"Model '{model_id}' is not fully downloaded"))
    kind = registry.set_active_model(model_id)
    return {"active_model": model_id, "kind": kind}


@app.get("/api/models/checkpoints")
async def comfy_checkpoints() -> dict[str, Any]:
    """Was ComfyUI wirklich sieht -- hilfreich bei 'Modell da, aber nicht nutzbar'."""
    return {"checkpoints": await comfy.list_checkpoints()}


# --------------------------------------------------------- Generieren

@app.post("/api/generate/image", response_model=Job)
async def generate_image(req: GenerateImageRequest) -> Job:
    return await jobs.submit("txt2img", req.model_dump())


@app.post("/api/generate/audio", response_model=Job)
async def generate_audio(req: GenerateAudioRequest) -> Job:
    return await jobs.submit("txt2audio", req.model_dump())


@app.post("/api/generate/video", response_model=Job)
async def generate_video(req: GenerateVideoRequest) -> Job:
    return await jobs.submit("txt2video", req.model_dump())


@app.post("/api/generate/3d", response_model=Job)
async def generate_3d(req: Generate3DRequest) -> Job:
    """Bild zu Mesh. Laeuft in einem eigenen Worker-Prozess, nicht in ComfyUI."""
    if db.get_asset(req.image_asset_id) is None:
        raise HTTPException(404, t(f"Bild-Asset nicht gefunden: {req.image_asset_id}", f"Image asset not found: {req.image_asset_id}"))

    model_id = req.model_id or registry.get_active_model("3d")
    entry = registry.get_entry(model_id) if model_id else None
    if entry is None:
        raise HTTPException(409, t("Kein 3D-Modell installiert.", "No 3D model installed."))
    try:
        worker = mesh_workers.get(entry["workflow"])
    except RuntimeError as exc:
        raise HTTPException(409, str(exc)) from exc
    if not worker.is_set_up():
        raise HTTPException(
            409,
            f"{worker.name}-Worker ist nicht eingerichtet. "
            f"scripts/setup_{worker.key}.ps1 ausfuehren.",
        )
    return await jobs.submit("img23d", req.model_dump())


@app.post("/api/prompt/expand", response_model=ExpandPromptResult)
async def expand_prompt(req: ExpandPromptRequest) -> ExpandPromptResult:
    """Prompt ausbauen: der Upsampler von FLUX 3 macht aus einer knappen Eingabe eine
    volle Bildbeschreibung -- fuer jedes Bildmodell, nicht nur FLUX 3. Nur Text.

    Blockiert bis fertig. Laeuft in der GPU-Queue, wartet also hinter einem laufenden
    Bild. Der Job wird danach geloescht, damit der Verlauf nur Bilder zeigt.
    """
    if jobs.prompt_upsampler() is None:
        raise HTTPException(409, t(
            "Prompt ausbauen braucht den Upsampler von FLUX 3 Image Klein. Bitte "
            "flux3-klein-nvfp4 (RTX 50) oder flux3-klein-int8 herunterladen.",
            "Expanding a prompt needs the FLUX 3 Image Klein upsampler. Please download "
            "flux3-klein-nvfp4 (RTX 50) or flux3-klein-int8.",
        ))
    for asset_id in req.reference_asset_ids:
        if db.get_asset(asset_id) is None:
            raise HTTPException(404, t(f"Bild-Asset nicht gefunden: {asset_id}",
                                       f"Image asset not found: {asset_id}"))
    started = time.monotonic()
    job = await jobs.submit("expand_prompt", req.model_dump())
    current = None
    try:
        while True:
            await asyncio.sleep(0.3)
            current = db.get_job(job.id)
            if current is None or current.status in ("done", "error", "cancelled"):
                break
            if time.monotonic() - started > 900:
                raise HTTPException(504, t("Prompt ausbauen dauerte zu lange.",
                                           "Expanding the prompt took too long."))
    finally:
        if jobs.current_job_id() != job.id:
            db.delete_job(job.id)
    if current is None or current.status != "done" or not current.params.get("expanded"):
        detail = (current.error if current else None) or t("abgebrochen", "cancelled")
        raise HTTPException(500, detail)
    return ExpandPromptResult(prompt=req.prompt, expanded=current.params["expanded"],
                              seconds=round(time.monotonic() - started, 1))


# --------------------------------------------------------------- Jobs

@app.get("/api/jobs", response_model=list[Job])
async def get_jobs(limit: int = 50, offset: int = 0) -> list[Job]:
    return db.list_jobs(limit=limit, offset=offset)


@app.get("/api/jobs/{job_id}", response_model=Job)
async def get_job(job_id: str) -> Job:
    job = db.get_job(job_id)
    if job is None:
        raise HTTPException(404, t("Job nicht gefunden", "Job not found"))
    return job


@app.get("/api/jobs/{job_id}/assets", response_model=list[Asset])
async def get_job_assets(job_id: str) -> list[Asset]:
    return db.assets_for_job(job_id)


# ------------------------------------------------------------- Assets

@app.get("/api/assets", response_model=list[Asset])
async def get_assets(kind: str | None = None, limit: int = 100, offset: int = 0) -> list[Asset]:
    return db.list_assets(kind=kind, limit=limit, offset=offset)


@app.get("/api/assets/{asset_id}", response_model=Asset)
async def get_asset(asset_id: str) -> Asset:
    asset = db.get_asset(asset_id)
    if asset is None:
        raise HTTPException(404, t("Asset nicht gefunden", "Asset not found"))
    return asset


@app.delete("/api/assets/{asset_id}")
async def delete_asset(asset_id: str) -> dict[str, Any]:
    """Loescht ein einzelnes Asset samt Datei."""
    ok, freed = db.delete_asset(asset_id)
    if not ok:
        raise HTTPException(404, t("Asset nicht gefunden", "Asset not found"))
    return {"ok": True, "freed_mb": round(freed / 1024 / 1024, 2)}


@app.delete("/api/jobs/{job_id}")
async def delete_job(job_id: str) -> dict[str, Any]:
    """Loescht einen Verlaufseintrag mit allen erzeugten Dateien."""
    if jobs.current_job_id() == job_id:
        raise HTTPException(409, t("Dieser Job läuft gerade.", "This job is running right now."))
    ok, count, freed = db.delete_job(job_id)
    if not ok:
        raise HTTPException(404, t("Job nicht gefunden", "Job not found"))
    return {"ok": True, "assets": count, "freed_mb": round(freed / 1024 / 1024, 2)}


@app.delete("/api/history")
async def clear_history(kind: str | None = None) -> dict[str, Any]:
    """Leert den Verlauf -- alles oder nur einen Asset-Typ.
    Download-Jobs bleiben erhalten, die gehoeren zur Modellverwaltung."""
    # Nur eine laufende Generierung blockiert -- ein Modell-Download hat mit dem
    # Verlauf nichts zu tun und wird von clear_history ohnehin ausgespart.
    current = jobs.current_job_id()
    if current:
        running = db.get_job(current)
        if running and running.kind != "download":
            raise HTTPException(409, t("Es läuft gerade eine Generierung – bitte abwarten.", "A generation is running – please wait."))
    n_jobs, n_assets, freed = db.clear_history(kind)
    return {
        "ok": True, "jobs": n_jobs, "assets": n_assets,
        "freed_mb": round(freed / 1024 / 1024, 2),
    }


@app.post("/api/upload", response_model=Asset)
async def upload(file: UploadFile) -> Asset:
    """Bild-Upload -- Grundlage fuer den spaeteren Bild-zu-3D-Pfad."""
    config.ensure_dirs()
    suffix = Path(file.filename or "upload.png").suffix or ".png"
    name = f"{db.new_id('upl')}{suffix}"
    dest = config.ASSET_DIR / name
    with dest.open("wb") as fh:
        shutil.copyfileobj(file.file, fh)
    return db.create_asset(kind="upload", filename=name, meta={"original_name": file.filename})


# ---------------------------------------------------------- Live-Feed

@app.websocket("/ws")
async def ws_events(ws: WebSocket) -> None:
    # Die HTTP-Middleware sieht WebSockets nicht -- deshalb hier dieselbe Pruefung.
    # Schliessen vor accept() lehnt schon den Handshake ab (HTTP 403).
    if not _authorized(ws.headers, ws.client):
        await ws.close(code=1008)
        return
    await ws.accept()
    q = jobs.subscribe()
    try:
        while True:
            try:
                event = await asyncio.wait_for(q.get(), timeout=20.0)
            except TimeoutError:
                await ws.send_json({"type": "ping"})
                continue
            await ws.send_json(event)
    except WebSocketDisconnect:
        pass
    finally:
        jobs.unsubscribe(q)


# ------------------------------------------------------ Statische Files

# Typen, die Python selbst nicht kennt. Ohne den korrekten Typ liefert
# FileResponse application/octet-stream, womit manche Viewer nichts anfangen.
EXTRA_MIME = {
    ".glb": "model/gltf-binary",
    ".gltf": "model/gltf+json",
    ".webm": "video/webm",
    ".ply": "application/octet-stream",
}


# Im Schema stand vorher application/json -- geliefert wird aber die Datei selbst.
@app.get("/files/{filename}", response_class=FileResponse, responses={200: {
    "description": "Die Asset-Datei; der Typ folgt der Endung (png, wav, webm, glb ...)",
    "content": {"image/*": {}, "audio/*": {}, "video/*": {}, "model/gltf-binary": {},
                "application/octet-stream": {}},
}})
async def serve_file(filename: str) -> FileResponse:
    # Kein Pfad-Traversal: nur der Dateiname zaehlt.
    path = config.ASSET_DIR / Path(filename).name
    if not path.exists():
        raise HTTPException(404, t("Datei nicht gefunden", "File not found"))
    media_type = EXTRA_MIME.get(path.suffix.lower())
    return FileResponse(path, media_type=media_type)


_frontend_dist = config.ROOT / "frontend" / "dist"
if _frontend_dist.exists():
    app.mount("/", StaticFiles(directory=str(_frontend_dist), html=True), name="frontend")


def run() -> None:
    import uvicorn

    uvicorn.run(app, host=config.API_HOST, port=config.API_PORT, log_level="info")


if __name__ == "__main__":
    run()
