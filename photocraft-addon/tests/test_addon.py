"""Add-on-Ordner für das NV-AI-Setup und das Windows-Symbol."""
from __future__ import annotations

import configparser
import struct
import sys
from pathlib import Path

import pytest
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

import build_addon  # noqa: E402
import make_icon  # noqa: E402

from bridge import __version__  # noqa: E402


def test_addon_folder(tmp_path):
    target = tmp_path / "addon"
    files = {p.relative_to(target).as_posix() for p in build_addon.build(target)}
    sources = {f"bridge/{p.name}" for p in (ROOT / "bridge").glob("*.py")}
    assert sources <= files
    assert {"addon.ini", "requirements.lock", "panel/index.html", "panel/panel.js", "panel/icon.ico"} <= files
    assert not [f for f in files if "__pycache__" in f or f.endswith(".pyc")]
    assert not [f for f in files if f.split("/")[0] not in ("bridge", "panel", "addon.ini", "requirements.lock")]

    ini = configparser.ConfigParser()
    ini.read_string((target / "addon.ini").read_text(encoding="utf-8"))
    addon = ini["addon"]
    assert addon["version"] == __version__
    assert (target / addon["requirements"]).is_file() and (target / addon["icon"]).is_file()
    assert addon["parameters"] == "-m bridge --launch"
    assert all(value.isascii() for value in addon.values())  # Inno Setup liest ANSI

    build_addon.build(target)  # eigener Ordner wird ersetzt


def test_foreign_folder_is_not_replaced(tmp_path):
    (tmp_path / "wichtig.txt").write_text("bleibt", encoding="utf-8")
    with pytest.raises(SystemExit, match="stammt nicht von diesem Skript"):
        build_addon.build(tmp_path)
    assert (tmp_path / "wichtig.txt").read_text(encoding="utf-8") == "bleibt"


def test_lock_matches_pyproject():
    assert build_addon.check_lock((ROOT / "requirements.lock").read_text(encoding="utf-8")) == []
    broken = "fastapi==1.0 \\\n    --hash=sha256:" + "0" * 64 + "\nuvicorn==1.0\n"
    problems = build_addon.check_lock(broken)
    assert "uvicorn ohne Prüfsumme" in problems
    assert any(p.startswith("httpx") and "fehlt" in p for p in problems)


def test_icon_frames():
    data = (ROOT / "panel" / "icon.ico").read_bytes()
    reserved, kind, count = struct.unpack_from("<HHH", data)
    assert (reserved, kind, count) == (0, 1, len(make_icon.SIZES))
    for i in range(count):
        width, height, _, _, planes, bits, size, offset = struct.unpack_from("<BBBBHHII", data, 6 + 16 * i)
        frame = data[offset:offset + size]
        if width == 0:  # 256 px als PNG, alles andere als BMP – das liest auch .NET
            assert frame.startswith(b"\x89PNG")
        else:
            assert struct.unpack_from("<Iii", frame) == (40, width, 2 * height)
            assert (planes, bits) == (1, 32)
    with Image.open(ROOT / "panel" / "icon.ico") as icon:
        assert sorted(icon.info["sizes"]) == [(n, n) for n in make_icon.SIZES]
