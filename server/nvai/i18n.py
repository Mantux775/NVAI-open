"""Sprache der Antworten: Englisch, auf Wunsch Deutsch, Chinesisch (vereinfacht) oder Franzoesisch.

Die Sprache gilt je Anfrage und kommt aus dem Header Accept-Language: beginnt die erste
Angabe mit "de", "zh" oder "fr", antwortet NVAI-open in dieser Sprache, sonst englisch. Die
Weboberflaeche schickt die gewaehlte Sprache ausdruecklich mit; URLSession (Mac) schickt die
Systemsprache von selbst; ohne Header (MCP, curl) gilt Englisch.

    from .i18n import t
    raise HTTPException(404, t("Datei nicht gefunden", "File not found"))

Chinesisch und Franzoesisch (seit 0.5.39, Grundlage aus PR #4): t() schlaegt den englischen Text im Sprachpaket
langpacks/<code>.json nach, f-Strings ueber Vorlagen mit {0}, {1} ... in der Reihenfolge im englischen Text; was
fehlt, bleibt englisch. Dort stehen auch die Texte des Modellkatalogs (registry.localized). Pflege:
packaging/tools/langpacks.py.

Hintergrundauftraege laufen in der Sprache der Anfrage, die sie angelegt hat: asyncio
uebernimmt den contextvars-Stand beim Anlegen eines Tasks.
"""
from __future__ import annotations

import json
import re
from collections.abc import Iterator
from contextlib import contextmanager
from contextvars import ContextVar
from functools import lru_cache
from pathlib import Path

LANGUAGES = ("en", "de", "zh", "fr")
PACK_LANGUAGES = ("zh", "fr")
_PACK_DIR = Path(__file__).resolve().parent / "langpacks"
_lang: ContextVar[str] = ContextVar("nvai_lang", default="en")


def from_header(accept_language: str | None) -> str:
    """'de-DE,de;q=0.9,en;q=0.8' -> 'de'; 'zh-CN,zh;q=0.9' -> 'zh'; 'fr-FR' -> 'fr'; alles andere -> 'en'."""
    if not accept_language:
        return "en"
    first = accept_language.split(",")[0].split(";")[0].strip().lower()
    return next((code for code in ("de", "zh", "fr") if first.startswith(code)), "en")


def set_lang(lang: str) -> None:
    _lang.set(lang if lang in LANGUAGES else "en")


def lang() -> str:
    return _lang.get()


@contextmanager
def language(code: str | None) -> Iterator[None]:
    """Fuer Arbeit ohne Anfrage (Planer, Abgleich beim Start): Texte in der Sprache, die der Nutzer beim Anlegen
    hatte; danach gilt wieder die vorige."""
    token = _lang.set(code if code in LANGUAGES else "en")
    try:
        yield
    finally:
        _lang.reset(token)


class _Pack:
    """Ein Sprachpaket: genaue Treffer und Vorlagen (f-Strings), die genaueste Vorlage zuerst."""

    def __init__(self, code: str, data: dict[str, str]) -> None:
        self.code = code
        self.exact: dict[str, str] = {}
        templates: list[tuple[int, re.Pattern[str], list[int], str]] = []
        for en, tr in data.items():
            if not re.search(r"\{\d+\}", en):
                self.exact[en] = tr
                continue
            parts = re.split(r"\{\d+\}", en)
            literal = "".join(parts)
            if not re.search(r"[^\W\d_]", literal):  # „{0} {1}“ passt auf alles
                continue
            pattern = re.compile("^" + "(.*?)".join(re.escape(p) for p in parts) + "$", re.S)
            order = [int(n) for n in re.findall(r"\{(\d+)\}", en)]
            templates.append((len(literal), pattern, order, tr))
        templates.sort(key=lambda x: -x[0])
        self.templates = [(p, o, tr) for _, p, o, tr in templates]

    def translate(self, en: str) -> str:
        hit = self.exact.get(en)
        return hit if hit is not None else _template_hit(self.code, en)


@lru_cache(maxsize=4096)
def _template_hit(code: str, en: str) -> str:
    """Text aus einem f-String über die passende Vorlage; Ergebnisse gemerkt (Fortschrittstexte kommen oft)."""
    pack = _pack(code)
    for pattern, order, tr in pack.templates if pack else ():
        if m := pattern.match(en):
            value = dict(zip(order, m.groups(), strict=False))
            return re.sub(r"\{(\d+)\}", lambda x: value.get(int(x.group(1)), x.group(0)), tr)
    return en


@lru_cache(maxsize=None)
def _pack(code: str) -> _Pack | None:
    """Sprachpaket einmal laden; fehlt oder bricht es, bleibt alles englisch."""
    try:
        data = json.loads((_PACK_DIR / f"{code}.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return _Pack(code, {k: v for k, v in data.items() if isinstance(k, str) and isinstance(v, str) and v})


def tr_en(en: str, code: str | None = None) -> str:
    """Englischen Text in die Sprache der Anfrage (bzw. `code`) bringen, soweit das Sprachpaket ihn kennt. Fuer Texte,
    die schon englisch vorliegen (Modellkatalog aus catalog_en)."""
    code = code or _lang.get()
    if code not in PACK_LANGUAGES or not en:
        return en
    pack = _pack(code)
    return pack.translate(en) if pack else en


def t(de: str, en: str) -> str:
    """Text in der Sprache der laufenden Anfrage."""
    code = _lang.get()
    if code == "de":
        return de
    if code in PACK_LANGUAGES:
        return tr_en(en, code)
    return en
