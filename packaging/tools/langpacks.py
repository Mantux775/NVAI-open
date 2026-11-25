"""Sprachpakete Chinesisch (zh) und Französisch (fr): welche Texte fehlen, welche Übersetzungen passen nicht.

Oberfläche und Server schreiben jeden Text als t("Deutsch", "English"). Für zh und fr schlägt t() den englischen Text
in einem Sprachpaket nach (Weboberfläche: frontend/src/langpacks/<code>.json, Server samt Modellkatalog:
server/nvai/langpacks/<code>.json); was fehlt, erscheint englisch. Vorlagen mit ${...} bzw. f-Strings stehen dort mit
{0}, {1} ... in der Reihenfolge im englischen Text.

    python -I -X utf8 packaging/tools/langpacks.py status                 # Abdeckung, Fehler, verwaiste Schlüssel
    python -I -X utf8 packaging/tools/langpacks.py missing zh fehlt.json  # fehlende Texte, zum Übersetzen
    python -I -X utf8 packaging/tools/langpacks.py merge zh neu.json      # Übersetzungen geprüft einpflegen
    python -I -X utf8 packaging/tools/langpacks.py prune                  # Schlüssel ohne Text im Code entfernen

Die Weboberfläche braucht dafür node und frontend/node_modules (npm install).
"""
from __future__ import annotations

import ast
import importlib
import json
import re
import subprocess
import sys
import tempfile
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CODES = ("zh", "fr")
PACKS = {"frontend": ROOT / "frontend" / "src" / "langpacks", "server": ROOT / "server" / "nvai" / "langpacks"}
# Felder des englischen Modellkatalogs (catalog_en.EN), die übersetzt werden; Namen und Lizenznamen bleiben.
CATALOG_FIELDS = ("best_for", "description", "pros", "cons", "warning", "license_badge", "output_badge")
CATALOG_FEATURES = ("prompt_hint", "tested")
_INVISIBLE = set("​‌‍⁠﻿‪‫‬‭‮⁦⁧⁨⁩")
_PLACEHOLDER = re.compile(r"\{[A-Za-z0-9_]*\}|%[sdif]")
_URL = re.compile(r"https?://[^\s\"')<>]+")


def frontend_strings() -> set[str]:
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "strings.json"
        subprocess.run(["node", str(ROOT / "frontend" / "scripts" / "langpack-strings.cjs"),
                        str(ROOT / "frontend" / "src"), str(out)], check=True)
        return set(json.loads(out.read_text(encoding="utf-8"))["strings"])


def _literal(node: ast.AST) -> str | None:
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.JoinedStr):
        parts, n = [], 0
        for v in node.values:
            if isinstance(v, ast.Constant):
                parts.append(str(v.value))
            else:
                parts.append("{%d}" % n)
                n += 1
        return "".join(parts)
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        a, b = _literal(node.left), _literal(node.right)
        if a is not None and b is not None:
            n = len(re.findall(r"\{\d+\}", a))
            return a + re.sub(r"\{(\d+)\}", lambda m: "{%d}" % (int(m.group(1)) + n), b)
    return None


def server_strings() -> set[str]:
    found: set[str] = set()
    for f in sorted((ROOT / "server" / "nvai").glob("*.py")):
        tree = ast.parse(f.read_text(encoding="utf-8-sig"))
        for node in ast.walk(tree):
            if not (isinstance(node, ast.Call) and len(node.args) == 2):
                continue
            fn = node.func
            name = fn.id if isinstance(fn, ast.Name) else fn.attr if isinstance(fn, ast.Attribute) else None
            if name == "t" and (en := _literal(node.args[1])) is not None:
                found.add(en)
    return found | catalog_strings()


def catalog_strings() -> set[str]:
    sys.path.insert(0, str(ROOT / "server"))
    try:
        cat = importlib.import_module("nvai.catalog_en")
    finally:
        sys.path.pop(0)
    found: set[str] = set(cat.SIZE_LABELS.values())
    for over in cat.EN.values():
        for key in CATALOG_FIELDS:
            v = over.get(key)
            found.update([v] if isinstance(v, str) else v or [])
        for key in CATALOG_FEATURES:
            if isinstance(v := (over.get("features") or {}).get(key), str):
                found.add(v)
    return {s for s in found if s.strip()}


def strings() -> dict[str, set[str]]:
    return {"frontend": frontend_strings(), "server": server_strings()}


def load(part: str, code: str) -> dict[str, str]:
    p = PACKS[part] / f"{code}.json"
    return json.loads(p.read_text(encoding="utf-8")) if p.exists() else {}


def save(part: str, code: str, pack: dict[str, str]) -> None:
    PACKS[part].mkdir(parents=True, exist_ok=True)
    text = json.dumps(dict(sorted(pack.items())), ensure_ascii=False, indent=1)
    (PACKS[part] / f"{code}.json").write_text(text + "\n", encoding="utf-8", newline="\n")


def problems(en: str, tr: str) -> list[str]:
    """Was an einer Übersetzung nicht stimmt; leer = gut."""
    out = []
    if not tr.strip():
        out.append("leer")
    if any(c in _INVISIBLE or unicodedata.category(c) == "Co" for c in tr):
        out.append("unsichtbare Zeichen")
    if sorted(_PLACEHOLDER.findall(en)) != sorted(_PLACEHOLDER.findall(tr)):
        out.append(f"Platzhalter {sorted(_PLACEHOLDER.findall(en))} != {sorted(_PLACEHOLDER.findall(tr))}")
    if sorted(_URL.findall(en)) != sorted(_URL.findall(tr)):
        out.append("Links weichen ab")
    if en.count("\n") != tr.count("\n"):
        out.append("Zeilenumbrüche weichen ab")
    if "—" in tr and "—" not in en:
        out.append("Gedankenstrich (—) neu")
    return out


def cmd_status() -> int:
    bad_total = 0
    for part, have in strings().items():
        for code in CODES:
            pack = load(part, code)
            bad = {k: p for k, v in pack.items() if (p := problems(k, v))}
            bad_total += len(bad)
            print(f"{part:8} {code}: {len(have & pack.keys())}/{len(have)} übersetzt, fehlen {len(have - pack.keys())}, "
                  f"verwaist {len(pack.keys() - have)}, fehlerhaft {len(bad)}")
            for k, p in list(bad.items())[:10]:
                print(f"    {k[:70]!r}: {', '.join(p)}")
    return 1 if bad_total else 0


def cmd_missing(code: str, out: str) -> int:
    rows = {}
    for part, have in strings().items():
        pack = load(part, code)
        rows.update({s: "" for s in sorted(have - pack.keys())})
    Path(out).write_text(json.dumps(rows, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"{len(rows)} fehlende Texte für {code} in {out}")
    return 0


def cmd_merge(code: str, src: str) -> int:
    new = json.loads(Path(src).read_text(encoding="utf-8"))
    have = strings()
    rejected, unknown, taken = [], [], 0
    packs = {part: load(part, code) for part in PACKS}
    for en, tr in new.items():
        if not isinstance(tr, str):
            continue
        tr = "".join(c for c in tr if c not in _INVISIBLE)
        if p := problems(en, tr):
            rejected.append((en, p))
            continue
        parts = [part for part in PACKS if en in have[part]]
        if not parts:
            unknown.append(en)
            continue
        for part in parts:
            packs[part][en] = tr
        taken += 1
    for part, pack in packs.items():
        save(part, code, pack)
    print(f"{code}: {taken} übernommen, {len(rejected)} abgelehnt, {len(unknown)} ohne Text im Code")
    for en, p in rejected[:20]:
        print(f"  abgelehnt {en[:70]!r}: {', '.join(p)}")
    for en in unknown[:10]:
        print(f"  unbekannt {en[:70]!r}")
    return 1 if rejected else 0


def cmd_prune() -> int:
    for part, have in strings().items():
        for code in CODES:
            pack = load(part, code)
            keep = {k: v for k, v in pack.items() if k in have}
            if len(keep) != len(pack):
                save(part, code, keep)
            print(f"{part} {code}: {len(pack) - len(keep)} verwaiste Schlüssel entfernt")
    return 0


def main(argv: list[str]) -> int:
    if argv[:1] == ["status"]:
        return cmd_status()
    if argv[:1] == ["missing"] and len(argv) == 3 and argv[1] in CODES:
        return cmd_missing(argv[1], argv[2])
    if argv[:1] == ["merge"] and len(argv) == 3 and argv[1] in CODES:
        return cmd_merge(argv[1], argv[2])
    if argv[:1] == ["prune"]:
        return cmd_prune()
    print(__doc__)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
