"""Sprache der Answers: English, Deutsch, Chinese or French.

The language is applied per request and comes from the Accept-Language header: if the first
entry starts with "de"/"zh"/"fr", NVAI-open replies accordingly, otherwise English. The Web UI
sends the selected language explicitly; URLSession (Mac) sends the system language automatically;
without a header (MCP, curl) English is used.

    from .i18n import t
    raise HTTPException(404, t("File not found", "File not found"))

Background tasks run in the language of the request that created them: asyncio
inherits the contextvars state when creating a Task.

Multi-language extension: ``t(de, en)`` keeps its two arguments. For zh/fr the
English text is looked up in the language pack ``langpacks/<code>.json``;
if not found, the English text is used as fallback. The packs reside next to
this file and are loaded once on import.
"""
from __future__ import annotations

import json
import re
from collections.abc import Iterator
from contextlib import contextmanager
from contextvars import ContextVar
from pathlib import Path

LANGUAGES = ("en", "de", "zh", "fr")
_LANG_PREFIX = {"de": "de", "zh": "zh", "fr": "fr"}
_PACK_DIR = Path(__file__).resolve().parent / "langpacks"
_packs: dict[str, dict[str, str]] = {}
# Dynamic text (f"...{var}...") templates: key is the English template with {0}/{1}, value is the translated template
_templates: dict[str, list[tuple[re.Pattern[str], str]]] = {}


def _norm_dynamic(text: str) -> str:
    """Replace variable parts in runtime text with {0} to match f-string templates.

    Only does conservative normalization: URLs, long numbers, quoted content, exception names, etc. Static words remain unchanged.
    """
    s = text
    # URL (with http(s) and bare domain paths)
    s = re.sub(r"https?://\S+", "{0}", s)
    # Quoted content (exception info often has '404 Not Found')
    s = re.sub(r"'[^']{1,200}'", "{0}", s)
    s = re.sub(r'"[^"]{1,200}"', "{0}", s)
    # Long numbers (with decimals, versions)
    s = re.sub(r"\b\d[\d._/-]*\b", "{0}", s)
    # Common exception/path snippets: C:\... or /path/to
    s = re.sub(r"[A-Za-z]:\\[^\s]+", "{0}", s)
    s = re.sub(r"(?<=\s)/[\w./-]+", "{0}", s)
    # Merge consecutive placeholders into one
    s = re.sub(r"\{0\}(?:\s*/\s*\{0\})+", "{0}", s)
    return s


def _compile_template(en_tpl: str, translation: str) -> tuple[re.Pattern[str], str] | None:
    """Compile 'Check failed: {0}' into regex, capturing variable parts."""
    parts = re.split(r"\{\d+\}", en_tpl)
    if len(parts) < 2:
        return None
    pattern = r"^\s*" + re.escape(parts[0])
    for p in parts[1:]:
        pattern += r"(.*?)" + re.escape(p)
    pattern += r"\s*$"
    try:
        return re.compile(pattern, re.S), translation
    except re.error:
        return None


def _load_packs() -> None:
    for code in ("zh", "fr"):
        path = _PACK_DIR / f"{code}.json"
        tpl_path = _PACK_DIR / f"{code}_templates.json"
        pack: dict[str, str] = {}
        try:
            pack = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            pass
        _packs[code] = pack
        # Template dictionary separate file
        compiled: list[tuple[re.Pattern[str], str]] = []
        tpl: dict[str, str] = {}
        try:
            tpl = json.loads(tpl_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            pass
        for en_tpl, translation in tpl.items():
            c = _compile_template(en_tpl, translation)
            if c:
                compiled.append(c)
        # Also identify {0} keys from the main dictionary
        for k, v in pack.items():
            if "{0}" in k and k not in tpl:
                c = _compile_template(k, v)
                if c:
                    compiled.append(c)
        _templates[code] = compiled


_load_packs()

_lang: ContextVar[str] = ContextVar("nvai_lang", default="en")


def from_header(accept_language: str | None) -> str:
    """'de-DE,de;q=0.9,en;q=0.8' -> 'de'; 'zh-CN,zh;q=0.9' -> 'zh'; otherwise 'en'."""
    if not accept_language:
        return "en"
    first = accept_language.split(",")[0].split(";")[0].strip().lower()
    for code, prefix in _LANG_PREFIX.items():
        if first.startswith(prefix):
            return code
    return "en"


def set_lang(lang: str) -> None:
    _lang.set(lang if lang in LANGUAGES else "en")


def lang() -> str:
    return _lang.get()


@contextmanager
def language(code: str | None) -> Iterator[None]:
    """Force work without request (Planner, alignment at startup): texts in the language the user selected;
    afterwards the previous language applies again."""
    token = _lang.set(code if code in LANGUAGES else "en")
    try:
        yield
    finally:
        _lang.reset(token)


def _translate(code: str, en: str) -> str:
    """Exact dictionary lookup; if failed, use normalization + template matching for dynamic text."""
    pack = _packs.get(code, {})
    hit = pack.get(en)
    if hit:
        return hit
    # Normalize dynamic parts and look up again
    norm = _norm_dynamic(en)
    if norm != en:
        hit = pack.get(norm)
        if hit:
            return hit
    # Template regex matching: fill captured variables from translated template
    for pattern, translation in _templates.get(code, []):
        m = pattern.match(en)
        if m:
            groups = list(m.groups())
            try:
                # Replace {0}/{1} in translation with captured groups (in template placeholder order)
                def repl(mm):
                    idx = int(mm.group(1))
                    return groups[idx] if idx < len(groups) else mm.group(0)
                return re.sub(r"\{(\d+)\}", repl, translation)
            except (IndexError, ValueError):
                return translation
    return en


def t(de: str, en: str) -> str:
    """Text in the language of the current request."""
    current = _lang.get()
    if current == "de":
        return de
    if current in ("zh", "fr"):
        return _translate(current, en)
    return en
