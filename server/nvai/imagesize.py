"""Breite und Hoehe eines Bildes aus dem Dateikopf -- ohne Pillow.

Der Server-venv hat bewusst keine Bildbibliothek; fuer Outpainting reicht die Groesse.
Gelesen werden PNG, JPEG und WebP, also alles, was Generierung und Upload liefern.
"""

from __future__ import annotations

import struct
from pathlib import Path


def size(path: Path) -> tuple[int, int] | None:
    """(Breite, Hoehe) oder None, wenn das Format unbekannt oder die Datei kaputt ist. Bei einem JPEG mit
    EXIF-Drehung um 90 Grad (Handyfoto hochkant) die aufrechten Masse, wie ComfyUI und der Browser das Bild zeigen."""
    with open(path, "rb") as f:
        head = f.read(32)
        if head[:8] == b"\x89PNG\r\n\x1a\n" and head[12:16] == b"IHDR":
            return struct.unpack(">II", head[16:24])
        if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
            return _webp(head)
        if head[:2] == b"\xff\xd8":
            f.seek(2)
            try:
                return _jpeg(f)
            except (struct.error, ValueError):
                return None
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
    # Segmente ueberspringen bis zum Frame-Kopf (SOF0..SOF15 ohne DHT/JPG/DAC); unterwegs die EXIF-Drehung merken.
    orientation = 1
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
        if kind == 0xE1:            # APP1, darin EXIF
            data = f.read(length - 2)
            if data[:6] == b"Exif\x00\x00":
                orientation = _orientation(data[6:]) or orientation
            continue
        if 0xC0 <= kind <= 0xCF and kind not in (0xC4, 0xC8, 0xCC):
            h, w = struct.unpack(">xHH", f.read(5))
            return (h, w) if orientation in (5, 6, 7, 8) else (w, h)
        f.seek(length - 2, 1)


def _orientation(tiff: bytes) -> int | None:
    """EXIF-Tag 0x0112 (Orientation) aus IFD0, 1 = aufrecht, 5..8 = um 90 Grad gedreht."""
    if tiff[:2] not in (b"II", b"MM"):
        return None
    end = "<" if tiff[:2] == b"II" else ">"
    (ifd,) = struct.unpack(end + "I", tiff[4:8])
    (count,) = struct.unpack(end + "H", tiff[ifd:ifd + 2])
    for i in range(count):
        entry = tiff[ifd + 2 + 12 * i: ifd + 14 + 12 * i]
        if len(entry) < 12:
            break
        tag, typ = struct.unpack(end + "HH", entry[:4])
        if tag == 0x0112 and typ == 3:
            return struct.unpack(end + "H", entry[8:10])[0]
    return None
