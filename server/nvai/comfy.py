"""Client fuer den ComfyUI-Backend-Prozess.

Wir sprechen ausschliesslich die HTTP-/WebSocket-API an -- ComfyUI bleibt eine
austauschbare Blackbox. Workflows werden hier als API-Format-Graph gebaut, damit
das Frontend nie Node-Graphen kennen muss.
"""
from __future__ import annotations

import asyncio
import json
import random
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any, Callable

import httpx
import websockets

from urllib.parse import urlparse

from . import config, gpu
from .i18n import t

ProgressCb = Callable[[float, str], None]

# Unter diesen Schluesseln liefert ComfyUI Ergebnisdateien -- je nach Save-Node.
OUTPUT_KEYS = ("images", "audio", "video", "gifs", "3d", "model_file", "result")

# Dateiendung -> Asset-Typ fuer die Library.
EXT_KIND = {
    ".png": "image", ".jpg": "image", ".jpeg": "image", ".webp": "image",
    ".mp3": "audio", ".flac": "audio", ".wav": "audio", ".opus": "audio", ".ogg": "audio",
    ".webm": "video", ".mp4": "video", ".mkv": "video", ".gif": "video",
    ".glb": "mesh", ".gltf": "mesh", ".obj": "mesh", ".ply": "mesh", ".stl": "mesh",
}


def kind_for(path: Path) -> str:
    return EXT_KIND.get(path.suffix.lower(), "image")


def _explain(message: str) -> str:
    """Haengt an bekannte ComfyUI-Fehler eine verwertbare Erklaerung an."""
    if "clip input is invalid" in message.lower():
        return f"{message}\n\n" + t(
            "Das bedeutet fast immer: Der Checkpoint enthaelt keinen Text-Encoder und "
            "braucht ihn als separate Datei. Betrifft reine Diffusion-Modelle wie Chroma. "
            "Im Katalog muss der Eintrag dann 'text_encoders' und 'vae' mitfuehren.",
            "This almost always means: the checkpoint contains no text encoder and "
            "needs it as a separate file. Affects pure diffusion models such as Chroma. "
            "The catalog entry must then include 'text_encoders' and 'vae'.",
        )
    if "not in list" in message and "ckpt_name" in message:
        return f"{message}\n\n" + t(
            "ComfyUI sieht die Modelldatei nicht. Liegt sie im richtigen Unterordner "
            "von external/comfyui/models/? Nach einem Download hilft ein Neuladen der Liste.",
            "ComfyUI cannot see the model file. Is it in the right subfolder "
            "of external/comfyui/models/? After a download, reloading the list helps.",
        )
    return message


# ------------------------------------------------------------ Prozess
#
# Normalerweise genau ein ComfyUI. Seit 0.5 (experimentell) optional ein zweites fuer
# die Sprachmodelle (FLUX-3-Upsampler, "Prompt ausbauen"), wenn die auf einer anderen
# Karte liegen als die Bildmodelle (gpu.separate_text_backend). Beide teilen sich
# Programm, Modelle und input/, haben aber eigene Benutzer-, Ausgabe- und Temp-Ordner --
# zwei Prozesse auf derselben ComfyUI-Datenbank vertragen sich nicht.


def _install_nodes() -> None:
    """NV-AIs eigene Knoten (nvai/comfy_nodes, z. B. der Audio-Limiter) nach ComfyUIs custom_nodes/
    legen, wenn sie dort fehlen oder veraltet sind. ComfyUI liest sie beim Start ein."""
    dest = config.COMFY_ROOT / "custom_nodes"
    if not dest.is_dir():
        return
    for src in Path(__file__).with_name("comfy_nodes").glob("*.py"):
        target = dest / src.name
        if not target.exists() or target.read_bytes() != src.read_bytes():
            shutil.copyfile(src, target)


def comfy_python() -> Path:
    """Interpreter des ComfyUI-venv (separat vom Server-venv, siehe Architektur)."""
    venv = config.COMFY_ROOT / ".venv"
    exe = venv / ("Scripts/python.exe" if sys.platform == "win32" else "bin/python")
    return exe


def installed_version() -> str | None:
    """ComfyUI-Version laut Installation -- auch ohne laufendes Backend."""
    try:
        text = (config.COMFY_ROOT / "comfyui_version.py").read_text(encoding="utf-8")
    except OSError:
        return None
    for line in text.splitlines():
        if line.startswith("__version__"):
            return line.split("=", 1)[1].strip().strip("\"'")
    return None


class Backend:
    """Ein ComfyUI-Prozess: Start, Status, Speicher freigeben, Abbrechen."""

    def __init__(self, key: str, url: str, role: str) -> None:
        self.key = key
        self.url = url
        self.role = role  # Rolle aus gpu.ROLES: auf welcher Karte er rechnet
        self.port = urlparse(url).port or 8188
        self.log_path = config.DATA_DIR / ("comfyui.log" if key == "main" else f"comfyui-{key}.log")
        self._proc: subprocess.Popen | None = None
        # Welches Modell zuletzt an dieses ComfyUI ging. ComfyUI selbst verraet das
        # nicht ueber die API, also fuehren wir Buch: gesetzt beim Start eines Jobs,
        # geloescht beim Freigeben oder Beenden.
        self.loaded: str | None = None

    async def is_running(self, timeout: float = 2.0) -> bool:
        try:
            async with httpx.AsyncClient(timeout=timeout) as c:
                return (await c.get(f"{self.url}/system_stats")).status_code == 200
        except (httpx.HTTPError, OSError):
            return False

    async def system_stats(self, timeout: float = 5.0) -> dict[str, Any] | None:
        try:
            async with httpx.AsyncClient(timeout=timeout) as c:
                r = await c.get(f"{self.url}/system_stats")
                r.raise_for_status()
                return r.json()
        except (httpx.HTTPError, OSError):
            return None

    def start(self) -> subprocess.Popen:
        """Startet ComfyUI headless als Kindprozess.

        Der Output geht in eine Logdatei, nicht in eine Pipe: ComfyUI schreibt beim
        Start mehr, als ein Pipe-Puffer fasst, und wuerde sonst beim Schreiben
        blockieren, solange niemand liest.
        """
        if self._proc is not None and self._proc.poll() is None:
            return self._proc
        py = comfy_python()
        if not py.exists():
            raise RuntimeError(t(
                f"ComfyUI-venv fehlt: {py}\nBitte scripts/setup_comfyui.ps1 ausfuehren.",
                f"ComfyUI venv missing: {py}\nPlease run scripts/setup_comfyui.ps1.",
            ))
        config.ensure_dirs()
        _install_nodes()
        log = self.log_path.open("a", encoding="utf-8", errors="replace")
        log.write(f"\n{'=' * 60}\nStart {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
        args = [str(py), "main.py", "--port", str(self.port), "--listen", "127.0.0.1",
                "--disable-auto-launch"]
        if config.MODEL_DIR_OVERRIDE:
            args += ["--models-directory", str(config.COMFY_MODEL_DIR)]
        if gpu.multi_gpu():
            # Erst mit mehreren Karten eine feste Karte vorgeben; mit einer bleibt alles
            # wie vor 0.5. ComfyUI setzt daraus CUDA_VISIBLE_DEVICES (bzw. HIP_*).
            args += ["--cuda-device", str(gpu.device_for(self.role))]
        if self.key != "main":
            own = config.DATA_DIR / f"comfy-{self.key}"
            for flag, sub in (("--user-directory", "user"), ("--output-directory", "output"),
                              ("--temp-directory", "temp")):
                (own / sub).mkdir(parents=True, exist_ok=True)
                args += [flag, str(own / sub)]
        log.write(f"Args: {' '.join(args[1:])}\n")
        log.flush()
        self._proc = subprocess.Popen(
            args,
            cwd=str(config.COMFY_ROOT),
            stdout=log,
            stderr=subprocess.STDOUT,
            # Ohne das oeffnet sich unter pythonw (installierte Fassung) ein Konsolenfenster.
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        return self._proc

    def log_tail(self, lines: int = 40) -> str:
        if not self.log_path.exists():
            return ""
        content = self.log_path.read_text(encoding="utf-8", errors="replace").splitlines()
        return "\n".join(content[-lines:])

    def stop(self) -> None:
        self.loaded = None
        if self._proc is not None and self._proc.poll() is None:
            self._proc.terminate()
        self._proc = None

    async def wait_until_ready(self, timeout: float = 180.0) -> bool:
        """ComfyUI braucht beim ersten Start lange (Torch-Import, Modell-Scan)."""
        loop = asyncio.get_running_loop()
        deadline = loop.time() + timeout
        while loop.time() < deadline:
            if await self.is_running():
                return True
            await asyncio.sleep(1.5)
        return False

    async def ensure(self) -> None:
        """Laeuft er nicht, starten und warten. Wirft mit dem Log-Ende, wenn er nicht kommt."""
        if await self.is_running():
            return
        self.start()
        if not await self.wait_until_ready():
            raise RuntimeError(t(
                f"ComfyUI ({self.key}) kam nicht hoch. Letzte Logzeilen:\n{self.log_tail(15)}",
                f"ComfyUI ({self.key}) did not come up. Last log lines:\n{self.log_tail(15)}",
            ))

    async def free_memory(self) -> None:
        """Modelle aus dem VRAM werfen -- vor dem Umschalten auf den 3D-Worker."""
        self.loaded = None
        try:
            async with httpx.AsyncClient(timeout=30.0) as c:
                await c.post(f"{self.url}/free", json={"unload_models": True, "free_memory": True})
        except (httpx.HTTPError, OSError):
            pass

    async def interrupt(self) -> bool:
        """Bricht die laufende Generierung ab. Ohne das rechnet ComfyUI weiter, auch
        wenn wir den Job-Task abbrechen -- die GPU bliebe belegt."""
        try:
            async with httpx.AsyncClient(timeout=15.0) as c:
                r = await c.post(f"{self.url}/interrupt")
                return r.status_code < 400
        except (httpx.HTTPError, OSError):
            return False


MAIN = Backend("main", config.COMFY_URL, "image")
TEXT = Backend("text", config.COMFY_TEXT_URL, "text")


def text_backend() -> Backend:
    """Wohin Textjobs (Upsampler) gehen: das eigene ComfyUI fuer Sprachmodelle, falls
    eingerichtet, sonst dasselbe wie fuer Bilder."""
    return TEXT if gpu.separate_text_backend() else MAIN


# Die bisherige Schnittstelle (ein ComfyUI) -- zeigt auf das Bild-Backend.
LOG_PATH = MAIN.log_path


async def is_running(timeout: float = 2.0) -> bool:
    return await MAIN.is_running(timeout)


async def system_stats(timeout: float = 5.0) -> dict[str, Any] | None:
    return await MAIN.system_stats(timeout)


def start() -> subprocess.Popen:
    return MAIN.start()


def log_tail(lines: int = 40) -> str:
    return MAIN.log_tail(lines)


def stop() -> None:
    """Beendet alle ComfyUI-Prozesse von NV-AI."""
    MAIN.stop()
    TEXT.stop()


async def wait_until_ready(timeout: float = 180.0) -> bool:
    return await MAIN.wait_until_ready(timeout)


def set_loaded_model(name: str | None) -> None:
    MAIN.loaded = name


def loaded_model() -> str | None:
    return MAIN.loaded


async def free_memory() -> None:
    """Gibt den VRAM aller laufenden ComfyUI frei."""
    await MAIN.free_memory()
    if await TEXT.is_running(timeout=1.0):
        await TEXT.free_memory()


async def interrupt() -> bool:
    return await MAIN.interrupt()


async def list_checkpoints() -> list[str]:
    """Fragt ComfyUI, welche Checkpoints es tatsaechlich sieht."""
    try:
        async with httpx.AsyncClient(timeout=10.0) as c:
            r = await c.get(f"{config.COMFY_URL}/object_info/CheckpointLoaderSimple")
            r.raise_for_status()
            info = r.json()["CheckpointLoaderSimple"]["input"]["required"]["ckpt_name"][0]
            return list(info)
    except (httpx.HTTPError, OSError, KeyError, IndexError):
        return []


def stage_input(src: Path) -> str:
    """Legt ein Startbild dort ab, wo LoadImage es findet, und gibt den Namen zurueck.

    ComfyUI kennt nur seinen eigenen input/-Ordner. Statt die Datei ueber die
    Upload-API zu schieben, kopieren wir sie direkt -- beides laeuft auf derselben
    Maschine. Der Praefix haelt gleichnamige Quellbilder auseinander.
    """
    dest_dir = config.COMFY_ROOT / "input"
    dest_dir.mkdir(parents=True, exist_ok=True)

    # Kopien von vorgestern raeumen wir weg -- sonst waechst der Ordner mit jedem
    # Bild-zu-Video-Lauf. Was juenger ist, koennte noch in einem Job stecken.
    cutoff = time.time() - 24 * 3600
    for old in dest_dir.glob("nvai_*"):
        try:
            if old.is_file() and old.stat().st_mtime < cutoff:
                old.unlink()
        except OSError:
            pass

    name = f"nvai_{uuid.uuid4().hex[:8]}{src.suffix.lower() or '.png'}"
    shutil.copy2(src, dest_dir / name)
    return name


# ----------------------------------------------------------- Ausfuehrung


async def run_workflow(
    workflow: dict[str, Any],
    on_progress: ProgressCb | None = None,
    timeout: float = 900.0,
) -> list[Path]:
    """Schickt einen Graphen an ComfyUI, verfolgt den Fortschritt und kopiert die
    Ergebnisse nach data/assets/. Gibt die lokalen Pfade zurueck."""
    files, _ = await _execute(workflow, on_progress, timeout, MAIN.url)
    return await _collect(files)


async def run_text_workflow(workflow: dict[str, Any], timeout: float = 600.0) -> list[str]:
    """Wie run_workflow, liefert aber Textausgaben (PreviewAny) statt Dateien --
    gebraucht fuer den Prompt-Upsampler von FLUX 3. Laeuft auf dem Text-Backend."""
    backend = text_backend()
    await backend.ensure()
    backend.loaded = "Prompt-Upsampler"
    _, texts = await _execute(workflow, None, timeout, backend.url)
    return texts


async def _execute(
    workflow: dict[str, Any],
    on_progress: ProgressCb | None,
    timeout: float,
    base_url: str,
) -> tuple[list[dict[str, Any]], list[str]]:
    """Gemeinsamer Kern: Graph abschicken, Websocket mitlesen, Datei- und Textausgaben
    einsammeln."""
    client_id = uuid.uuid4().hex
    ws_url = base_url.replace("http://", "ws://").replace("https://", "wss://")

    # Mehrstufige Graphen (Hires-Fix, Wan 2.2 mit zwei Experten) haben mehr als einen
    # Sampler. ComfyUI zaehlt je Sampler bei 0 los -- ohne diese Aufteilung faellt der
    # Balken beim Uebergang zurueck. Die IDs vergeben wir aufsteigend in Laufreihenfolge.
    sampler_ids = sorted(
        (nid for nid, n in workflow.items()
         if str(n.get("class_type", "")).startswith("KSampler")),
        key=lambda x: int(x) if str(x).isdigit() else 0,
    )
    stages = max(1, len(sampler_ids))

    async with websockets.connect(f"{ws_url}/ws?clientId={client_id}", max_size=None) as ws:
        async with httpx.AsyncClient(timeout=60.0) as http:
            r = await http.post(
                f"{base_url}/prompt", json={"prompt": workflow, "client_id": client_id}
            )
            if r.status_code != 200:
                raise RuntimeError(t(f"ComfyUI lehnte den Workflow ab: {r.text[:500]}",
                                     f"ComfyUI rejected the workflow: {r.text[:500]}"))
            prompt_id = r.json()["prompt_id"]

        outputs: list[dict[str, Any]] = []
        texts: list[str] = []
        try:
            async with asyncio.timeout(timeout):
                while True:
                    raw = await ws.recv()
                    if isinstance(raw, bytes):
                        continue  # Preview-Frames ignorieren wir
                    msg = json.loads(raw)
                    mtype, data = msg.get("type"), msg.get("data", {})
                    if data.get("prompt_id") not in (None, prompt_id):
                        continue

                    if mtype == "progress" and on_progress:
                        mx = max(1, data.get("max", 1))
                        val = data.get("value", 0)
                        node = str(data.get("node"))
                        idx = sampler_ids.index(node) if node in sampler_ids else 0
                        stage = f"Step {val}/{mx}"
                        if stages > 1:
                            stage = t(f"Durchgang {idx + 1}/{stages} · {stage}",
                                      f"Pass {idx + 1}/{stages} · {stage}")
                        on_progress((idx + val / mx) / stages, stage)
                    elif mtype == "executed":
                        outputs.extend(_files_from_output(data.get("output") or {}))
                        texts.extend(_texts_from_output(data.get("output") or {}))
                    elif mtype == "execution_error":
                        raise RuntimeError(_explain(data.get(
                            "exception_message", t("ComfyUI-Fehler", "ComfyUI error"))))
                    elif mtype == "executing" and data.get("node") is None:
                        break
        except TimeoutError as exc:
            raise RuntimeError(t(f"Timeout nach {timeout}s", f"Timeout after {timeout}s")) from exc

    # Fallback, falls die WS-Nachricht verpasst wurde -- oder ComfyUI die Ausgabe aus
    # seinem Cache nahm und deshalb gar kein "executed" schickte.
    if not outputs and not texts:
        outputs, texts = await _outputs_from_history(prompt_id, base_url)

    return outputs, texts


def _texts_from_output(node_output: dict[str, Any]) -> list[str]:
    """Textausgaben eines Nodes -- PreviewAny meldet sie unter "text"."""
    return [s for s in node_output.get("text") or [] if isinstance(s, str)]


def _files_from_output(node_output: dict[str, Any]) -> list[dict[str, Any]]:
    """Sammelt Dateiverweise aus einem Node-Output. Je nach Save-Node heisst der
    Schluessel images, audio, video oder 3d -- wir nehmen alles, was wie eine
    Datei aussieht."""
    found: list[dict[str, Any]] = []
    for key in OUTPUT_KEYS:
        for item in node_output.get(key) or []:
            if isinstance(item, dict) and "filename" in item:
                found.append(item)
    return found


async def _outputs_from_history(prompt_id: str, base_url: str) -> tuple[list[dict[str, Any]], list[str]]:
    """Fallback, falls die WS-Nachricht verpasst wurde."""
    async with httpx.AsyncClient(timeout=30.0) as c:
        r = await c.get(f"{base_url}/history/{prompt_id}")
        if r.status_code != 200:
            return [], []
        hist = r.json().get(prompt_id, {})
    files: list[dict[str, Any]] = []
    texts: list[str] = []
    for node_out in hist.get("outputs", {}).values():
        files.extend(_files_from_output(node_out))
        texts.extend(_texts_from_output(node_out))
    return files, texts


async def _collect(images: list[dict[str, Any]]) -> list[Path]:
    """Holt die Dateien aus ComfyUI und legt sie in data/assets/ ab."""
    config.ensure_dirs()
    paths: list[Path] = []
    async with httpx.AsyncClient(timeout=120.0) as c:
        for img in images:
            if img.get("type") == "temp":
                continue
            src = config.COMFY_ROOT / "output" / (img.get("subfolder") or "") / img["filename"]
            dest = config.ASSET_DIR / f"{uuid.uuid4().hex[:12]}_{img['filename']}"
            if src.exists():
                shutil.copy2(src, dest)
            else:
                r = await c.get(
                    f"{config.COMFY_URL}/view",
                    params={
                        "filename": img["filename"],
                        "subfolder": img.get("subfolder", ""),
                        "type": img.get("type", "output"),
                    },
                )
                r.raise_for_status()
                dest.write_bytes(r.content)
            paths.append(dest)
    return paths
