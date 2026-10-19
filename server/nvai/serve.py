"""NV-AI ohne Konsole betreiben -- Einstieg der installierten Windows-Fassung.

    pythonw -m nvai.serve

Wie `uvicorn nvai.main:app`, aber mit einem Griff auf den Server, damit
POST /api/shutdown ihn sauber beenden kann: der Lifespan raeumt ComfyUI und die
Mesh-Worker mit ab. Unter pythonw gibt es weder stdout noch stderr -- ohne
Umleitung scheitert schon uvicorns Logging. Die Ausgaben gehen deshalb immer
nach data/nvai-server.log -- auch wenn der Starter stdout auf NUL legt; dann ist
sys.stdout nicht None, und ein Test darauf liess das Protokoll leer (gemessen).
"""
from __future__ import annotations

import importlib
import sys

import uvicorn

from . import config

server: uvicorn.Server | None = None


def main() -> None:
    global server
    config.ensure_dirs()
    log = open(config.DATA_DIR / "nvai-server.log", "a", encoding="utf-8", buffering=1)
    sys.stdout = sys.stderr = log
    server = uvicorn.Server(uvicorn.Config(
        "nvai.main:app", host=config.API_HOST, port=config.API_PORT, log_level="info",
    ))
    # Als `python -m nvai.serve` laeuft diese Datei als __main__, main.py importiert
    # aber nvai.serve -- ein zweites Modulobjekt mit server = None. Dann fiel
    # /api/shutdown auf Strg+C zurueck und hinterliess einen Traceback (gemessen).
    importlib.import_module("nvai.serve").server = server
    server.run()


if __name__ == "__main__":
    main()
