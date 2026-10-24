"""Einstieg: ``python -m bridge [--launch] [--server] [--browser]``."""
from __future__ import annotations

import argparse
import logging
import logging.handlers
import sys
import threading
import time
import webbrowser

import httpx

from . import __version__, config, launcher


def setup_logging() -> None:
    config.ensure_dirs()
    handlers: list[logging.Handler] = [logging.handlers.RotatingFileHandler(
        config.LOG_DIR / "bridge.log", maxBytes=2_000_000, backupCount=3, encoding="utf-8")]
    if sys.stderr is not None:  # unter pythonw.exe gibt es keine Konsole
        handlers.append(logging.StreamHandler())
    logging.basicConfig(level=logging.INFO, handlers=handlers,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    # Jede Statusabfrage an NVAI-open wäre sonst eine Logzeile.
    logging.getLogger("httpx").setLevel(logging.WARNING)


def bridge_url() -> str:
    return f"http://{config.BRIDGE_HOST}:{config.BRIDGE_PORT}"


def bridge_running() -> bool:
    try:
        r = httpx.get(f"{bridge_url()}/api/state", timeout=1.5)
        return r.status_code == 200 and "bridge" in r.json()
    except (httpx.HTTPError, ValueError):
        return False


def start_server() -> tuple[object, threading.Thread]:
    import uvicorn

    from . import server

    server.mount_static()
    server.tasks.cleanup()
    server.tasks.load_history()
    threading.Thread(target=server.tasks.cleanup_uploads, name="cleanup", daemon=True).start()
    uv = uvicorn.Server(uvicorn.Config(server.app, host=config.BRIDGE_HOST, port=config.BRIDGE_PORT,
                                       log_level="warning", log_config=None))
    thread = threading.Thread(target=uv.run, name="uvicorn", daemon=True)
    thread.start()
    deadline = time.monotonic() + 15
    while not uv.started and thread.is_alive() and time.monotonic() < deadline:
        time.sleep(0.05)
    if not uv.started:
        raise SystemExit(f"Server konnte nicht auf {bridge_url()} starten (Port belegt?).")
    return uv, thread


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(prog="python -m bridge", description="NVAI-open as the local AI for PhotoCraft")
    ap.add_argument("--launch", action="store_true",
                    help="start NVAI-open and PhotoCraft (with control channel), then open the panel")
    ap.add_argument("--server", action="store_true", help="only start the server, no window")
    ap.add_argument("--browser", action="store_true", help="open the panel in the default browser")
    args = ap.parse_args(argv)
    setup_logging()
    log = logging.getLogger("bridge")
    log.info("ArtCraft-LocalAI %s", __version__)
    # Für die Fehlersuche bei Testern: was die Brücke vorgefunden hat.
    install = config.nvai_setup()
    log.info("NVAI-open: %s%s", config.NVAI_URL,
             f" – Setup {install.version or '?'} in {install.install_dir}" if install else "")
    found = launcher.photocraft_install()
    log.info("PhotoCraft: %s", f"{found['exe']} ({found['version'] or 'Version unbekannt'})"
             if found["installed"] else "nicht installiert")

    if bridge_running():
        # Zweiter Start (etwa über die Verknüpfung): PhotoCraft nachstarten, falls es fehlt,
        # und das vorhandene Fenster nach vorn holen. Das geht von hier aus zuverlässiger als
        # aus dem Panel-Prozess: Windows lässt nur den Vordergrundprozess Fenster aktivieren.
        if args.launch:
            try:
                httpx.post(f"{bridge_url()}/api/photocraft/start", timeout=30)
            except httpx.HTTPError:
                pass
        from . import winutil

        hwnd = winutil.find_window()
        if hwnd:
            winutil.bring_to_front(hwnd)
        elif args.launch:
            webbrowser.open(bridge_url() + "/")  # Panel läuft im Browser (ohne WebView2)
        log.info("Brücke läuft bereits auf %s", bridge_url())
        return

    if args.launch:
        starters = [launcher.start_photocraft]
        if config.nvai_is_local():
            starters.insert(0, launcher.start_nvai)
        for start in starters:
            try:
                log.info(start())
            except launcher.LaunchError as exc:
                # Das Panel zeigt den Hinweis samt Knopf – hier nur protokollieren.
                log.warning("%s", exc)

    uv, thread = start_server()
    url = bridge_url() + "/"
    log.info("Panel: %s", url)
    try:
        from . import winutil

        if args.server:
            thread.join()
        elif args.browser or not winutil.webview2_available():
            if not args.browser:
                log.warning("Microsoft Edge WebView2 fehlt – das Panel öffnet im Standardbrowser")
            webbrowser.open(url)
            thread.join()
        else:
            try:
                from . import window
                window.run(url)
            except ImportError as exc:
                log.warning("pywebview nicht verfügbar (%s) – öffne den Browser", exc)
                webbrowser.open(url)
                thread.join()
    except KeyboardInterrupt:
        pass
    finally:
        log.info("Brücke wird beendet")
        uv.should_exit = True  # type: ignore[attr-defined]
        thread.join(timeout=5)


if __name__ == "__main__":
    main()
