"""Sprache von Oberfläche und Meldungen: Englisch is Standard, Deutsch/Chinese/French the Option.

Every visible text in the code is ``t("German", "English")``. The choice ("auto", "en",
"de", "zh", "fr") is stored in settings.json under ``language``. "auto" follows the Windows display language:
German/Chinese/French only if the system is, otherwise English. NVAI-open receives
the same language as ``Accept-Language`` and serves its model texts and error messages accordingly.

Multi-language extension: ``t(de, en)`` looks up the English text in the language pack
``langpacks/<code>.json`` for zh/fr (fallback -> English text). The packs are located in the bridge folder.
"""
from __future__ import annotations

import ctypes
import json
import locale
import re
import threading
from pathlib import Path

CHOICES = ("auto", "en", "de", "zh", "fr")
_LANG_GERMAN = 0x07   # primary language ID in a Windows-LANGID
_LANG_CHINESE = 0x04  # zh (neutral), 0x0804 zh-CN
_LANG_FRENCH = 0x0C   # fr (neutral), 0x040C fr-FR

_PACK_DIR = Path(__file__).resolve().parent / "langpacks"
_packs: dict[str, dict[str, str]] = {}
_templates: dict[str, list[tuple[re.Pattern[str], str]]] = {}


def _compile_template(en_tpl: str, translation: str) -> tuple[re.Pattern[str], str] | None:
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
        compiled: list[tuple[re.Pattern[str], str]] = []
        tpl: dict[str, str] = {}
        try:
            tpl = json.loads(tpl_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            pass
        for k, v in tpl.items():
            c = _compile_template(k, v)
            if c:
                compiled.append(c)
        _templates[code] = compiled


_load_packs()

_lock = threading.Lock()
_choice = "auto"
_lang: str | None = None


def system_language() -> str:
    """Language of Windows display: "de"/"zh"/"fr", otherwise "en"."""
    try:
        langid = ctypes.windll.kernel32.GetUserDefaultUILanguage() & 0x3FF
        if langid == _LANG_GERMAN:
            return "de"
        if langid == _LANG_CHINESE:
            return "zh"
        if langid == _LANG_FRENCH:
            return "fr"
        return "en"
    except (AttributeError, OSError):  # non-Windows
        code = (locale.getlocale()[0] or "").lower()
        if code.startswith(("zh", "chinese")):
            return "zh"
        if code.startswith("fr"):
            return "fr"
        if code.startswith(("de", "german")):
            return "de"
        return "en"


def choice() -> str:
    return _choice


def set_choice(value: str | None) -> None:
    """Set language choice; unknown values default to "auto"."""
    global _choice, _lang
    with _lock:
        _choice = value if value in CHOICES else "auto"
        _lang = None


def lang() -> str:
    """Effective language: "de", "zh", "fr" or "en"."""
    global _lang
    with _lock:
        if _lang is None:
            _lang = _choice if _choice != "auto" else system_language()
        return _lang


def _translate(code: str, en: str) -> str:
    pack = _packs.get(code, {})
    hit = pack.get(en)
    if hit:
        return hit
    for pattern, translation in _templates.get(code, []):
        m = pattern.match(en)
        if m:
            groups = list(m.groups())
            try:
                def repl(mm):
                    idx = int(mm.group(1))
                    return groups[idx] if idx < len(groups) else mm.group(0)
                return re.sub(r"\{(\d+)\}", repl, translation)
            except (IndexError, ValueError):
                return translation
    return en


def t(de: str, en: str) -> str:
    """The text in the selected language: ``t("German", "English")``."""
    current = lang()
    if current == "de":
        return de
    if current in ("zh", "fr"):
        return _translate(current, en)
    return en
