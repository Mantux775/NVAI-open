"""Das Panel als eigenes, schlankes Fenster (pywebview mit Edge WebView2)."""
from __future__ import annotations

import json
import logging
import os
from typing import Any

from . import config, server, winutil
from .i18n import t

log = logging.getLogger(__name__)

DEFAULT_SIZE = (430, 940)


def _load_state() -> dict[str, Any]:
    try:
        return json.loads(config.PANEL_STATE_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def _save_state(**changes: Any) -> None:
    state = _load_state()
    state.update(changes)
    try:
        config.PANEL_STATE_FILE.write_text(json.dumps(state), encoding="utf-8")
    except OSError as exc:
        log.warning("Fensterzustand nicht gespeichert: %s", exc)


def _own_window() -> int | None:
    return winutil.find_window(pid=os.getpid())


class Api:
    """Vom Panel per ``window.pywebview.api`` aufrufbar (läuft in einem eigenen Thread)."""

    def set_on_top(self, flag: bool) -> bool:
        hwnd = _own_window()
        if hwnd:
            winutil.set_topmost(hwnd, bool(flag))
        _save_state(on_top=bool(flag))
        return bool(flag)

    def get_on_top(self) -> bool:
        return bool(_load_state().get("on_top", True))


def title() -> str:
    return t("NV-AI für PhotoCraft", "NV-AI for PhotoCraft")


def retitle() -> None:
    """Titel an die gerade gewählte Sprache anpassen."""
    hwnd = _own_window()
    if hwnd:
        winutil.set_title(hwnd, title())


def focus() -> None:
    """Fenster wiederherstellen und nach vorn holen (für einen zweiten Start der Verknüpfung)."""
    hwnd = _own_window()
    if hwnd:
        winutil.bring_to_front(hwnd)
        if _load_state().get("on_top", True):
            winutil.set_topmost(hwnd, True)


def run(url: str) -> None:
    import webview

    state = _load_state()
    width, height = state.get("width", DEFAULT_SIZE[0]), state.get("height", DEFAULT_SIZE[1])
    x, y = state.get("x"), state.get("y")
    if x is None or y is None:
        try:
            screen = webview.screens[0]
            x, y = max(0, screen.width - width - 24), 72
        except (IndexError, AttributeError):
            x = y = None

    window = webview.create_window(
        title(), url, js_api=Api(),
        width=width, height=height, x=x, y=y, min_size=(360, 520),
        on_top=bool(state.get("on_top", True)), background_color="#262626", text_select=True,
    )
    server.focus_window = focus
    server.retitle_window = retitle
    try:
        window.events.moved += lambda x, y: _save_state(x=x, y=y)
        window.events.resized += lambda width, height: _save_state(width=width, height=height)
    except AttributeError:
        pass
    # Eigene ID und eigenes Symbol, sonst zeigt die Taskleiste das von Python. pywebview 6
    # übernimmt „icon“ auch unter WinForms, obwohl die Doku es nur für GTK/Qt nennt.
    winutil.set_app_id()
    icon = str(config.ICON_FILE) if config.ICON_FILE.is_file() else None
    webview.start(private_mode=False, storage_path=str(config.WEBVIEW_DIR), icon=icon)
    server.focus_window = server.retitle_window = None
