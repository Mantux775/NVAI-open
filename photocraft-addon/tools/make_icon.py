"""Windows-Symbol ``panel/icon.ico``: das Funkeln des Panel-Logos auf blau-violettem Verlauf.

Gegenstück zu MacApp/tools/make-icon.swift, aber als abgerundete Kachel – Windows legt keine
Form über das Symbol. Jede Größe wird einzeln gezeichnet (vierfach überabgetastet), damit auch
16 px scharf bleiben. Gebraucht wird es für das Panel-Fenster, die Taskleiste und die
Startmenü-Verknüpfung des Setups.

    python tools/make_icon.py [Ziel]        Standard: panel/icon.ico
"""
from __future__ import annotations

import io
import struct
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
TARGET = ROOT / "panel" / "icon.ico"
SIZES = (16, 20, 24, 32, 40, 48, 64, 128, 256)
SUPERSAMPLE = 4
TOP_LEFT = (69, 148, 250)       # wie make-icon.swift: sRGB 0.27 / 0.58 / 0.98
BOTTOM_RIGHT = (115, 77, 230)   # sRGB 0.45 / 0.30 / 0.90
# Sterne aus panel/index.html (24er-Raster, y nach unten).
STARS = (
    ((11, 2.5), (12.8, 7.7), (18, 9.5), (12.8, 11.3), (11, 16.5), (9.2, 11.3), (4, 9.5), (9.2, 7.7)),
    ((18.5, 14), (19.4, 16.6), (22, 17.5), (19.4, 18.4), (18.5, 21), (17.6, 18.4), (15, 17.5), (17.6, 16.6)),
)


def render(size: int) -> Image.Image:
    s = size * SUPERSAMPLE
    # Diagonaler Verlauf: Mittel aus waagerechtem und senkrechtem Verlauf.
    vertical = Image.linear_gradient("L").resize((s, s))
    ramp = ImageChops.add(vertical, vertical.transpose(Image.Transpose.TRANSPOSE), scale=2.0)
    tile = Image.composite(Image.new("RGB", (s, s), BOTTOM_RIGHT), Image.new("RGB", (s, s), TOP_LEFT), ramp)

    # Abgerundete Kachel; kleine Größen ohne Rand, damit sie nicht schrumpfen.
    margin = 0 if size <= 24 else s // 32
    shape = Image.new("L", (s, s), 0)
    ImageDraw.Draw(shape).rounded_rectangle((margin, margin, s - 1 - margin, s - 1 - margin),
                                            radius=round(s * 0.2), fill=255)

    # Sterne: Mitte (13 | 11,75) auf die Bildmitte, etwas kleiner als auf dem Mac (Kachelrand).
    scale = s / 24 * 0.8
    stars = Image.new("L", (s, s), 0)
    draw = ImageDraw.Draw(stars)
    for star in STARS:
        draw.polygon([(s / 2 + (x - 13) * scale, s / 2 + (y - 11.75) * scale) for x, y in star], fill=255)

    icon = tile.convert("RGBA")
    if size >= 32:  # Schatten wie auf dem Mac; bei kleinen Größen nur Matsch
        shadow = stars.filter(ImageFilter.GaussianBlur(s * 0.02))
        shadow = ImageChops.offset(shadow, 0, round(s * 0.008)).point(lambda v: v * 64 // 255)
        icon.paste(Image.new("RGBA", (s, s), (0, 0, 0, 255)), (0, 0), shadow)
    icon.paste(Image.new("RGBA", (s, s), (255, 255, 255, 255)), (0, 0), stars)
    icon.putalpha(shape)
    return icon.resize((size, size), Image.Resampling.LANCZOS)


def dib(image: Image.Image) -> bytes:
    """Bild als 32-Bit-DIB für die ICO-Datei: doppelte Höhe im Kopf, Zeilen von unten nach oben,
    danach die 1-Bit-Maske (1 = durchsichtig) mit Zeilen auf 4 Byte aufgefüllt."""
    w, h = image.size
    pixels = image.tobytes("raw", "BGRA", 0, -1)
    transparent = image.getchannel("A").point(lambda a: 255 if a < 128 else 0).convert("1")
    row = (w + 31) // 32 * 4
    mask = b"".join(transparent.crop((0, y, w, y + 1)).tobytes().ljust(row, b"\0") for y in reversed(range(h)))
    header = struct.pack("<IiiHHIIiiII", 40, w, h * 2, 1, 32, 0, len(pixels) + len(mask), 0, 0, 0, 0)
    return header + pixels + mask


def write_ico(target: Path, images: list[Image.Image]) -> None:
    """ICO wie von Microsoft empfohlen: 256 px als PNG, kleinere als BMP. Pillow schreibt alles als
    PNG – damit scheitert System.Drawing.Icon (.NET Framework, pywebview unter WinForms) an 256 px."""
    frames = []
    for image in images:
        if image.width >= 256:
            buf = io.BytesIO()
            image.save(buf, "PNG", optimize=True)
            frames.append((image.width, buf.getvalue()))
        else:
            frames.append((image.width, dib(image)))
    offset = 6 + 16 * len(frames)
    entries = []
    for size, data in frames:
        dim = 0 if size >= 256 else size  # 0 steht für 256
        entries.append(struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(data), offset))
        offset += len(data)
    target.write_bytes(struct.pack("<HHH", 0, 1, len(frames)) + b"".join(entries) + b"".join(d for _, d in frames))


def main(argv: list[str]) -> int:
    target = Path(argv[0]) if argv else TARGET
    target.parent.mkdir(parents=True, exist_ok=True)
    write_ico(target, [render(size) for size in SIZES])
    print(f"Symbol: {target} ({', '.join(map(str, SIZES))} px)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
