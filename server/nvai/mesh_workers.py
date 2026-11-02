"""Clients fuer die Worker-Prozesse: Mesh-Worker (TripoSG, TRELLIS.2) und seit 0.5.21 die Sprecherstimme
(Qwen3-TTS).

Alle laufen als eigener Prozess mit eigenem venv und sprechen dieselbe kleine
HTTP-Schnittstelle (/health, /generate, /unload; Qwen3-TTS dazu /cancel). Deshalb eine Klasse statt
fast identischer Module.

Warum ueberhaupt eigene Prozesse: Die Modelle brauchen unvereinbare torch- und
CUDA-Kombinationen und teils selbst kompilierte CUDA-Extensions. ComfyUI bleibt
davon unberuehrt.
"""
from __future__ import annotations

import asyncio
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Callable

import httpx

from . import config, gpu
from .i18n import t

WORKER_DIR = Path(__file__).resolve().parent.parent / "workers"


class MeshWorker:
    """Ein Bild-zu-Mesh-Worker als Kindprozess."""

    def __init__(
        self,
        key: str,
        name: str,
        repo_root: Path,
        script: str,
        port: int,
        env_prefix: str,
        package_dir: str,
        role: str = "mesh",
        extra_env: Callable[[], dict[str, str]] | None = None,
    ) -> None:
        self.key = key
        self.name = name
        self.repo_root = repo_root
        self.script = WORKER_DIR / script
        self.port = port
        self.env_prefix = env_prefix
        self.package_dir = package_dir
        self.role = role  # welche Karte (gpu.ROLES): 3D auf der 3D-Karte, die Stimme auf der fuer Bild/Video/Ton
        self.extra_env = extra_env
        self.log_path = config.DATA_DIR / f"{key}.log"
        self._proc: subprocess.Popen | None = None
        self._started_at: float | None = None

    # ------------------------------------------------------------ Zustand

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def python(self) -> Path:
        venv = self.repo_root / ".venv"
        return venv / ("Scripts/python.exe" if sys.platform == "win32" else "bin/python")

    def is_set_up(self) -> bool:
        return self.python().exists() and (self.repo_root / self.package_dir).is_dir()

    async def _port_open(self, timeout: float = 0.25) -> bool:
        """Schneller Portcheck. Unter Windows wartet ein Verbindungsversuch auf einen geschlossenen Port rund 2 s
        (gemessen 2.11.2026: 2,0-2,1 s je Worker); _ensure_backend fragt vor jedem Bild-, Video- und Tonauftrag alle
        Worker, das kostete 4-6 s je Auftrag. Ein laufender Worker nimmt die Verbindung sofort an."""
        try:
            _, writer = await asyncio.wait_for(asyncio.open_connection("127.0.0.1", self.port), timeout)
        except (OSError, asyncio.TimeoutError):
            return False
        writer.close()
        try:
            await writer.wait_closed()
        except OSError:
            pass
        return True

    async def is_running(self, timeout: float = 2.0) -> bool:
        if not await self._port_open():
            return False
        try:
            async with httpx.AsyncClient(timeout=timeout) as c:
                return (await c.get(f"{self.url}/health")).status_code == 200
        except (httpx.HTTPError, OSError):
            return False

    async def health(self, timeout: float = 5.0) -> dict[str, Any] | None:
        try:
            async with httpx.AsyncClient(timeout=timeout) as c:
                r = await c.get(f"{self.url}/health")
                r.raise_for_status()
                return r.json()
        except (httpx.HTTPError, OSError):
            return None

    # ------------------------------------------------------------- Prozess

    def _code_is_newer(self) -> bool:
        """Wurde der Worker-Code geaendert, seit der Prozess laeuft?

        Ein laufender Worker haelt seinen Code im Speicher -- Aenderungen wirken
        erst nach einem Neustart. Das einmal zu uebersehen kostet leicht eine
        Stunde Fehlersuche an einem Ergebnis, das mit altem Code entstand.
        """
        if self._started_at is None:
            return False
        newest = self.script.stat().st_mtime
        pkg = self.repo_root / self.package_dir
        if pkg.is_dir():
            for p in pkg.rglob("*.py"):
                newest = max(newest, p.stat().st_mtime)
        return newest > self._started_at

    def start(self, model_dir: Path) -> subprocess.Popen:
        if self._proc is not None and self._proc.poll() is None:
            if self._code_is_newer():
                print(f"[{self.name}] Code neuer als der laufende Prozess -- Neustart",
                      flush=True)
                self.stop()
            else:
                return self._proc
        py = self.python()
        if not py.exists():
            raise RuntimeError(t(
                f"{self.name}-venv fehlt: {py}\nBitte scripts/setup_{self.key}.ps1 ausfuehren.",
                f"{self.name} venv missing: {py}\nPlease run scripts/setup_{self.key}.ps1.",
            ))
        config.ensure_dirs()
        # Ausgabe in eine Datei, nicht in eine Pipe: die liefe sonst voll und
        # der Prozess blockierte beim Schreiben.
        log = self.log_path.open("a", encoding="utf-8", errors="replace")
        log.write(f"\n{'=' * 60}\nStart {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
        log.flush()

        import os

        env = dict(os.environ)
        env.pop("PYTHONPATH", None)  # sonst zieht der Worker Pakete aus dem falschen venv
        env[f"{self.env_prefix}_ROOT"] = str(self.repo_root)
        env[f"{self.env_prefix}_MODEL"] = str(model_dir)
        env[f"{self.env_prefix}_PORT"] = str(self.port)
        if gpu.multi_gpu():
            # Mehrere Karten (experimentell seit 0.5): der Worker sieht nur seine.
            env["CUDA_VISIBLE_DEVICES"] = str(gpu.device_for(self.role))
        if self.extra_env is not None:
            env.update(self.extra_env())

        self._proc = subprocess.Popen(
            [str(py), str(self.script)],
            cwd=str(self.repo_root),
            stdout=log,
            stderr=subprocess.STDOUT,
            env=env,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        self._started_at = time.time()
        return self._proc

    def stop(self) -> None:
        if self._proc is not None and self._proc.poll() is None:
            self._proc.terminate()
            try:
                self._proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self._proc.kill()
        self._proc = None
        self._started_at = None

    def log_tail(self, lines: int = 40) -> str:
        if not self.log_path.exists():
            return ""
        content = self.log_path.read_text(encoding="utf-8", errors="replace").splitlines()
        return "\n".join(content[-lines:])

    async def wait_until_ready(self, timeout: float = 420.0) -> bool:
        """Erster Start dauert: Torch-Import plus mehrere GB Modell von Platte."""
        loop = asyncio.get_running_loop()
        deadline = loop.time() + timeout
        while loop.time() < deadline:
            if await self.is_running():
                return True
            if self._proc is not None and self._proc.poll() is not None:
                code, tail = self._proc.returncode, self.log_tail(15)
                raise RuntimeError(t(
                    f"{self.name}-Worker beendet (Code {code}).\n"
                    f"Letzte Logzeilen:\n{tail}",
                    f"{self.name} worker exited (code {code}).\n"
                    f"Last log lines:\n{tail}",
                ))
            await asyncio.sleep(2.0)
        return False

    async def unload(self) -> None:
        try:
            async with httpx.AsyncClient(timeout=60.0) as c:
                await c.post(f"{self.url}/unload")
        except (httpx.HTTPError, OSError):
            pass

    async def cancel(self) -> bool:
        """Laufenden Auftrag anhalten, ohne den Prozess zu beenden (nur Worker mit /cancel, z. B. Qwen3-TTS)."""
        try:
            async with httpx.AsyncClient(timeout=5.0) as c:
                return (await c.post(f"{self.url}/cancel")).status_code == 200
        except (httpx.HTTPError, OSError):
            return False

    # ---------------------------------------------------------- Generierung

    async def generate(self, payload: dict[str, Any], timeout: float = 2400.0) -> dict[str, Any]:
        async with httpx.AsyncClient(timeout=timeout) as c:
            r = await c.post(f"{self.url}/generate", json=payload)
            if r.status_code >= 400:
                detail = r.text
                if r.headers.get("content-type", "").startswith("application/json"):
                    detail = r.json().get("detail", r.text)
                raise RuntimeError(f"{self.name}: {detail}")
            return r.json()


TRIPOSG = MeshWorker(
    key="triposg",
    name="TripoSG",
    repo_root=config.TRIPOSG_ROOT,
    script="triposg_worker.py",
    port=8200,
    env_prefix="TRIPOSG",
    package_dir="triposg",
)

TRELLIS2 = MeshWorker(
    key="trellis2",
    name="TRELLIS.2",
    repo_root=config.TRELLIS2_ROOT,
    script="trellis2_worker.py",
    port=8201,
    env_prefix="TRELLIS2",
    package_dir="trellis2",
)

def _site_packages(venv: Path) -> Path:
    return venv / "Lib" / "site-packages" if sys.platform == "win32" else next(
        iter(sorted((venv / "lib").glob("python3*/site-packages"))), venv / "lib" / "site-packages")


def _qwen3tts_env() -> dict[str, str]:
    """PyTorch fuer den Stimm-Worker kommt aus dem venv von ComfyUI (gleiche CUDA- bzw. ROCm-Fassung, kein zweites
    PyTorch auf der Platte); der Worker haengt den Pfad hinten an sys.path."""
    return {"QWEN3TTS_TORCH_SITE": str(_site_packages(config.COMFY_ROOT / ".venv"))}


QWEN3TTS = MeshWorker(
    key="qwen3tts",
    name="Qwen3-TTS",
    repo_root=config.QWEN3TTS_ROOT,
    script="qwen3tts_worker.py",
    port=config.QWEN3TTS_PORT,
    env_prefix="QWEN3TTS",
    package_dir=str(_site_packages(Path(".venv")) / "faster_qwen3_tts"),
    role="image",
    extra_env=_qwen3tts_env,
)

# Zuordnung workflow-Schluessel aus catalog.py -> Worker
BY_WORKFLOW: dict[str, MeshWorker] = {
    "triposg": TRIPOSG,
    "trellis2": TRELLIS2,
    "qwen3tts": QWEN3TTS,
}


def get(workflow: str) -> MeshWorker:
    worker = BY_WORKFLOW.get(workflow)
    if worker is None:
        raise RuntimeError(t(f"Kein Mesh-Worker fuer Workflow '{workflow}'",
                             f"No mesh worker for workflow '{workflow}'"))
    return worker


def all_workers() -> list[MeshWorker]:
    return list(BY_WORKFLOW.values())


def stop_all() -> None:
    for w in BY_WORKFLOW.values():
        w.stop()
