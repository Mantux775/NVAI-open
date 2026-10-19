"""Sprache von Oberfläche und Meldungen: Englisch ist Standard, Deutsch die Option.

Jeder sichtbare Text steht im Code als ``t("Deutsch", "English")``. Die Wahl („auto“, „en“,
„de“) steht in settings.json unter ``language``. „auto“ folgt der Windows-Anzeigesprache: Deutsch
nur, wenn die deutsch ist, sonst Englisch. NV-AI bekommt dieselbe Sprache als ``Accept-Language``
und liefert seine Modelltexte und Fehlermeldungen danach.
"""
from __future__ import annotations

import ctypes
import locale
import threading

CHOICES = ("auto", "en", "de")
_LANG_GERMAN = 0x07  # primäre Sprach-ID in einer Windows-LANGID

_lock = threading.Lock()
_choice = "auto"
_lang: str | None = None


def system_language() -> str:
    """„de“, wenn die Anzeigesprache des Systems Deutsch ist, sonst „en“."""
    try:
        return "de" if ctypes.windll.kernel32.GetUserDefaultUILanguage() & 0x3FF == _LANG_GERMAN else "en"
    except (AttributeError, OSError):  # nicht Windows
        code = (locale.getlocale()[0] or "").lower()
        return "de" if code.startswith(("de", "german")) else "en"


def choice() -> str:
    return _choice


def set_choice(value: str | None) -> None:
    """Sprachwahl setzen; Unbekanntes gilt als „auto“."""
    global _choice, _lang
    with _lock:
        _choice = value if value in CHOICES else "auto"
        _lang = None


def lang() -> str:
    """Wirksame Sprache, „de“ oder „en“."""
    global _lang
    with _lock:
        if _lang is None:
            _lang = _choice if _choice != "auto" else system_language()
        return _lang


def t(de: str, en: str) -> str:
    """Den Text in der gewählten Sprache: ``t("Deutsch", "English")``."""
    return de if lang() == "de" else en
