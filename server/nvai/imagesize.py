"""Breite und Hoehe eines Bildes aus dem Dateikopf -- ohne Pillow.

Der Server-venv hat bewusst keine Bildbibliothek; fuer Outpainting reicht die Groesse.
Gelesen werden PNG, JPEG und WebP, also alles, was Generierung und Upload liefern.
"""

from __future__ import annotations

import struct
from pathlib import Path


def size(path: Path) -> tuple[int, int] | None:
    """(Breite, Hoehe) oder None, wenn das Format unbekannt oder die Datei kaputt ist."""
    with open(path, "rb") as f:
        head = f.read(32)
        if head[:8] == b"\x89PNG\r\n\x1a\n" and head[12:16] == b"IHDR":
            return struct.unpack(">II", head[16:24])
        if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
            return _webp(head)
        if head[:2] == b"\xff\xd8":
            f.seek(2)
            return _jpeg(f)
    return None


def _webp(head: bytes) -> tuple[int, int] | None:
    chunk = head[12:16]
    if chunk == b"VP8X":
        w = int.from_bytes(head[24:27], "little") + 1
        h = int.from_bytes(head[27:30], "little") + 1
        return w, h
    if chunk == b"VP8L":
        bits = int.from_bytes(head[21:25], "little")
        return (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
    if chunk == b"VP8 ":
        w, h = struct.unpack("<HH", head[26:30])
        return w & 0x3FFF, h & 0x3FFF
    return None


def _jpeg(f) -> tuple[int, int] | None:
    # Segmente ueberspringen bis zum Frame-Kopf (SOF0..SOF15 ohne DHT/JPG/DAC).
    while True:
        marker = f.read(2)
        if len(marker) < 2 or marker[0] != 0xFF:
            return None
        kind = marker[1]
        if kind == 0xFF:            # Fuellbyte
            f.seek(-1, 1)
            continue
        if kind in (0xD8, 0x01) or 0xD0 <= kind <= 0xD7:
            continue
        length = struct.unpack(">H", f.read(2))[0]
        if 0xC0 <= kind <= 0xCF and kind not in (0xC4, 0xC8, 0xCC):
            h, w = struct.unpack(">xHH", f.read(5))
            return w, h
        f.seek(length - 2, 1)
