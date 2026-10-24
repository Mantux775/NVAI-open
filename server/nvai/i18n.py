"""Sprache der Antworten: Englisch, Deutsch auf Wunsch.

Die Sprache gilt je Anfrage und kommt aus dem Header Accept-Language: beginnt die erste
Angabe mit "de", antwortet NVAI-open deutsch, sonst englisch. Die Weboberflaeche schickt die
gewaehlte Sprache ausdruecklich mit; URLSession (Mac) schickt die Systemsprache von selbst;
ohne Header (MCP, curl) gilt Englisch.

    from .i18n import t
    raise HTTPException(404, t("Datei nicht gefunden", "File not found"))

Hintergrundauftraege laufen in der Sprache der Anfrage, die sie angelegt hat: asyncio
uebernimmt den contextvars-Stand beim Anlegen eines Tasks.
"""
from __future__ import annotations

from contextvars import ContextVar

LANGUAGES = ("en", "de")
_lang: ContextVar[str] = ContextVar("nvai_lang", default="en")


def from_header(accept_language: str | None) -> str:
    """'de-DE,de;q=0.9,en;q=0.8' -> 'de'; alles andere -> 'en'."""
    if not accept_language:
        return "en"
    first = accept_language.split(",")[0].split(";")[0].strip().lower()
    return "de" if first.startswith("de") else "en"


def set_lang(lang: str) -> None:
    _lang.set(lang if lang in LANGUAGES else "en")


def lang() -> str:
    return _lang.get()


def t(de: str, en: str) -> str:
    """Text in der Sprache der laufenden Anfrage."""
    return de if _lang.get() == "de" else en
