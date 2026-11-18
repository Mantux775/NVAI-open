"""VDR-Aufzeichnungen (Voyage Data Recorder) für den Bereich „Audio“ lesen, seit 17.11.2026: Furuno VR-7000, Export
„VDR Data files“. Läuft als eigener Prozess wie audio_tools.py (python -I vdr.py <befehl> <einstellungen.json>,
Fortschritt und Ergebnis als JSON-Zeilen); der Server nutzt die reinen Python-Teile (inspect, raw_lines) direkt, die
Ton- und Bildteile laden numpy und PyAV erst beim Gebrauch.

Aufbau des Exports (technische Einzelheiten: notizen/vdr-format.md):
  block.<spur>.<id>.gz  je 15 s ein tar (gzip) mit audio<n> (Ogg Vorbis, 16 kHz, Stereo = zwei Eingänge),
                        radar<a>_<b> (Bild mit eigenem Kopf), serial (NMEA mit Empfangszeit), sporadic (Digital-,
                        Analog- und Statuswerte, nur Änderungen), alarmblock (Ereignisprotokoll des VDR),
                        attachedinfo<n> (Zusatzangaben je Bildquelle), configure (Einstellungen), *_version
  Track.txt             <id>,<spur>,<Unix-Zeit Blockbeginn>
  TrackInfo.txt         <spur>,<Beginn>,<Ende>
  VdrCheckList.dat      je Block 48 Byte Name + 16 Byte MD5 der .gz-Datei
  VdrCheckFile.dat      4 × MD5: Track.txt, TrackInfo.txt, VdrCheckList.dat, viewerConfig.dat
Ton: je Kanalpaar läuft EIN Vorbis-Kodierer durch, alle 15 s wird an einer Seitengrenze geschnitten und die drei
Kopfpakete neu vorangestellt. Lückenlos wird der Ton nur mit einem Dekoder über alle Dateien; einzeln dekodiert fehlen
je Datei die ersten 512 Proben (32 ms), über 12 Stunden rund 100 s. Weil der erste Schnitt jeder Datei zufällig liegt,
laufen die Kanäle ohne Ausgleich um bis zu einige Zehntelsekunden gegeneinander; jede Datei wird deshalb um den Median
ihrer Schnittlage gegen das Blockraster verschoben (_audio_offsets).
"""
from __future__ import annotations

import bisect
import calendar
import contextlib
import functools
import gzip
import hashlib
import io
import json
import math
import os
import re
import struct
import sys
import tarfile
import time
import zlib
from pathlib import Path
from typing import Any, Callable
import xml.etree.ElementTree as ET

BLOCK_SECONDS = 15
SR = 16000
MAX_DRIFT_S = 2.0          # so weit darf der fortlaufende Ton vom Blockraster abweichen, sonst Lücke/Überlappung
PROXY_KBPS = 24            # Opus-Vorschau 16 kHz mono (Sprache, Funk): 24 kbit/s
PROXY_OPTIONS = {"compression_level": "5"}  # 405-fach statt 138-fach Echtzeit bei Stufe 10, gleicher Klang
TICKS_PER_S = 192500.0     # Zähler in „sporadic“ (30 bit), gemessen je Block an den Sekundenpulsen
_BLOCK = re.compile(r"^block\.(\d+)\.(\d+)(\.gz)?$")
_RADAR = re.compile(r"^radar(\d+)_(\d+)$")
_LANG = "de"


class VdrError(Exception):
    """Fehler mit Text auf Deutsch und Englisch; der Server wählt die Sprache."""

    def __init__(self, de: str, en: str = "") -> None:
        super().__init__(de)
        self.de, self.en = de, en or de


def L(de: str, en: str) -> str:
    return de if _LANG == "de" else en


def emit(**kw: Any) -> None:
    # nur ASCII: mit -I gilt PYTHONIOENCODING nicht, die Ausgabe liefe sonst in der Codepage des Systems
    print(json.dumps(kw, ensure_ascii=True), flush=True)


@functools.lru_cache(maxsize=64)
def _day(y: int, m: int, d: int) -> int:
    return calendar.timegm((y, m, d, 0, 0, 0))


def _utc(t: float) -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(t))


# ------------------------------------------------------------------------------------------------ Export finden

def _scan(folder: Path, only: set[str] | None = None) -> list[dict[str, Any]]:
    found: dict[tuple[int, int], dict[str, Any]] = {}
    try:
        names = os.listdir(folder)
    except OSError:
        return []
    for name in names:
        m = _BLOCK.match(name)
        if not m or (only and name not in only):
            continue
        key = (int(m.group(1)), int(m.group(2)))
        gz = bool(m.group(3))
        path = folder / name
        if not path.is_file():
            continue
        # liegen .gz und entpacktes tar nebeneinander, gilt das Original (.gz, über die Prüfliste prüfbar)
        if key in found and found[key]["gz"] and not gz:
            continue
        found[key] = {"track": key[0], "id": key[1], "gz": gz, "path": path, "name": name}
    return sorted(found.values(), key=lambda b: (b["track"], b["id"]))


def _read_track_txt(folder: Path) -> dict[int, int | None]:
    out: dict[int, int | None] = {}
    f = folder / "Track.txt"
    if not f.is_file():
        return out
    for ln in f.read_text(encoding="latin-1", errors="replace").splitlines():
        parts = ln.strip().split(",")
        if len(parts) >= 2 and parts[0].strip().isdigit():
            tv = parts[2].strip() if len(parts) > 2 else ""
            out[int(parts[0])] = int(tv) if tv.isdigit() else None
    return out


def read_block(path: Path, gz: bool, want: Callable[[str], bool] | None = None) -> dict[str, bytes]:
    """Ein Block als {Grundname: Inhalt}; Grundname ohne die angehängte Block-ID („serial.123456789“ → „serial“)."""
    raw = path.read_bytes()
    if gz:
        raw = gzip.decompress(raw)
    out: dict[str, bytes] = {}
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as tf:
        for m in tf:
            if not m.isfile():
                continue
            base = m.name.replace("\\", "/").rsplit("/", 1)[-1]
            stem, _, tail = base.rpartition(".")
            if stem and tail.isdigit():
                base = stem
            if want is not None and not want(base):
                continue
            fh = tf.extractfile(m)
            out[base] = fh.read() if fh else b""
    return out


def _safe_block(b: dict[str, Any], want: Callable[[str], bool] | None = None) -> dict[str, bytes] | None:
    try:
        return read_block(b["path"], b["gz"], want)
    except (OSError, EOFError, tarfile.TarError, zlib.error) as e:
        b["error"] = str(e)[:200]
        return None


def _time_from_block(b: dict[str, Any]) -> int | None:
    """Blockbeginn ohne Track.txt: Kopf von „sporadic“ (Unix-Zeit des Blockendes) oder Dateizeit von „alarmblock“."""
    try:
        raw = b["path"].read_bytes()
        if b["gz"]:
            raw = gzip.decompress(raw)
        with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as tf:
            mtime = None
            for m in tf:
                base = m.name.rsplit("/", 1)[-1].rpartition(".")[0]
                if base == "sporadic":
                    fh = tf.extractfile(m)
                    d = fh.read(0x40) if fh else b""
                    if len(d) >= 0x34:
                        end = struct.unpack_from("<I", d, 0x30)[0]
                        if end > 10 ** 9:
                            return end - BLOCK_SECONDS
                if base == "alarmblock":
                    mtime = int(m.mtime)
            return mtime
    except (OSError, EOFError, tarfile.TarError, zlib.error):
        return None


def find_export(path: str | Path, track: int | None = None) -> dict[str, Any]:
    """Ordner mit Blöcken (block.<spur>.<id>.gz oder entpackte tar), auch eine Ebene tiefer, oder eine Blockdatei."""
    p = Path(str(path).strip().strip('"'))
    only = None
    if p.is_file():
        if not _BLOCK.match(p.name):
            raise VdrError(f"Keine VDR-Blockdatei: {p.name}", f"Not a VDR block file: {p.name}")
        folder, only = p.parent, {p.name}
    elif p.is_dir():
        folder = p
    else:
        raise VdrError(f"Pfad nicht gefunden: {p}", f"Path not found: {p}")
    blocks = _scan(folder, only)
    if not blocks and only is None:
        for sub in sorted(x for x in folder.iterdir() if x.is_dir()):
            b = _scan(sub)
            if b:
                folder, blocks = sub, b
                break
    if not blocks:
        raise VdrError("Keine VDR-Blöcke gefunden (block.<n>.<id>.gz oder entpackte Blöcke).",
                       "No VDR blocks found (block.<n>.<id>.gz or unpacked blocks).")
    tracks = sorted({b["track"] for b in blocks})
    if track is None:
        track = max(tracks, key=lambda k: sum(1 for b in blocks if b["track"] == k))
    blocks = [b for b in blocks if b["track"] == track]
    times = _read_track_txt(folder)
    source_of_times = "Track.txt" if times else "block"
    # Zeiten: Track.txt, fehlende aus Nachbarn (15 s je ID), sonst aus dem ersten Block hochgerechnet
    known = [(b["id"], times.get(b["id"])) for b in blocks if times.get(b["id"])]
    if not known:
        t_first = _time_from_block(blocks[0])
        if t_first is None:
            raise VdrError("Die Zeit des ersten Blocks lässt sich nicht bestimmen.",
                           "The time of the first block cannot be determined.")
        known = [(blocks[0]["id"], t_first)]
        if len(blocks) > 1:
            source_of_times = "block+15s"
    kid = [k for k, _ in known]
    for b in blocks:
        tv = times.get(b["id"])
        if tv:
            b["start"] = tv
            continue
        i = min(max(0, bisect.bisect_left(kid, b["id"]) - 1), len(known) - 1)
        ref_id, ref_t = known[i]
        b["start"] = ref_t + (b["id"] - ref_id) * BLOCK_SECONDS
        b["time_guessed"] = True
    blocks.sort(key=lambda b: (b["start"], b["id"]))
    t0 = blocks[0]["start"]
    gaps = []
    for a, b in zip(blocks, blocks[1:]):
        missing = b["id"] - a["id"] - 1
        dt = b["start"] - a["start"]
        if missing > 0 or dt != BLOCK_SECONDS:
            gaps.append({"after": a["id"], "next": b["id"], "missing_ids": max(0, missing),
                         "t": a["start"] + BLOCK_SECONDS - t0, "seconds": dt - BLOCK_SECONDS})
    listed_missing = sorted(set(times) - {b["id"] for b in blocks}) if times and only is None else []
    info = (folder / "TrackInfo.txt").read_text(encoding="latin-1", errors="replace").strip() \
        if (folder / "TrackInfo.txt").is_file() else ""
    return {"folder": folder, "track": track, "tracks": tracks, "blocks": blocks, "t0": t0,
            "end": blocks[-1]["start"] + BLOCK_SECONDS, "gaps": gaps, "listed_missing": listed_missing,
            "layout": "gz" if all(b["gz"] for b in blocks) else ("tar" if not any(b["gz"] for b in blocks) else "mixed"),
            "times": source_of_times, "trackinfo": info}


# ------------------------------------------------------------------------------------------------ Konfiguration

def parse_config(data: bytes) -> dict[str, list[dict[str, str]]]:
    """configure-XML: {Kategorie: [{Parametername: Wert, "_id": Kanal}]}."""
    root = ET.fromstring(data)
    cats: dict[str, list[dict[str, str]]] = {}
    for c in root.iter("category"):
        chans = []
        d = c.find("data")
        for ch in (d.findall("channel") if d is not None else []):
            params = {p.get("name"): p.get("value", "") for p in ch.findall("parameter") if p.get("name")}
            params["_id"] = ch.get("id") or ""
            chans.append(params)
        cats[c.get("id") or ""] = chans
    return cats


def _versions(data: bytes | None) -> dict[str, str]:
    if not data:
        return {}
    try:
        root = ET.fromstring(data)
    except ET.ParseError:
        return {}
    return {p.get("name"): p.get("value", "") for p in root.iter("parameter") if p.get("name")}


def _int(s: Any, default: int = 0) -> int:
    try:
        return int(str(s).strip())
    except (TypeError, ValueError):
        return default


def _active(ch: dict[str, str]) -> bool:
    return (ch.get("Active") or "").strip().lower() == "true"


def audio_channels(cats: dict[str, list[dict[str, str]]]) -> list[dict[str, Any]]:
    """Mono-Kanäle aus der Kategorie „Audio“: Kanal n liegt in audio<n-1>, links der erste, rechts der zweite Eingang."""
    out: list[dict[str, Any]] = []
    used: set[str] = set()
    for ch in cats.get("Audio", []):
        if not _active(ch):
            continue
        cid = _int(ch.get("_id"))
        if cid < 1:
            continue
        inputs = [x.strip() for x in (ch.get("Input Type") or "").split("/")]
        equipment = [x.strip() for x in re.split(r"\s*[,/]\s*", ch.get("Type No.(Equipment Name)") or "") if x.strip()]
        pos = [(ch.get("MIC 1/3/5/7 Position") or "").strip(), (ch.get("MIC 2/4/6/8 Position") or "").strip()]
        rate = _int(re.sub(r"\D", "", ch.get("Sampling Frequency") or ""), SR) or SR
        for side in (0, 1):
            name = inputs[side] if side < len(inputs) and inputs[side] else f"CH{cid}{'LR'[side]}"
            tid = "v_" + (re.sub(r"[^a-z0-9]+", "", name.lower()) or f"ch{cid}{side}")
            while tid in used:
                tid += "x"
            used.add(tid)
            out.append({"id": tid, "input": name, "position": pos[side], "category": (ch.get("Equipment Category") or "").strip(),
                        "equipment": equipment[side] if side < len(equipment) else "", "channel": cid,
                        "file": f"audio{cid - 1}", "side": side, "delay_ms": _int(ch.get("Delay Offset(ms)")),
                        "rate": rate, "codec": ch.get("Codec") or "", "model": ch.get("Data Name") or "",
                        "brand": ch.get("Brand") or ""})
    return out


def config_summary(cats: dict[str, list[dict[str, str]]]) -> dict[str, Any]:
    serial = [{"channel": _int(c.get("_id")), "name": c.get("Type No.(Equipment Name)") or "", "brand": c.get("Brand") or "",
               "model": c.get("Data Name") or "", "baud": c.get("Baud rate") or "", "sentences": c.get("Note") or "",
               "board": c.get("Board Name") or ""} for c in cats.get("Serial", []) if _active(c)]
    digital = [{"channel": _int(c.get("_id")), "name": c.get("Type No.(Equipment Name)") or "",
                "group": c.get("Data Name") or "", "brand": c.get("Brand") or "",
                "state1": c.get("Active Status(1)") or "1", "state0": c.get("Active Status(0)") or "0",
                "contact": c.get("Contact Type") or "", "interface": c.get("Interface (JB or SA1-8)") or "",
                "sampling": c.get("Sampling Rate") or ""} for c in cats.get("Digital", []) if _active(c)]
    analog = [{"channel": _int(c.get("_id")), "name": c.get("Type No.(Equipment Name)") or "",
               "group": c.get("Data Name") or "", "brand": c.get("Brand") or "", "data_type": c.get("Data Type") or "",
               "calibration": [c.get("Calibration Point1"), c.get("Calibration Point1 Value"),
                               c.get("Calibration Point2"), c.get("Calibration Point2 Value")],
               "calibration_active": (c.get("Calibration Active") or "") == "true",
               "unit": c.get("Engineering Value Unit") or "", "interface": c.get("Interface (JB or SA1-8)") or "",
               "sampling": c.get("Sampling Rate") or ""} for c in cats.get("Analog", []) if _active(c)]
    sensor = [{"channel": _int(c.get("_id")), "name": c.get("Type No.(Equipment Name)") or "",
               "model": c.get("Data Name") or ""} for c in cats.get("Sensor", []) if _active(c)]
    ifaces = {_int(c.get("_id")): c for c in cats.get("ImageInterface", [])}
    images = []
    for c in cats.get("ImageRecordSetting", []):
        if not _active(c):
            continue
        rid = _int(c.get("_id"))
        for k in ("No.1 Input source", "No.2 Input source", "No.3 Input source", "No.4 Input source"):
            src = _int(c.get(k))
            if src < 1:
                continue
            itf = ifaces.get(src) or {}
            label = (c.get("No") or f"Bild {rid}").strip()
            extra = " ".join(x for x in ((itf.get("No") or "").strip(), (itf.get("Type No.(Equipment Name)") or "").strip()) if x)
            images.append({"id": f"radar{rid - 1}_{src - 1}", "label": label + (f" ({extra})" if extra else ""),
                           "record": rid, "input": src, "jpeg_quality": c.get("Jpeg Quality") or ""})
    vessel_c = (cats.get("Vessel") or [{}])[0]
    vessel = {k: (vessel_c.get(v) or "").strip() for k, v in (("name", "Vessel Name"), ("imo", "Vessel IMO Number"),
                                                              ("mmsi", "Vessel MMSI Number"), ("flag", "Vessel Flag"))}
    sys_c = (cats.get("System") or [{}])[0]
    system = {k: (sys_c.get(v) or "").strip() for k, v in (("vdr_type", "VDR Type"), ("config_version", "VDR Config Version"),
                                                           ("config_date", "VDR Config Date"))}
    gps_c = (cats.get("Gps") or [{}])[0]
    gps = {"source": (gps_c.get("Date and Time Source / Ship Position Source (Serial Channel No. or 450 Sensor Channel No.)")
                      or "").strip()}
    soft_c = (cats.get("Software") or [{}])[0]
    software = {k: v for k, v in soft_c.items() if not k.startswith("_") and v and k not in ("Note",)}
    return {"audio": audio_channels(cats), "serial": serial, "digital": digital, "analog": analog, "sensor": sensor,
            "images": images, "vessel": vessel, "system": system, "gps": gps, "software": software}


def _config_bytes(ex: dict[str, Any], first: dict[str, bytes] | None) -> tuple[bytes | None, str]:
    """Eigenständige configure.<id>.xml bevorzugen, sonst die aus dem ersten Block."""
    folder = ex["folder"]
    for f in sorted(folder.glob("configure.*.xml")):
        with contextlib.suppress(OSError):
            return f.read_bytes(), f.name
    if first and first.get("configure"):
        return first["configure"], f"block {ex['blocks'][0]['id']}"
    return None, ""


# ------------------------------------------------------------------------------------------------ Bildkopf

_MONTHS = {m: i for i, m in enumerate(("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov",
                                       "Dec"), 1)}


def parse_image(d: bytes) -> dict[str, Any] | None:
    """Kopf eines Bildes (radar<a>_<b>): u32 Unix-Zeit (Aufzeichnung), u16 Höhe, u16 Breite (Bit 15 = Bildsignal),
    u32 Kopflänge ab Byte 8, u32 Datenlänge (bei „image/bmp“ die Rohgröße), 4 Byte Quelle, Mime mit Längenbyte,
    Textzeilen „VDRI/1.0“ mit „Schlüssel: Wert“, dann die Bilddaten (PNG/JPEG)."""
    if len(d) < 0x20:
        return None
    t_rec, h, w, hl, dl = struct.unpack_from("<IHHII", d, 0)
    off = 8 + hl
    ml = d[0x14]
    if off > len(d) or 0x15 + ml > off:
        return None
    mime = d[0x15:0x15 + ml].decode("ascii", "replace")
    text = d[0x15 + ml:off].split(b"\x00", 1)[0].decode("latin-1", "replace")
    head: dict[str, str] = {}
    for ln in text.split("\r\n")[1:]:
        if ":" in ln:
            k, v = ln.split(":", 1)
            head[k.strip()] = v.strip()
    capture = None
    m = re.match(r"\w{3}, (\d{1,2}) (\w{3}) (\d{4}) (\d\d):(\d\d):(\d\d)", head.get("Time") or "")
    if m and m.group(2) in _MONTHS:
        capture = _day(int(m.group(3)), _MONTHS[m.group(2)], int(m.group(1))) + int(m.group(4)) * 3600 \
            + int(m.group(5)) * 60 + int(m.group(6)) + _int(head.get("Time-ms")) / 1000
    payload = d[off:]
    kind = "png" if payload[:4] == b"\x89PNG" else "jpg" if payload[:2] == b"\xff\xd8" else \
        "bmp" if payload[:2] == b"BM" else "zlib" if payload[:1] == b"\x78" else "bin"
    return {"t": t_rec, "h": h, "w": w & 0x7FFF, "signal": bool(w & 0x8000), "mime": mime, "head": head,
            "capture": capture, "source_code": d[0x10:0x14].hex(), "offset": off, "raw_size": dl, "kind": kind,
            "no_signal": not (w & 0x8000) and not head.get("Source")}


# ------------------------------------------------------------------------------------------------ inspect

def inspect(path: str | Path, track: int | None = None) -> dict[str, Any]:
    """Schneller Überblick (< 5 s): Zeiten, Lücken, Kanäle, Geräte, Bildquellen, Versionen, Größe."""
    t_start = time.time()
    ex = find_export(path, track)
    first = None
    for b in ex["blocks"][:3]:
        first = _safe_block(b)
        if first is not None:
            break
    cfg, cfg_from = _config_bytes(ex, first)
    cats = parse_config(cfg) if cfg else {}
    summ = config_summary(cats)
    versions = {"vdr": _versions((first or {}).get("vdr_version")), "vlc1": _versions((first or {}).get("vlc1_version")),
                "vlc2": _versions((first or {}).get("vlc2_version"))}
    # Bildquellen: aus der Konfiguration, Mime und Kopfzeilen aus dem ersten Block mit Bildern
    img_by_id = {x["id"]: dict(x) for x in summ["images"]}
    for b in ex["blocks"][:12]:
        blk = first if b is ex["blocks"][0] else _safe_block(b, lambda n: n.startswith("radar"))
        found = {k: v for k, v in (blk or {}).items() if _RADAR.match(k)}
        if not found:
            continue
        for k, v in sorted(found.items()):
            hd = parse_image(v)
            x = img_by_id.setdefault(k, {"id": k, "label": k})
            if hd:
                x.update({"mime": hd["mime"], "stored_as": hd["kind"], "width": hd["w"], "height": hd["h"],
                          "header_source": hd["head"].get("Source", ""), "location": hd["head"].get("Location", "")})
        break
    audio_files = sorted(k for k in (first or {}) if re.match(r"^audio\d+$", k))
    size = sum(b["path"].stat().st_size for b in ex["blocks"])
    files = {}
    for n in ("Track.txt", "TrackInfo.txt", "VdrCheckList.dat", "VdrCheckFile.dat", "viewerConfig.dat"):
        f = ex["folder"] / n
        if f.is_file():
            files[n] = f.stat().st_size
            size += f.stat().st_size
    for f in ex["folder"].glob("configure.*.xml"):
        files[f.name] = f.stat().st_size
        size += f.stat().st_size
    missing_audio = [c["file"] for c in summ["audio"] if first is not None and c["file"] not in first]
    return {
        "product": summ["system"].get("vdr_type") or "VDR", "format": "Furuno VR-7000 (VDR Data files)",
        "folder": str(ex["folder"]), "layout": ex["layout"], "track": ex["track"], "tracks": ex["tracks"],
        "blocks": len(ex["blocks"]), "first_id": ex["blocks"][0]["id"], "last_id": ex["blocks"][-1]["id"],
        "start_utc": ex["t0"], "end_utc": ex["end"], "start": _utc(ex["t0"]), "end": _utc(ex["end"]),
        "duration": ex["end"] - ex["t0"], "block_seconds": BLOCK_SECONDS, "times": ex["times"],
        "gaps": ex["gaps"][:200], "gap_count": len(ex["gaps"]), "listed_missing": ex["listed_missing"][:200],
        "trackinfo": ex["trackinfo"], "config_from": cfg_from, "versions": versions, "software": summ["software"],
        "system": summ["system"], "vessel": summ["vessel"], "gps": summ["gps"],
        "audio": summ["audio"], "audio_files": audio_files, "missing_audio_files": missing_audio,
        "serial": summ["serial"], "digital": summ["digital"], "analog": summ["analog"], "sensor": summ["sensor"],
        "images": sorted(img_by_id.values(), key=lambda x: x["id"]),
        "size_bytes": size, "files": files, "seconds": round(time.time() - t_start, 2)}


# ------------------------------------------------------------------------------------------------ verify

def _md5(path: Path) -> str:
    h = hashlib.md5()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 22), b""):
            h.update(chunk)
    return h.hexdigest()


def verify(path: str | Path, progress: Callable[[float, str], None] | None = None) -> dict[str, Any]:
    """Prüfsummen: jede Datei aus VdrCheckList.dat (MD5 der .gz-Datei) und VdrCheckFile.dat (4 × MD5 der Begleitdateien)."""
    from concurrent.futures import ThreadPoolExecutor
    t_start = time.time()
    ex = find_export(path)
    folder = ex["folder"]
    out: dict[str, Any] = {"folder": str(folder), "checklist": None, "checkfile": None}
    cl = folder / "VdrCheckList.dat"
    if cl.is_file():
        raw = cl.read_bytes()
        entries = []
        for i in range(0, len(raw) - 63, 64):
            name = raw[i:i + 48].split(b"\x00", 1)[0].decode("latin-1", "replace")
            entries.append((name, raw[i + 48:i + 64].hex()))
        algo = None
        checks: list[tuple[str, Path | None, str]] = []
        for name, digest in entries:
            gz, plain = folder / (name + ".gz"), folder / name
            checks.append((name, gz if gz.is_file() else (plain if plain.is_file() else None), digest))
        # Verfahren am ersten vorhandenen Eintrag bestimmen
        for name, f, digest in checks:
            if f is None:
                continue
            data = f.read_bytes()
            for a in ("md5", "sha1", "sha256"):
                if hashlib.new(a, data).hexdigest()[:32] == digest:
                    algo = a
                    break
            if algo is None and f.suffix != ".gz":
                algo = "md5"   # nur entpackt vorhanden: die Liste gilt der .gz-Datei, prüfen geht dann nicht
            break
        algo = algo or "unbekannt"
        ok: list[str] = []
        bad: list[str] = []
        missing: list[str] = []
        unpacked: list[str] = []
        done = [0]

        def one(item: tuple[str, Path | None, str]) -> tuple[str, str]:
            name, f, digest = item
            if f is None:
                return name, "missing"
            if f.suffix != ".gz":
                return name, "unpacked"
            h = hashlib.new(algo if algo in ("md5", "sha1", "sha256") else "md5")
            with f.open("rb") as fh:
                for chunk in iter(lambda: fh.read(1 << 22), b""):
                    h.update(chunk)
            return name, "ok" if h.hexdigest()[:32] == digest else "bad"

        with ThreadPoolExecutor(max_workers=min(8, (os.cpu_count() or 4))) as pool:
            for name, st in pool.map(one, checks):
                {"ok": ok, "bad": bad, "missing": missing, "unpacked": unpacked}[st].append(name)
                done[0] += 1
                if progress and done[0] % 50 == 0:
                    progress(done[0] / max(1, len(checks)), "Prüfsummen")
        listed = {n for n, _ in entries}
        unlisted = sorted(b["name"] for b in _scan(folder) if b["name"].removesuffix(".gz") not in listed)
        out["checklist"] = {"algorithm": algo, "covers": ".gz", "listed": len(entries), "ok": len(ok), "bad": bad[:500],
                            "bad_count": len(bad), "missing": missing[:500], "missing_count": len(missing),
                            "unpacked": len(unpacked), "unlisted": unlisted[:200], "unlisted_count": len(unlisted)}
    cf = folder / "VdrCheckFile.dat"
    if cf.is_file():
        raw = cf.read_bytes()
        expected = ["Track.txt", "TrackInfo.txt", "VdrCheckList.dat", "viewerConfig.dat"]
        cands = {n: _md5(folder / n) for n in expected if (folder / n).is_file()}
        for f in folder.glob("configure.*.xml"):
            cands[f.name] = _md5(f)
        parts = []
        for k in range(len(raw) // 16):
            dg = raw[16 * k:16 * k + 16].hex()
            exp = expected[k] if k < len(expected) else None
            match = next((n for n, h in cands.items() if h == dg), None)
            parts.append({"expected": exp, "matches": match, "ok": match is not None and (exp is None or match == exp)})
        out["checkfile"] = {"layout": f"{len(raw) // 16} × MD5", "parts": parts, "ok": all(p["ok"] for p in parts),
                            "not_covered": sorted(f.name for f in folder.glob("configure.*.xml"))}
    if out["checklist"] is None and out["checkfile"] is None:
        out["ok"] = None   # nichts zu prüfen (etwa ein einzelner entpackter Block)
        out["note"] = "Keine VdrCheckList.dat/VdrCheckFile.dat im Ordner."
    else:
        cl = out["checklist"]
        cl_ok = cl is None or (cl["bad_count"] == 0 and cl["missing_count"] == 0 and cl["unpacked"] == 0)
        out["ok"] = bool(cl_ok and (out["checkfile"] is None or out["checkfile"]["ok"]))
    out["seconds"] = round(time.time() - t_start, 2)
    return out


# ------------------------------------------------------------------------------------------------ NMEA

def _nmea_ok(s: str) -> bool | None:
    """Prüfsumme; None, wenn keine angehängt ist."""
    star = s.rfind("*")
    if star < 0 or len(s) < star + 3:
        return None
    x = 0
    for ch in s[1:star]:
        x ^= ord(ch)
    try:
        return x == int(s[star + 1:star + 3], 16)
    except ValueError:
        return False


def _fields(s: str) -> list[str]:
    star = s.rfind("*")
    return (s[1:star] if star > 0 else s[1:]).split(",")


def _f(x: str) -> float | None:
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def _dm(v: str, hemi: str) -> float | None:
    """NMEA Grad/Minuten („5330.5000“, N = 53,508333°) → Dezimalgrad."""
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    deg = int(f // 100)
    val = deg + (f - deg * 100) / 60
    return -val if hemi in ("S", "W") else val


def parse_serial_line(ln: str) -> tuple[float, int | None, str] | None:
    """„<präfix>:<c9,1000XX,1>:…|TT/MM/JJJJ hh:mm:ss.mmm $…“ → (Unix-Zeit, serieller Kanal, Satz)."""
    bar = ln.find("|")
    if bar < 0 or len(ln) < bar + 25:
        return None
    head = ln[:bar]
    lt = head.find("<")
    gt = head.find(">", lt)
    chan = None
    if lt >= 0 and gt > lt:
        tag = head[lt + 1:gt].split(",")
        if len(tag) > 1:
            try:
                chan = int(tag[1], 16) - 0x100000
            except ValueError:
                chan = None
    ts = ln[bar + 1:bar + 24]
    try:
        t = _day(int(ts[6:10]), int(ts[3:5]), int(ts[0:2])) + int(ts[11:13]) * 3600 + int(ts[14:16]) * 60 \
            + int(ts[17:19]) + int(ts[20:23]) / 1000
    except ValueError:
        return None
    return t, chan, ln[bar + 25:].rstrip("\r\n")


TELEGRAPH = {"00": (0, "Stopp", "Stop"), "01": (1, "Voraus äußerst langsam", "Ahead dead slow"),
             "02": (2, "Voraus langsam", "Ahead slow"), "03": (3, "Voraus halbe", "Ahead half"),
             "04": (4, "Voraus voll", "Ahead full"), "05": (5, "Voraus volle Seefahrt", "Ahead navigation full"),
             "11": (-1, "Zurück äußerst langsam", "Astern dead slow"), "12": (-2, "Zurück langsam", "Astern slow"),
             "13": (-3, "Zurück halbe", "Astern half"), "14": (-4, "Zurück voll", "Astern full"),
             "15": (-5, "Zurück äußerste Kraft", "Astern crash/emergency full")}
SUB_TELEGRAPH = {"20": ("Maschine klar (S/B)", "Stand-by engine (S/B)"), "30": ("Seefahrt (F/A)", "Full away (F/A)"),
                 "40": ("Maschine fertig (F/E)", "Finished with engine (F/E)")}
LOCATION = {"B": ("Brücke", "bridge"), "P": ("Nock Backbord", "port wing"), "S": ("Nock Steuerbord", "starboard wing"),
            "C": ("Maschinenkontrollraum", "engine control room"), "E": ("Maschine vor Ort", "engine side"),
            "W": ("Nock", "wing")}
STEERING = {"M": ("Handsteuerung", "manual steering"), "S": ("Kursregelung (eigenständig)", "stand-alone heading control"),
            "H": ("Kursregelung", "heading control"), "T": ("Bahnregelung", "track control"),
            "R": ("Ruderregelung", "rudder control")}
NAV_STATUS = ["under way using engine", "at anchor", "not under command", "restricted manoeuvrability",
              "constrained by draught", "moored", "aground", "engaged in fishing", "under way sailing",
              "reserved (HSC)", "reserved (WIG)", "power-driven towing astern", "power-driven pushing ahead",
              "reserved", "AIS-SART/MOB/EPIRB active", "undefined"]

# Reihen: Schlüssel → (Deutsch, Englisch, Einheit, Nachkommastellen, Halten bis zum nächsten Wert)
SERIES = {
    "lat": ("Breite", "Latitude", "°", 6, False), "lon": ("Länge", "Longitude", "°", 6, False),
    "sog": ("Geschwindigkeit über Grund", "Speed over ground", "kn", 2, False),
    "cog": ("Kurs über Grund", "Course over ground", "°", 1, False),
    "hdg": ("Steuerkurs (Kreisel)", "Heading (gyro)", "°", 1, False),
    "rot": ("Drehrate", "Rate of turn", "°/min", 1, False),
    "stw": ("Geschwindigkeit durchs Wasser", "Speed through water", "kn", 2, False),
    "depth": ("Wassertiefe unter Schwinger", "Depth below transducer", "m", 1, False),
    "rudder": ("Ruderlage", "Rudder angle", "°", 1, False),
    "rudder_order": ("Ruderbefehl (Autopilot)", "Rudder order (autopilot)", "°", 1, False),
    "heading_order": ("Sollkurs (Autopilot)", "Heading order (autopilot)", "°", 1, False),
    "rpm": ("Drehzahl", "Engine speed", "1/min", 1, False),
    "pitch": ("Propellersteigung", "Propeller pitch", "%", 1, False),
    "rpm_order": ("Drehzahlvorgabe", "RPM order", "1/min", 1, False),
    "pitch_order": ("Steigungsvorgabe", "Pitch order", "%", 1, False),
    "wind_rel_dir": ("Wind relativ, Richtung", "Relative wind direction", "°", 0, False),
    "wind_rel_speed": ("Wind relativ, Stärke", "Relative wind speed", "kn", 1, False),
    "wind_true_dir": ("Wind wahr, Richtung", "True wind direction", "°", 0, False),
    "wind_true_speed": ("Wind wahr, Stärke", "True wind speed", "kn", 1, False),
    "telegraph_order": ("Maschinentelegraf Befehl", "Engine telegraph order", "Stufe/step", 0, True),
    "telegraph_answer": ("Maschinentelegraf Antwort", "Engine telegraph answer", "Stufe/step", 0, True),
}
_WIND = {"N": 1.0, "K": 1 / 1.852, "M": 1.9438445, "S": 0.8689762}


class Events:
    """Ereignisliste; Zustände mit Anfang und Ende über einen Schlüssel."""

    def __init__(self) -> None:
        self.items: list[dict[str, Any]] = []
        self.open: dict[Any, dict[str, Any]] = {}

    def point(self, t: float, kind: str, label: str, detail: str = "", source: str = "") -> dict[str, Any]:
        ev = {"t": round(t, 3), "end": None, "kind": kind, "label": label, "detail": detail, "source": source}
        self.items.append(ev)
        return ev

    def start(self, key: Any, t: float, kind: str, label: str, detail: str = "", source: str = "") -> dict[str, Any]:
        self.stop(key, t)
        ev = self.point(t, kind, label, detail, source)
        self.open[key] = ev
        return ev

    def stop(self, key: Any, t: float) -> dict[str, Any] | None:
        ev = self.open.pop(key, None)
        if ev is not None:
            ev["end"] = round(max(t, ev["t"]), 3)
        return ev

    def finish(self, t_end: float) -> None:
        for key in list(self.open):
            ev = self.stop(key, t_end)
            if ev is not None:
                ev["open"] = True


# ------------------------------------------------------------------------------------------------ AIS

_SIX = "@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_ !\"#$%&'()*+,-./0123456789:;<=>?"


class _Bits:
    def __init__(self, payload: str, fill: int) -> None:
        v = 0
        n = 0
        for ch in payload:
            c = ord(ch) - 48
            if c > 40:
                c -= 8
            if c < 0 or c > 63:
                raise ValueError("payload")
            v = (v << 6) | c
            n += 6
        n -= fill
        self.v = v >> fill
        self.n = n

    def u(self, start: int, length: int) -> int | None:
        if start + length > self.n:
            return None
        return (self.v >> (self.n - start - length)) & ((1 << length) - 1)

    def s(self, start: int, length: int) -> int | None:
        x = self.u(start, length)
        if x is None:
            return None
        return x - (1 << length) if x & (1 << (length - 1)) else x

    def text(self, start: int, length: int) -> str:
        out = []
        for k in range(start, start + length, 6):
            c = self.u(k, 6)
            if c is None:
                break
            out.append(_SIX[c])
        return "".join(out).split("@", 1)[0].strip()


def ship_type_text(code: int | None) -> str:
    if code is None or code == 0:
        return ""
    groups = [(20, 29, "WIG"), (30, 30, "fishing"), (31, 32, "towing"), (33, 33, "dredging"), (34, 34, "diving"),
              (35, 35, "military"), (36, 36, "sailing"), (37, 37, "pleasure craft"), (40, 49, "high-speed craft"),
              (50, 50, "pilot"), (51, 51, "search and rescue"), (52, 52, "tug"), (53, 53, "port tender"),
              (54, 54, "anti-pollution"), (55, 55, "law enforcement"), (58, 58, "medical"), (60, 69, "passenger"),
              (70, 79, "cargo"), (80, 89, "tanker"), (90, 99, "other")]
    return next((n for a, b, n in groups if a <= code <= b), "")


class Ais:
    """VDM (andere Schiffe) und VDO (eigenes Schiff), Typen 1/2/3/5/18/19/24; Spur höchstens alle 10 s ein Punkt."""

    def __init__(self, own_mmsi: str) -> None:
        self.parts: dict[tuple[Any, ...], list[str | None]] = {}
        self.targets: dict[str, dict[str, Any]] = {}
        self.own: dict[str, Any] = {"mmsi": own_mmsi, "track": []}
        self.counts: dict[str, int] = {}
        self.errors = 0
        self.nav_status: int | None = None

    def feed(self, t: float, chan: Any, f: list[str], own: bool, ev: Events) -> None:
        # !AIVDM,anzahl,nummer,folge-id,kanal,nutzdaten,füllbits
        if len(f) < 7:
            self.errors += 1
            return
        try:
            total, num = int(f[1]), int(f[2])
            fill = int(f[6] or 0)
        except ValueError:
            self.errors += 1
            return
        if total == 1:
            payload = f[5]
        else:
            key = (chan, own, f[3], f[4], total)
            lst = self.parts.get(key)
            if lst is None or num == 1:
                lst = [None] * total
                self.parts[key] = lst
            if num < 1 or num > total:
                self.errors += 1
                return
            lst[num - 1] = f[5]
            if any(x is None for x in lst):
                return
            payload = "".join(x for x in lst if x)
            del self.parts[key]
        try:
            bits = _Bits(payload, fill)
        except ValueError:
            self.errors += 1
            return
        mt = bits.u(0, 6)
        mmsi = bits.u(8, 30)
        if mt is None or mmsi is None:
            self.errors += 1
            return
        self.counts[str(mt)] = self.counts.get(str(mt), 0) + 1
        mm = f"{mmsi:09d}"
        tgt = self.own if own else self.targets.setdefault(mm, {"name": "", "type": None, "type_text": "", "class": "",
                                                               "first": round(t, 1), "last": round(t, 1), "n": 0,
                                                               "track": []})
        if own and not self.own.get("mmsi"):
            self.own["mmsi"] = mm
        tgt["last"] = round(t, 1)
        tgt["n"] = tgt.get("n", 0) + 1
        pos = None
        if mt in (1, 2, 3):
            tgt["class"] = "A"
            lon, lat = bits.s(61, 28), bits.s(89, 27)
            sog, cog, hdg = bits.u(50, 10), bits.u(116, 12), bits.u(128, 9)
            status = bits.u(38, 4)
            pos = (lat, lon, sog, cog)
            if hdg is not None and hdg != 511:
                tgt["heading"] = hdg
            if status is not None:
                tgt["status"] = NAV_STATUS[status]
            if own and status is not None and status != self.nav_status:
                prev = self.nav_status
                ev.point(t, "ais", L("Eigenes Schiff: Navigationsstatus", "Own ship: navigational status") +
                         L(f" „{NAV_STATUS[status]}“", f' "{NAV_STATUS[status]}"'),
                         (L("vorher", "was") + L(f" „{NAV_STATUS[prev]}“", f' "{NAV_STATUS[prev]}"'))
                         if prev is not None else L("Stand bei Aufnahmebeginn", "state at start of recording"), "AIS")
                self.nav_status = status
        elif mt in (18, 19):
            tgt["class"] = "B"
            lon, lat = bits.s(57, 28), bits.s(85, 27)
            pos = (lat, lon, bits.u(46, 10), bits.u(112, 12))
            if mt == 19:
                tgt["name"] = bits.text(143, 120) or tgt.get("name", "")
                tgt["type"] = bits.u(263, 8)
                tgt["type_text"] = ship_type_text(tgt["type"])
        elif mt == 5:
            tgt["class"] = "A"
            tgt["imo"] = bits.u(40, 30)
            tgt["callsign"] = bits.text(70, 42)
            tgt["name"] = bits.text(112, 120) or tgt.get("name", "")
            tgt["type"] = bits.u(232, 8)
            tgt["type_text"] = ship_type_text(tgt["type"])
            a, b2, c, d = bits.u(240, 9), bits.u(249, 9), bits.u(258, 6), bits.u(264, 6)
            if None not in (a, b2, c, d):
                tgt["length"] = a + b2
                tgt["beam"] = c + d
            dr = bits.u(294, 8)
            if dr:
                tgt["draught"] = dr / 10
            tgt["destination"] = bits.text(302, 120)
        elif mt == 27:
            # Langstrecken-Meldung: Lage in 1/10 Minute, Geschwindigkeit in kn, Kurs in Grad
            lon, lat = bits.s(44, 18), bits.s(62, 17)
            sog, cog = bits.u(79, 6), bits.u(85, 9)
            if lon is not None and lat is not None:
                pos = (lat * 1000, lon * 1000, None if sog is None or sog == 63 else sog * 10,
                       None if cog is None or cog >= 360 else cog * 10)
        elif mt == 24:
            part = bits.u(38, 2)
            if part == 0:
                tgt["name"] = bits.text(40, 120) or tgt.get("name", "")
            elif part == 1:
                tgt["type"] = bits.u(40, 8)
                tgt["type_text"] = ship_type_text(tgt["type"])
                tgt["callsign"] = bits.text(90, 42)
        if pos is not None:
            lat, lon, sog, cog = pos
            if lat is None or lon is None or abs(lat) > 90 * 600000 or abs(lon) > 180 * 600000:
                return
            tr = tgt["track"]
            if tr and t - tr[-1][0] < 10:
                return
            tr.append([round(t, 1), round(lat / 600000, 6), round(lon / 600000, 6),
                       None if sog is None or sog == 1023 else sog / 10, None if cog is None or cog >= 3600 else cog / 10])


# ------------------------------------------------------------------------------------------------ sporadic

def parse_sporadic(d: bytes) -> dict[str, Any] | None:
    """Digital-, Analog- und Statuswerte: Kopf (96 Byte), Kanaltabelle (Typ, Unterart, Kanal, 16) × n, zwei
    Versatztabellen (erster und letzter Eintrag je Kanal), Einträge als verkettete Liste:
    u32 nächster Eintrag (Bit 30: Wert folgt), u16 Kanalindex, u16 Merker, u32 Sekunde (VDR-intern), u32 Zähler (30 bit),
    [u32 Wert]. Neue Einträge gibt es nur bei Änderung; der erste Eintrag trägt den Stand bei Blockbeginn."""
    if len(d) < 0x60:
        return None
    h = struct.unpack_from("<24I", d, 0)
    n = h[1]
    if n <= 0 or 0x60 + 16 * n > len(d):
        return None
    tab = [struct.unpack_from("<HHHH", d, 0x60 + 8 * i) for i in range(n)]
    first = struct.unpack_from(f"<{n}I", d, 0x60 + 8 * n)
    chains: dict[tuple[int, int, int], list[tuple[int, int, int, int | None]]] = {}
    limit = len(d) // 16 + 1
    for i, (typ, sub, ch, _) in enumerate(tab):
        off = first[i]
        recs: list[tuple[int, int, int, int | None]] = []
        guard = 0
        while off and off + 16 <= len(d) and guard < limit:
            nxt, idx, fl, sec, cnt = struct.unpack_from("<IHHII", d, off)
            if idx != i:
                break
            val = struct.unpack_from("<I", d, off + 16)[0] if nxt & 0x40000000 and off + 20 <= len(d) else None
            recs.append((fl, sec, cnt & 0x3FFFFFFF, val))
            off = nxt & 0x3FFFFFFF
            guard += 1
        chains[(typ, sub, ch)] = recs
    return {"hdr": h, "chains": chains, "sec_start": h[2], "sec_end": h[8], "tick_end": h[9] & 0x3FFFFFFF,
            "utc_end": h[12]}


class SporadicClock:
    """Zeit der Einträge: über den Zähler (30 bit) gegen den letzten Sekundenpuls des Blocks (= Blockende); Einträge,
    deren VDR-Sekunde vor dem Blockbeginn liegt, sind der Stand bei Blockbeginn."""

    def __init__(self) -> None:
        self.prev_tick: int | None = None

    def mapper(self, sp: dict[str, Any], t_block: float) -> Callable[[int, int], float]:
        hb = sp["chains"].get((112, 10, 1)) or sp["chains"].get((112, 12, 1)) or []
        rate = TICKS_PER_S
        if len(hb) >= 4:
            span = (hb[-1][2] - hb[1][2]) % (1 << 30)
            if span:
                r = span / (len(hb) - 2)
                if 150000 < r < 250000:
                    rate = r
        frozen = self.prev_tick is not None and sp["tick_end"] == self.prev_tick
        self.prev_tick = sp["tick_end"]
        t_end = t_block + BLOCK_SECONDS
        sec_start = sp["sec_start"]

        def at(sec: int, tick: int) -> float:
            if frozen or (sec_start - sec) > 2 and (sec_start - sec) < (1 << 31):
                return t_block
            dt = ((sp["tick_end"] - tick) % (1 << 30)) / rate
            return min(t_end, max(t_block, t_end - dt))
        return at


# ------------------------------------------------------------------------------------------------ Datenlauf

def _worker_progress(key: str, frac: float) -> None:
    q = _W.get("queue")
    if q is not None:
        try:
            q.put_nowait((key, float(frac)))
        except Exception:  # noqa: BLE001 - Fortschritt ist Nebensache
            pass
    if not _parent_alive():
        os._exit(3)


def task_data(job: dict[str, Any]) -> dict[str, Any]:
    """Ein Durchlauf über alle Blöcke: NMEA (Reihen, Alarme, Telegraf, Autopilot, AIS), sporadic (Digital/Analog),
    alarmblock (Ereignisprotokoll des VDR), attachedinfo (Karteninfo), Wechsel der Konfiguration."""
    global _LANG
    _LANG = job.get("lang") or "de"
    blocks = job["blocks"]
    t0 = job["t0"]
    n_sec = int(math.ceil(job["duration"])) + 1
    out_dir = Path(job["out_dir"])
    serial_names = {d["channel"]: d["name"] for d in job["summary"]["serial"]}
    digital = {d["channel"]: d for d in job["summary"]["digital"]}
    analog = {d["channel"]: d for d in job["summary"]["analog"]}
    series: dict[str, list[Any]] = {}
    hold_series: dict[str, list[Any]] = {}
    ev = Events()
    ais = Ais(job["summary"]["vessel"].get("mmsi") or "")
    counts: dict[str, int] = {}
    bad_checksum: dict[str, int] = {}
    clock: list[float] = []
    ecdis: dict[str, list[Any]] = {}
    cfg_crc = None
    cfg_changes = []
    ver_seen: dict[str, str] = {}
    alarm_state: dict[Any, dict[str, Any]] = {}
    etl_state: dict[Any, tuple[str, str, str]] = {}
    htd_state: dict[str, Any] = {}
    hbt_state: dict[Any, str] = {}
    dig_state: dict[int, tuple[int | None, bool]] = {}
    dig_points: dict[int, list[tuple[float, int | None]]] = {}
    ana_valid: dict[int, bool] = {}
    spclock = SporadicClock()
    invalid_since: float | None = None
    sp_stats = {"records": 0, "blocks": 0, "frozen_blocks": 0}
    syslog_open: dict[Any, dict[str, Any]] = {}
    alert_open: dict[str, dict[str, Any]] = {}
    lines_total = 0
    unreadable = []

    def put(key: str, t_rel: float, v: float | None, nd: int) -> None:
        if v is None:
            return
        i = int(t_rel)
        if 0 <= i < n_sec:
            arr = series.get(key)
            if arr is None:
                arr = series[key] = [None] * n_sec
            arr[i] = round(v, nd) if nd else int(round(v))

    def src_name(chan: Any) -> str:
        nm = serial_names.get(chan)
        return f"{L('Seriell', 'Serial')} {chan}" + (f" ({nm})" if nm else "")

    for k, b in enumerate(blocks):
        blk = _safe_block(b, lambda n: n in ("serial", "sporadic", "alarmblock", "configure", "vdr_version",
                                             "vlc1_version", "vlc2_version") or n.startswith("attachedinfo"))
        tb = b["start"] - t0
        if blk is None:
            unreadable.append(b["id"])
            continue
        # Konfiguration und Versionen je Block vergleichen (gleich in jedem Block erwartet)
        if blk.get("configure"):
            crc = zlib.crc32(blk["configure"])
            if cfg_crc is not None and crc != cfg_crc:
                cfg_changes.append({"t": tb, "block": b["id"]})
                ev.point(tb, "system", L("Konfiguration des VDR geändert", "VDR configuration changed"), "", "VDR")
            cfg_crc = crc
        for vn in ("vdr_version", "vlc1_version", "vlc2_version"):
            if blk.get(vn):
                h = hashlib.md5(blk[vn]).hexdigest()
                if vn in ver_seen and ver_seen[vn] != h:
                    ev.point(tb, "system", L(f"Version geändert ({vn})", f"Version changed ({vn})"), "", "VDR")
                ver_seen[vn] = h
        # ---- serielle Daten
        text = blk.get("serial", b"").decode("latin-1", "replace")
        for ln in text.split("\n"):
            if not ln.strip():
                continue
            pr = parse_serial_line(ln)
            if pr is None:
                counts["unparsed"] = counts.get("unparsed", 0) + 1
                continue
            lines_total += 1
            t_abs, chan, s = pr
            t = t_abs - t0
            if len(s) < 6 or s[0] not in "$!":
                continue
            ok = _nmea_ok(s)
            prop = s[1] == "P"
            fmt = s[1:5] if prop else s[3:6]
            talker = "P" if prop else s[1:3]
            ckey = f"{chan}:{talker}{fmt}" if not prop else f"{chan}:{fmt}"
            counts[ckey] = counts.get(ckey, 0) + 1
            if ok is False:
                bad_checksum[ckey] = bad_checksum.get(ckey, 0) + 1
                continue
            f = _fields(s)
            src = src_name(chan)
            try:
                if fmt == "RMC" and len(f) > 8 and f[2] == "A":
                    put("lat", t, _dm(f[3], f[4]), 6)
                    put("lon", t, _dm(f[5], f[6]), 6)
                    put("sog", t, _f(f[7]), 2)
                    put("cog", t, _f(f[8]), 1)
                elif fmt == "GGA" and len(f) > 6 and f[6] not in ("", "0"):
                    put("lat", t, _dm(f[2], f[3]), 6)
                    put("lon", t, _dm(f[4], f[5]), 6)
                elif fmt == "GLL" and len(f) > 6 and f[6] == "A":
                    put("lat", t, _dm(f[1], f[2]), 6)
                    put("lon", t, _dm(f[3], f[4]), 6)
                elif fmt == "VTG" and len(f) > 7 and (len(f) < 10 or f[9] != "N"):
                    put("cog", t, _f(f[1]), 1)
                    put("sog", t, _f(f[5]), 2)
                elif fmt in ("HDT", "THS") and len(f) > 1:
                    if fmt == "HDT" or (len(f) > 2 and f[2] == "A"):
                        put("hdg", t, _f(f[1]), 1)
                elif fmt == "ROT" and len(f) > 2 and f[2] == "A":
                    put("rot", t, _f(f[1]), 1)
                elif fmt == "VHW" and len(f) > 5:
                    put("stw", t, _f(f[5]), 2)
                elif fmt == "VBW" and len(f) > 3 and f[3] == "A" and "stw" not in series:
                    put("stw", t, _f(f[1]), 2)
                elif fmt == "DPT" and len(f) > 1:
                    put("depth", t, _f(f[1]), 1)
                elif fmt == "RSA" and len(f) > 2 and f[2] == "A":
                    put("rudder", t, _f(f[1]), 1)
                elif fmt in ("HTD", "HTC") and len(f) > 10:
                    ang = _f(f[2])
                    if ang is not None:
                        put("rudder_order", t, -ang if f[3] == "L" else ang, 1)
                    put("heading_order", t, _f(f[10]), 1)
                    _autopilot(t, f, htd_state, ev, src)
                elif fmt == "RPM" and len(f) > 5 and f[5] == "A" and f[2] in ("0", "1", ""):
                    put("rpm", t, _f(f[3]), 1)
                    put("pitch", t, _f(f[4]), 1)
                elif fmt == "PRC" and len(f) > 6:
                    if f[4] not in ("V", ""):
                        put("rpm_order", t, _f(f[3]), 1)
                    if f[6] not in ("V", ""):
                        put("pitch_order", t, _f(f[5]), 1)
                elif fmt == "MWV" and len(f) > 5 and f[5] == "A":
                    ws = _f(f[3])
                    ws = ws * _WIND.get(f[4], 1.0) if ws is not None else None
                    if f[2] == "R":
                        put("wind_rel_dir", t, _f(f[1]), 0)
                        put("wind_rel_speed", t, ws, 1)
                    elif f[2] == "T":
                        put("wind_true_dir", t, _f(f[1]), 0)
                        put("wind_true_speed", t, ws, 1)
                elif fmt == "ETL" and len(f) > 6:
                    _telegraph(t, f, etl_state, ev, src, put)
                elif fmt == "ZDA" and len(f) > 4:
                    hhmmss = f[1]
                    if len(hhmmss) >= 6 and f[2] and f[3] and f[4]:
                        g = _day(int(f[4]), int(f[3]), int(f[2])) + int(hhmmss[0:2]) * 3600 + int(hhmmss[2:4]) * 60 \
                            + float(hhmmss[4:])
                        clock.append(g - t_abs)
                elif fmt == "ALR" and len(f) > 4:
                    _alarm_alr(t, chan, talker, f, alarm_state, ev, src)
                elif fmt == "ALA" and len(f) > 7:
                    _alarm_ala(t, chan, f, alarm_state, ev, src)
                elif fmt == "ALF" and len(f) > 13:
                    _alert_alf(t, chan, f, alarm_state, ev, src)
                elif fmt == "ACN" and len(f) > 5:
                    ev.point(t, "alert", L("Befehl an Alarm", "Alert command") + f" {f[2]} {f[3]}",
                             L("Befehl", "command") + f" {f[5]}, " + L("Zustand", "state") + f" {f[6] if len(f) > 6 else ''}",
                             src)
                elif fmt == "ACK" and len(f) > 1:
                    ev.point(t, "alarm", L("Alarm quittiert", "Alarm acknowledged") + f" {f[1]}", "", src)
                elif fmt in ("TXT", "EVE") and len(f) > 3:
                    # TXT: anzahl, nummer, kennung, text; EVE: zeit, kennung, text
                    msg = f[4] if fmt == "TXT" and len(f) > 4 else f[3] if fmt == "EVE" else f[-1]
                    ev.point(t, "text", f"{talker}{fmt}: {msg}".strip(), ",".join(f[1:])[:300], src)
                elif fmt == "HBT" and len(f) > 2:
                    hk = (chan, talker)
                    if hbt_state.get(hk, "A") != f[2]:
                        ev.point(t, "system", L("Lebenszeichen geändert", "Heartbeat status changed") + f": {talker} {f[2]}",
                                 "", src)
                    hbt_state[hk] = f[2]
                elif fmt in ("VDM", "VDO"):
                    ais.feed(t, chan, f, fmt == "VDO", ev)
            except (ValueError, IndexError):
                counts["field_errors"] = counts.get("field_errors", 0) + 1
        # ---- sporadic: Digital/Analog
        spd = blk.get("sporadic")
        sp = parse_sporadic(spd) if spd else None
        if sp is not None:
            sp_stats["blocks"] += 1
            prev_tick = spclock.prev_tick
            at = spclock.mapper(sp, tb)
            if prev_tick is not None and prev_tick == sp["tick_end"]:
                sp_stats["frozen_blocks"] += 1
            any_invalid = False
            for c_id, dd in digital.items():
                for fl, sec, tick, val in sp["chains"].get((111, 1, c_id), []):
                    sp_stats["records"] += 1
                    t = at(sec, tick)
                    valid = not (fl & 0x4000)
                    any_invalid |= not valid
                    st = dig_state.get(c_id)
                    if st is not None and st == (val, valid):
                        continue
                    key = ("digital", c_id)
                    name = dd["name"] or f"Digital {c_id}"
                    src = f"Digital {c_id}"
                    dig_points.setdefault(c_id, []).append((t, (1 if val else 0) if valid else None))
                    if valid:
                        txt = dd["state1"] if val else dd["state0"]
                        ev.start(key, t, "digital", f"{name}: {txt}", L(f"Rohwert {val}", f"raw value {val}") +
                                 (L(", Zustand bei Aufnahmebeginn", ", state at start of recording") if st is None else ""),
                                 src)
                    else:
                        ev.start(key, t, "digital", f"{name}: " + L("kein gültiges Signal", "no valid signal"),
                                 L("Eingang meldet ungültig (Merker 0x4000)", "input flagged invalid (flag 0x4000)"), src)
                    dig_state[c_id] = (val, valid)
            for c_id, ad in analog.items():
                key_s = f"analog_{c_id}"
                for fl, sec, tick, val in sp["chains"].get((110, 1, c_id), []):
                    sp_stats["records"] += 1
                    t = at(sec, tick)
                    valid = not (fl & 0x4000)
                    any_invalid |= not valid
                    if ana_valid.get(c_id, True) != valid:
                        key = ("analog", c_id)
                        if not valid:
                            ev.start(key, t, "analog", f"{ad['name'] or 'Analog ' + str(c_id)}: " +
                                     L("kein gültiger Wert", "no valid value"), "", f"Analog {c_id}")
                        else:
                            ev.stop(key, t)
                    ana_valid[c_id] = valid
                    if val is None:
                        continue
                    v = val & 0xFFFF
                    v = v - 0x10000 if v & 0x8000 else v
                    arr = hold_series.setdefault(key_s, [])
                    arr.append((t, v if valid else None))
            if any_invalid and invalid_since is None:
                invalid_since = tb
                ev.start("sporadic_invalid", tb, "system", L("Digital-/Analogeingänge ohne gültige Daten",
                                                             "Digital/analog inputs without valid data"),
                         L("Merker 0x4000 an den Eingängen (Verbindung zur Anschlussbox?)",
                           "flag 0x4000 on the inputs (junction box link?)"), "sporadic")
            elif not any_invalid and invalid_since is not None:
                ev.stop("sporadic_invalid", tb)
                invalid_since = None
        # ---- alarmblock: Ereignisprotokoll des VDR
        for ln in blk.get("alarmblock", b"").decode("latin-1", "replace").split("\n"):
            if ln.strip():
                _syslog(ln, b["start"], t0, ev, syslog_open, alert_open)
        # ---- attachedinfo: Zusatzangaben je Bildquelle (Karten der ECDIS)
        for name, data in blk.items():
            if not name.startswith("attachedinfo") or len(data) < 8:
                continue
            kv = {}
            for ln in data[8:].decode("latin-1", "replace").split("\r\n"):
                if "=" in ln:
                    a, v = ln.split("=", 1)
                    kv[a.strip()] = v.strip()
            lst = ecdis.setdefault(name, [])
            if not lst or lst[-1][1] != kv:
                lst.append([tb, kv])
        if k % 25 == 0:
            _worker_progress("data", (k + 1) / len(blocks))
    t_end = job["duration"]
    ev.finish(t_end)
    for d in list(alert_open.values()) + list(syslog_open.values()):
        if d.get("end") is None:
            d["end"] = t_end
            d["open"] = True
    # Digital- und Analogreihen: gespeichert wird nur bei Änderung → je Sekunde der letzte Wert, dazwischen halten
    for key_s, pts in list(hold_series.items()) + [(f"digital_{c}", p) for c, p in dig_points.items()]:
        arr: list[Any] = [None] * n_sec
        pts.sort(key=lambda x: x[0])
        cur = None
        j = 0
        for i in range(n_sec):
            while j < len(pts) and pts[j][0] < i + 1:
                cur = pts[j][1]
                j += 1
            arr[i] = cur
        series[key_s] = arr
    meta = {}
    for key in series:
        if key in SERIES:
            de, en, unit, nd, hold = SERIES[key]
        elif key.startswith("analog_"):
            ad = analog[int(key.split("_")[1])]
            de, en = f"Analog {ad['channel']}: {ad['name']}", f"Analog {ad['channel']}: {ad['name']}"
            unit, hold = L("roh (16 bit)", "raw (16 bit)"), True
        else:
            dd = digital[int(key.split("_")[1])]
            de, en = f"Digital {dd['channel']}: {dd['name']}", f"Digital {dd['channel']}: {dd['name']}"
            unit, hold = f"1={dd['state1']}, 0={dd['state0']}", True
        meta[key] = {"label_de": de, "label_en": en, "unit": unit, "hold": hold, "values": series[key]}
    data_dir = out_dir / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    _dump(data_dir / "series.json", {"t0_utc": t0, "dt": 1.0, "n": n_sec, "series": meta})
    own = ais.own
    _dump(data_dir / "ais.json", {"own": own, "targets": ais.targets, "messages": ais.counts})
    ev.items.sort(key=lambda e: (e["t"], e["kind"]))
    clock.sort()
    return {"events": ev.items, "counts": counts, "bad_checksum": bad_checksum, "lines": lines_total,
            "series": sorted(meta), "ais_targets": len(ais.targets), "ais_messages": ais.counts, "ais_errors": ais.errors,
            "ecdis_info": ecdis, "config_changes": cfg_changes, "unreadable": unreadable, "sporadic": sp_stats,
            "gps_clock_offset_s": {"n": len(clock), "median": round(clock[len(clock) // 2], 3) if clock else None,
                                   "min": round(clock[0], 3) if clock else None,
                                   "max": round(clock[-1], 3) if clock else None}}


def _autopilot(t: float, f: list[str], st: dict[str, Any], ev: Events, src: str) -> None:
    mode = f[4]
    if mode and mode != st.get("mode"):
        prev = st.get("mode")
        name = STEERING.get(mode, (mode, mode))
        ev.point(t, "autopilot", L("Steuerart", "Steering mode") + f": {L(*name)}",
                 (L("vorher", "was") + f" {L(*STEERING.get(prev, (prev, prev)))}" if prev else
                  L("Stand bei Aufnahmebeginn", "state at start of recording")) + f" (HTD {mode})", src)
        st["mode"] = mode
    if f[1] and f[1] != st.get("override"):
        if st.get("override") is not None:
            ev.point(t, "autopilot", L("Übersteuerung", "Override") + (L(" aktiv", " active") if f[1] == "A" else
                                                                       L(" aus", " off")), f"HTD {f[1]}", src)
        st["override"] = f[1]
    hd = _f(f[10])
    last = st.get("heading")
    if hd is not None and (last is None or abs(((hd - last + 180) % 360) - 180) >= 1.0):
        pend = st.get("hd_ev")
        if pend is not None and t - pend["t"] < 10:
            pend["label"] = L("Sollkurs", "Heading order") + f" {hd:.1f}°"
        else:
            st["hd_ev"] = ev.point(t, "autopilot", L("Sollkurs", "Heading order") + f" {hd:.1f}°",
                                   (L("vorher", "was") + f" {last:.1f}°") if last is not None else
                                   L("Stand bei Aufnahmebeginn", "state at start of recording"), src)
        st["heading"] = hd


def _telegraph(t: float, f: list[str], st: dict[Any, tuple[str, str, str]], ev: Events, src: str,
               put: Callable[[str, float, float | None, int], None]) -> None:
    # $--ETL,zeit,O/A,stellung,unter-telegraf,ort,maschine
    typ, pos, sub, loc, eng = f[2], f[3], f[4], f[5], f[6]
    if typ not in ("O", "A"):
        return
    if pos in TELEGRAPH:
        put("telegraph_order" if typ == "O" else "telegraph_answer", t, TELEGRAPH[pos][0], 0)
    key = (typ, eng)
    if st.get(key) == (pos, sub, loc):
        return
    first = key not in st
    st[key] = (pos, sub, loc)
    what = L("Maschinentelegraf Befehl", "Engine telegraph order") if typ == "O" else \
        L("Maschinentelegraf Antwort", "Engine telegraph answer")
    lab = L(*TELEGRAPH[pos][1:]) if pos in TELEGRAPH else (pos or "–")
    det = []
    if sub in SUB_TELEGRAPH:
        det.append(L(*SUB_TELEGRAPH[sub]))
    if loc in LOCATION:
        det.append(L(*LOCATION[loc]))
    if eng not in ("", "0"):
        det.append(L("Maschine", "engine") + f" {eng}")
    if first:
        det.append(L("erster Wert der Aufnahme", "first value in the recording"))
    ev.point(t, "telegraph", f"{what}: {lab}", ", ".join(det) + f" (ETL {pos},{sub},{loc})", src)


def _alarm_alr(t: float, chan: Any, talker: str, f: list[str], st: dict[Any, Any], ev: Events, src: str) -> None:
    # $--ALR,zeit,nummer,zustand A/V,quittung A/V,text
    num = f[2]
    if not num:
        return
    key = ("ALR", chan, talker, num)
    active = f[3] == "A"
    ack = f[4]
    text = (f[5] if len(f) > 5 else "").strip()
    cur = st.get(key)
    if active and (cur is None or not cur["active"]):
        e = ev.start(key, t, "alarm", text or L(f"Alarm {num}", f"Alarm {num}"),
                     f"{talker}ALR {num}, " + (L("quittiert", "acknowledged") if ack == "A" else
                                              L("nicht quittiert", "not acknowledged")) +
                     (f", {L('Zeit im Satz', 'time in sentence')} {f[1]}" if f[1] else ""), src)
        st[key] = {"active": True, "ack": ack, "ev": e}
    elif active and cur["ack"] != ack:
        if ack == "A":
            cur["ev"]["detail"] += f"; {L('quittiert bei', 'acknowledged at')} {t:.1f} s"
        cur["ack"] = ack
    elif not active and cur is not None and cur["active"]:
        ev.stop(key, t)
        cur["active"] = False


def _alarm_ala(t: float, chan: Any, f: list[str], st: dict[Any, Any], ev: Events, src: str) -> None:
    # $--ALA,zeit,system,teilsystem,instanz,typ,zustand,quittung,text  (Zustand N/V = normal, sonst Alarm)
    key = ("ALA", chan, f[2], f[3], f[4], f[5])
    active = f[6] not in ("N", "V", "")
    ack = f[7]
    text = f[8].strip() if len(f) > 8 else ""
    cur = st.get(key)
    if active and (cur is None or not cur["active"]):
        e = ev.start(key, t, "alarm", text or f"ALA {f[2]} {f[3]} {f[4]} {f[5]}",
                     f"ALA {f[2]}/{f[3]}/{f[4]}/{f[5]}, {L('Zustand', 'condition')} {f[6]}, " +
                     (L("quittiert", "acknowledged") if ack == "A" else L("nicht quittiert", "not acknowledged")) +
                     (f", {L('Zeit im Satz', 'time in sentence')} {f[1]}" if f[1] else ""), src)
        st[key] = {"active": True, "ack": ack, "ev": e}
    elif active and cur["ack"] != ack:
        if ack == "A":
            cur["ev"]["detail"] += f"; {L('quittiert bei', 'acknowledged at')} {t:.1f} s"
        cur["ack"] = ack
    elif not active and cur is not None and cur["active"]:
        ev.stop(key, t)
        cur["active"] = False


def _alert_alf(t: float, chan: Any, f: list[str], st: dict[Any, Any], ev: Events, src: str) -> None:
    # $--ALF,anzahl,nummer,folge,zeit,kategorie,priorität,zustand,hersteller,kennung,instanz,revision,eskalation,text
    if f[2] not in ("1", ""):
        return
    key = ("ALF", chan, f[8], f[9], f[10])
    state = f[7]
    active = state in ("V", "S", "A", "O")
    cur = st.get(key)
    text = f[13].strip() if len(f) > 13 else ""
    if active and (cur is None or not cur["active"]):
        e = ev.start(key, t, "alert", text or f"ALF {f[8]} {f[9]}",
                     f"ALF {f[8]} {f[9]}.{f[10]}, {L('Priorität', 'priority')} {f[6]}, {L('Kategorie', 'category')} {f[5]}, "
                     f"{L('Zustand', 'state')} {state}", src)
        st[key] = {"active": True, "state": state, "ev": e}
    elif active and cur["state"] != state:
        cur["ev"]["detail"] += f"; {state} {L('bei', 'at')} {t:.1f} s"
        cur["state"] = state
    elif not active and cur is not None and cur["active"]:
        ev.stop(key, t)
        cur["active"] = False


def _syslog(ln: str, t_block: float, t0: float, ev: Events, open_: dict[Any, dict[str, Any]],
            alerts: dict[str, dict[str, Any]]) -> None:
    """alarmblock: „JJJ/MM/TT/hh/mm/ss/mmm/folge:<typ,quelle,…>:…|feld|feld|…|“, Typ 0x1f4 = Alarm des VDR,
    0xd3 = Protokoll (Power, UTC, MIC, System, Warning, …). Datum aus dem Block, Uhrzeit aus dem Präfix."""
    m = re.match(r"^(\d+)/(\d+)/(\d+)/(\d+)/(\d+)/(\d+)/(\d+)/(\d+):<([^>]*)>:[^|]*\|(.*)$", ln.strip())
    if not m:
        return
    tod = int(m.group(4)) * 3600 + int(m.group(5)) * 60 + int(m.group(6)) + int(m.group(7)) / 1000
    day0 = (int(t_block) // 86400) * 86400
    t_abs = day0 + tod
    if t_abs - t_block > 43200:
        t_abs -= 86400
    elif t_block - t_abs > 43200:
        t_abs += 86400
    t = t_abs - t0
    tag = m.group(9).split(",")
    parts = m.group(10).split("|")
    typ = tag[0].lower()
    if typ == "1f4" and len(parts) >= 5:
        # Alert|Text|Nummer|Zustand|Priorität   (A: aktiv, N: normal)
        text, num, state, prio = parts[1].strip(), parts[2].strip(), parts[3].strip(), parts[4].strip()
        code = state[:1]
        if code == "N":
            d = alerts.pop(num, None)
            if d is not None:
                d["end"] = round(max(t, d["t"]), 3)
            else:
                ev.point(t, "alert", text, f"VDR {num}: {state} ({prio})", "VDR")
        else:
            if num not in alerts:
                alerts[num] = ev.point(t, "alert", text, f"VDR {num}: {state} ({prio})", "VDR")
    else:
        cat = parts[0].strip() if parts else ""
        what = parts[1].strip() if len(parts) > 1 else ""
        rest = [x.strip() for x in parts[2:] if x.strip()]
        key = (cat, what)
        if rest and rest[0] == "Occurrence":
            open_[key] = ev.point(t, "system", f"{cat}: {what}", " ".join(rest), "VDR")
        elif rest and rest[0] in ("Recovered", "Recovery") and key in open_:
            e = open_.pop(key)
            e["end"] = round(max(t, e["t"]), 3)
        else:
            ev.point(t, "system", f"{cat}: {what}", " · ".join(rest), "VDR")


def _dump(path: Path, data: Any) -> None:
    tmp = path.with_suffix(".part")
    tmp.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    os.replace(tmp, path)


# ------------------------------------------------------------------------------------------------ Bilder

def task_images(job: dict[str, Any]) -> dict[str, Any]:
    """Bilder je Quelle nach images/<quelle>/<block>.<png|jpg>: PNG und JPEG unverändert (der VR-7000 legt „image/bmp“
    als PNG ab); echte BMP werden PNG, außer das PNG wird mehr als dreimal so groß wie ein JPEG mit Qualität 92."""
    out_dir = Path(job["out_dir"]) / "images"
    frames: dict[str, list[Any]] = {}
    stats: dict[str, dict[str, Any]] = {}
    info: dict[str, dict[str, Any]] = {}
    blocks = job["blocks"]
    t0 = job["t0"]
    for k, b in enumerate(blocks):
        blk = _safe_block(b, lambda n: bool(_RADAR.match(n)))
        for name, data in sorted((blk or {}).items()):
            hd = parse_image(data)
            if hd is None:
                continue
            payload = data[hd["offset"]:]
            ext = hd["kind"]
            st = stats.setdefault(name, {"count": 0, "bytes": 0, "kinds": {}, "no_signal": 0, "converted": 0})
            if ext in ("bmp", "zlib", "bin"):
                payload, ext = _convert_image(payload, hd)
                st["converted"] += 1
            folder = out_dir / name
            folder.mkdir(parents=True, exist_ok=True)
            fn = f"{b['id']}.{ext}"
            (folder / fn).write_bytes(payload)
            t_rec = hd["t"] - t0
            t_cap = (hd["capture"] - t0) if hd["capture"] is not None else None
            use_cap = t_cap is not None and abs(t_cap - t_rec) < 60
            frames.setdefault(name, []).append([round(t_cap if use_cap else t_rec, 3), f"{name}/{fn}", round(t_rec, 3)])
            st["count"] += 1
            st["bytes"] += len(payload)
            st["kinds"][ext] = st["kinds"].get(ext, 0) + 1
            if hd["no_signal"]:
                st["no_signal"] += 1
                info.setdefault(name, {}).setdefault("no_signal", []).append(f"{name}/{fn}")
            inf = info.setdefault(name, {})
            if not inf.get("mime") and not hd["no_signal"]:
                inf.update({"mime": hd["mime"], "stored_as": ext, "width": hd["w"], "height": hd["h"],
                            "header_source": hd["head"].get("Source", ""), "location": hd["head"].get("Location", ""),
                            "time": "capture" if use_cap else "record"})
        if k % 25 == 0:
            _worker_progress(job["key"], (k + 1) / len(blocks))
    return {"frames": frames, "stats": stats, "info": info}


def _convert_image(payload: bytes, hd: dict[str, Any]) -> tuple[bytes, str]:
    from PIL import Image
    img = None
    if hd["kind"] == "bmp":
        img = Image.open(io.BytesIO(payload))
    elif hd["kind"] == "zlib":
        with contextlib.suppress(zlib.error, ValueError):
            raw = zlib.decompress(payload)
            if hd["w"] and hd["h"] and len(raw) == hd["w"] * hd["h"] * 3:
                img = Image.frombytes("RGB", (hd["w"], hd["h"]), raw, "raw", "BGR")
    if img is None:
        return payload, "bin"
    img = img.convert("RGB")
    png, jpg = io.BytesIO(), io.BytesIO()
    img.save(png, "PNG", optimize=False, compress_level=6)
    img.save(jpg, "JPEG", quality=92, subsampling=0)
    return (png.getvalue(), "png") if png.tell() <= 3 * jpg.tell() else (jpg.getvalue(), "jpg")


# ------------------------------------------------------------------------------------------------ Ton

def _audio_tools() -> Any:
    import importlib.util
    mod = sys.modules.get("audio_tools")
    if mod is None:
        spec = importlib.util.spec_from_file_location("audio_tools", Path(__file__).with_name("audio_tools.py"))
        assert spec and spec.loader
        mod = importlib.util.module_from_spec(spec)
        sys.modules["audio_tools"] = mod
        spec.loader.exec_module(mod)
    return mod


def ogg_granule(b: bytes) -> int | None:
    """Granule-Position der letzten Seite = Probenzahl der Datei."""
    pos = 0
    last = None
    while pos + 27 <= len(b):
        if b[pos:pos + 4] != b"OggS":
            nxt = b.find(b"OggS", pos + 1)
            if nxt < 0:
                break
            pos = nxt
            continue
        gp = struct.unpack_from("<q", b, pos + 6)[0]
        nseg = b[pos + 26]
        size = sum(b[pos + 27:pos + 27 + nseg])
        if gp >= 0:
            last = gp
        pos += 27 + nseg + size
    return last


def _join_metric(np: Any, tail: Any, head: Any) -> float | None:
    """Sprung an einer Naht: Vorhersagefehler 2. Ordnung an der Naht gegen das 99. Perzentil der Umgebung."""
    if len(tail) < 128 or len(head) < 128:
        return None
    seg = np.concatenate([tail[-128:], head[:128]]).astype(np.float64)
    e = np.abs(seg[2:] - 2 * seg[1:-1] + seg[:-2])
    k = 126   # e[k] sagt seg[128] = erste Probe nach der Naht voraus
    around = np.r_[e[:k - 4], e[k + 4:]]
    ref = float(np.percentile(around, 99))
    if ref < 1e-5:
        return None
    return float(e[k - 1:k + 2].max() / ref)


def task_audio(job: dict[str, Any]) -> dict[str, Any]:
    """Eine Seite (links/rechts) einer Ogg-Datei über alle Blöcke: EIN Dekoder über alle Dateien (durchgehender
    Kodierer), Platz nach Track.txt mit Toleranz, FLAC 16 bit + Wellenform + Opus-Vorschau, Pegel, Nähte."""
    import av
    import numpy as np
    at = _audio_tools()
    blocks = job["blocks"]
    t0 = job["t0"]
    sr = int(job.get("sr") or SR)
    side = int(job["side"])
    fname = job["file"]
    key = job["key"]
    w = at.Writer(Path(job["flac"]), sr, 1, Path(job["peaks"]), Path(job["proxy"]), subtype="PCM_16",
                  proxy_kbps=int(job.get("proxy_kbps") or PROXY_KBPS), proxy_rate=sr,
                  proxy_options=dict(job.get("proxy_options") or PROXY_OPTIONS))
    loud = at.Loudness(sr, 1)
    n_sec = int(math.ceil(job["duration"])) + 4
    sq = np.zeros(n_sec + 64, np.float64)
    cnt = np.zeros(n_sec + 64, np.int64)
    pos = 0
    keep = None
    ctx = None
    prev_id = None
    tail = None
    lengths: list[int] = []
    leads: list[int] = []
    drifts: list[float] = []
    joins: list[float] = []
    suspicious: list[list[float]] = []
    restarts: list[dict[str, Any]] = []
    pads: list[dict[str, Any]] = []
    missing: list[int] = []
    max_drift = int(MAX_DRIFT_S * sr)

    def decode(data: bytes, fresh_ctx: bool) -> Any:
        nonlocal keep, ctx
        cont = av.open(io.BytesIO(data))
        if fresh_ctx:
            if keep is not None:
                keep.close()
            keep = cont
            ctx = cont.streams.audio[0].codec_context
        parts = []
        for pkt in cont.demux(cont.streams.audio[0]):
            if pkt.size == 0:
                continue
            for fr in ctx.decode(pkt):
                a = fr.to_ndarray()
                parts.append(a if fr.format.is_planar else a.reshape(-1, fr.layout.nb_channels).T)
        if cont is not keep:
            cont.close()
        if not parts:
            return np.zeros((0, 2), np.float32)
        x = np.concatenate(parts, axis=1).T.astype(np.float32, copy=False)
        return x if x.shape[1] >= 2 else np.repeat(x, 2, axis=1)

    def write(y: Any) -> None:
        nonlocal pos, sq, cnt
        if not len(y):
            return
        w.add(y)
        loud.add(y)
        first = pos // sr
        local = (pos + np.arange(len(y))) // sr - first
        n_loc = int(local[-1]) + 1
        if first + n_loc > len(sq):   # länger als gedacht: Felder verlängern
            grow = first + n_loc - len(sq) + 64
            sq = np.concatenate([sq, np.zeros(grow)])
            cnt = np.concatenate([cnt, np.zeros(grow, np.int64)])
        sq[first:first + n_loc] += np.bincount(local, weights=y[:, 0].astype(np.float64) ** 2, minlength=n_loc)
        cnt[first:first + n_loc] += np.bincount(local, minlength=n_loc)
        pos += len(y)

    # gemeinsamer Bezug aller Kanäle: um den üblichen Versatz der Schnitte verschieben (_audio_offsets)
    shift = int(round(float(job.get("offset_s") or 0.0) * sr))
    skip = 0
    if shift > 0:
        write(np.zeros((shift, 1), np.float32))
    elif shift < 0:
        skip = -shift
    for k, b in enumerate(blocks):
        expected = int(round((b["start"] - t0) * sr))
        blk = _safe_block(b, lambda n: n == fname)
        data = (blk or {}).get(fname)
        if not data:
            missing.append(b["id"])
            ctx = None
            prev_id = None
            continue
        gp = ogg_granule(data)
        fresh = ctx is None or prev_id is None or b["id"] != prev_id + 1
        x = decode(data, fresh)
        restarted = False
        if not fresh and gp is not None and len(x) != gp:
            # Kodierer neu angelaufen (oder Datei beschädigt): diese Datei für sich dekodieren
            x = decode(data, True)
            restarted = True
            restarts.append({"block": b["id"], "t": round(expected / sr, 2)})
        lead = 0
        if (fresh or restarted) and gp is not None and 0 < gp - len(x) <= 8192:
            lead = gp - len(x)  # Vorlauf, der den Vorgänger braucht: als Stille, damit die Zeit stimmt
            leads.append(lead)
            x = np.concatenate([np.zeros((lead, 2), np.float32), x])
        lengths.append(len(x))
        prev_id = b["id"]
        y = x[:, side:side + 1]
        if skip:
            cut0 = min(skip, len(y))
            y = y[cut0:]
            skip -= cut0
        if pos < expected - max_drift:
            gap = expected - pos
            pads.append({"t": round(pos / sr, 2), "seconds": round(gap / sr, 3), "block": b["id"], "kind": "pad"})
            write(np.zeros((gap, 1), np.float32))
            tail = None
        elif pos > expected + max_drift:
            cut = min(len(y), pos - expected)
            pads.append({"t": round(pos / sr, 2), "seconds": round(-cut / sr, 3), "block": b["id"], "kind": "overlap"})
            y = y[cut:]
        drifts.append((pos - expected) / sr)
        if tail is not None and not fresh and not restarted and len(y):
            mtr = _join_metric(np, tail[:, 0], y[:, 0])
            if mtr is not None:
                joins.append(mtr)
                if mtr > 3.0 and len(suspicious) < 50:
                    suspicious.append([round(pos / sr, 3), round(mtr, 1)])
        write(y)
        tail = y[-256:].copy() if len(y) >= 256 else None
        if k % 10 == 0:
            _worker_progress(key, (k + 1) / len(blocks) * 0.97)
    # bis zum Ende der Aufnahme auffüllen (alle Spuren decken die ganze Aufnahme ab)
    total = int(round(job["duration"] * sr))
    if pos < total:
        write(np.zeros((total - pos, 1), np.float32))
    if keep is not None:
        keep.close()
    res = w.close()
    _worker_progress(key, 0.98)
    analysis = loud.result()
    analysis.pop("levels_db", None)
    with contextlib.suppress(Exception):
        analysis.update(at.detect_hum(str(job["flac"]), sr, 1, pos / sr))
    nsec = max(1, int(math.ceil(pos / sr)))
    rms = np.sqrt(sq[:nsec] / np.maximum(cnt[:nsec], 1))
    db = 20 * np.log10(np.maximum(rms, 1e-6))
    floor = float(np.percentile(db, 10))
    active = int((db > floor + 10).sum())
    jarr = np.array(joins) if joins else np.zeros(0)
    _worker_progress(key, 1.0)
    return {
        "id": job["id"], "file": fname, "side": side, "frames": res["frames"], "bars": res["bars"], "peak": res["peak"],
        "duration": round(pos / sr, 3), "sample_rate": sr, "analysis": analysis, "offset_s": round(shift / sr, 3),
        "rms_db": {"p10": round(floor, 1), "p50": round(float(np.percentile(db, 50)), 1),
                   "p90": round(float(np.percentile(db, 90)), 1), "max": round(float(db.max()), 1),
                   "active_s": active, "active_share": round(active / nsec, 4)},
        "levels": [round(float(v), 1) for v in db],
        "blocks": len(lengths), "missing_blocks": missing[:200], "missing_count": len(missing),
        "file_seconds": {"min": round(min(lengths) / sr, 3) if lengths else None,
                         "max": round(max(lengths) / sr, 3) if lengths else None,
                         "mean": round(sum(lengths) / len(lengths) / sr, 4) if lengths else None,
                         "not_15s": sum(1 for x in lengths if x != BLOCK_SECONDS * sr)},
        "lead_in": {"count": len(leads), "samples": sorted(set(leads))[:10]},
        "drift_s": {"min": round(min(drifts), 3) if drifts else None, "max": round(max(drifts), 3) if drifts else None,
                    "end": round(drifts[-1], 3) if drifts else None},
        "restarts": restarts[:50], "restart_count": len(restarts), "pads": pads[:200], "pad_count": len(pads),
        "joins": {"checked": int(len(jarr)), "median": round(float(np.median(jarr)), 2) if len(jarr) else None,
                  "p99": round(float(np.percentile(jarr, 99)), 2) if len(jarr) else None,
                  "max": round(float(jarr.max()), 2) if len(jarr) else None,
                  "suspicious": int((jarr > 3.0).sum()), "examples": suspicious[:20]}}


# ------------------------------------------------------------------------------------------------ Einlesen

_W: dict[str, Any] = {}
_PARENT: int | None = None


def _parent_alive() -> bool:
    if _PARENT is None:
        return True
    if sys.platform == "win32":
        import ctypes
        k32 = ctypes.windll.kernel32
        h = k32.OpenProcess(0x00100000, False, _PARENT)   # SYNCHRONIZE
        if not h:
            return False
        try:
            return k32.WaitForSingleObject(h, 0) == 0x102   # WAIT_TIMEOUT: läuft noch
        finally:
            k32.CloseHandle(h)
    return os.getppid() == _PARENT


def _worker_init(queue: Any, parent: int, torch_site: str) -> None:
    global _PARENT
    _W["queue"] = queue
    _PARENT = parent
    if torch_site and Path(torch_site).is_dir() and torch_site not in sys.path:
        sys.path.append(torch_site)
    if sys.platform == "win32":
        # alle Kerne für Minuten belegt: niedrigere Priorität, damit Oberfläche und andere Programme flüssig bleiben
        with contextlib.suppress(Exception):
            import ctypes
            k32 = ctypes.windll.kernel32
            k32.SetPriorityClass(k32.GetCurrentProcess(), 0x00004000)   # BELOW_NORMAL_PRIORITY_CLASS
    # Abbrechen beendet nur den Hauptprozess (audio_lab._run_tool: proc.kill()); auch untätige Arbeiter merken das hier
    import threading

    def watchdog() -> None:
        while True:
            time.sleep(1.0)
            if not _parent_alive():
                os._exit(3)
    threading.Thread(target=watchdog, name="vdr-watchdog", daemon=True).start()


def task_granules(job: dict[str, Any]) -> dict[str, Any]:
    """Probenzahl (letzte Granule-Position) jeder Ogg-Datei der Blöcke, ohne zu dekodieren."""
    files = set(job["files"])
    out: dict[str, dict[str, int | None]] = {}
    for k, b in enumerate(job["blocks"]):
        blk = _safe_block(b, lambda n: n in files)
        out[str(b["id"])] = {f: ogg_granule(d) for f, d in (blk or {}).items()}
        if k % 50 == 0:
            _worker_progress(job["key"], (k + 1) / len(job["blocks"]))
    return {"granules": out}


def _audio_offsets(blocks: list[dict[str, Any]], t0: float, parts: list[dict[str, Any]],
                   files: list[str]) -> dict[str, dict[str, Any]]:
    """Je Ogg-Datei: wo die Schnitte des durchlaufenden Tons im Mittel gegen das Blockraster liegen. Der Rekorder
    schneidet alle Kanäle zugleich; ein Kanal, dessen erster Schnitt zufällig spät lag, läuft sonst um diesen Betrag
    gegen die anderen versetzt (gemessen 0,1–0,27 s, per Kreuzkorrelation bestätigt). Versatz = −Median der Abweichung."""
    gran: dict[str, dict[str, int | None]] = {}
    for p in parts:
        gran.update(p["granules"])
    out: dict[str, dict[str, Any]] = {}
    for f in files:
        cum = 0
        devs: list[float] = []
        prev_id = None
        for b in blocks:
            gp = (gran.get(str(b["id"])) or {}).get(f)
            if gp is None or (prev_id is not None and b["id"] != prev_id + 1):
                # Lücke: der Ton setzt dort wieder am Raster an
                cum = int(round((b["start"] - t0) * SR))
            if gp is None:
                prev_id = None
                continue
            devs.append(cum / SR - (b["start"] - t0))
            cum += gp
            prev_id = b["id"]
        if len(devs) >= 20:
            devs.sort()
            med = devs[len(devs) // 2]
            out[f] = {"offset_s": round(-med, 3), "median_drift_s": round(med, 3), "blocks": len(devs),
                      "p10": round(devs[len(devs) // 10], 3), "p90": round(devs[len(devs) * 9 // 10], 3)}
    return out


def _run_task(kind: str, job: dict[str, Any]) -> tuple[str, str, dict[str, Any], float]:
    t_start = time.time()
    if kind == "audio":
        res = task_audio(job)
    elif kind == "granules":
        res = task_granules(job)
    elif kind == "data":
        res = task_data(job)
    elif kind == "images":
        res = task_images(job)
    else:
        res = verify(job["path"], lambda f, s: _worker_progress(job["key"], f))
        _worker_progress(job["key"], 1.0)
    return kind, job["key"], res, round(time.time() - t_start, 1)


def _blocks_for_job(blocks: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [{"id": b["id"], "path": str(b["path"]), "gz": b["gz"], "start": b["start"]} for b in blocks]


def cmd_import(s: dict[str, Any]) -> dict[str, Any]:
    """Ganzer Export → Projektordner: tracks/ (FLAC 16 bit), peaks/, proxy/, data/ (JSON), images/."""
    import multiprocessing as mp
    global _LANG
    t_start = time.time()
    _LANG = s.get("lang") or "de"
    summary = inspect(s["path"], s.get("track"))
    ex = find_export(s["path"], s.get("track"))
    out = Path(s["out_dir"])
    for sub in ("tracks", "peaks", "proxy", "data", "images"):
        (out / sub).mkdir(parents=True, exist_ok=True)
    blocks = _blocks_for_job(ex["blocks"])
    for b in blocks:
        b["path"] = Path(b["path"])
    t0 = ex["t0"]
    duration = float(ex["end"] - t0)
    want = set(s.get("track_ids") or [])
    chans = [c for c in summary["audio"] if not want or c["id"] in want]
    tasks: list[tuple[str, dict[str, Any], float]] = []
    audio_jobs: list[tuple[str, dict[str, Any], float]] = []
    for c in chans:
        audio_jobs.append(("audio", {"key": c["id"], "id": c["id"], "file": c["file"], "side": c["side"],
                                     "blocks": blocks, "t0": t0, "duration": duration, "sr": c.get("rate") or SR,
                                     "flac": str(out / "tracks" / f"{c['id']}.flac"),
                                     "peaks": str(out / "peaks" / f"{c['id']}.peaks"),
                                     "proxy": str(out / "proxy" / f"{c['id']}.webm"),
                                     "proxy_kbps": s.get("proxy_kbps") or PROXY_KBPS}, 1.0))
    # Vorlauf: Granule-Positionen aller Ogg-Dateien → je Datei der übliche Versatz der Schnitte zum Blockraster
    files = sorted({c["file"] for c in chans})
    if files and s.get("align", True):
        n_g = max(1, min(8, len(blocks) // 50 or 1))
        step_g = int(math.ceil(len(blocks) / n_g))
        for i in range(n_g):
            part = blocks[i * step_g:(i + 1) * step_g]
            if part:
                tasks.append(("granules", {"key": f"granules{i}", "blocks": part, "files": files}, 0.1 / n_g))
    if s.get("data", True):
        tasks.append(("data", {"key": "data", "blocks": blocks, "t0": t0, "duration": duration, "out_dir": str(out),
                               "summary": summary, "lang": _LANG}, 0.6))
    if s.get("images", True):
        n_img = max(1, min(4, int(s.get("image_workers") or 2)))
        step = int(math.ceil(len(blocks) / n_img))
        for i in range(n_img):
            part = blocks[i * step:(i + 1) * step]
            if part:
                tasks.append(("images", {"key": f"images{i}", "blocks": part, "t0": t0, "out_dir": str(out)},
                              0.5 / n_img))
    if s.get("verify", True):
        tasks.append(("verify", {"key": "verify", "path": s["path"]}, 0.2))
    weights = {job["key"]: wt for _, job, wt in tasks + audio_jobs}
    fracs = {k: 0.0 for k in weights}
    workers = max(1, min(int(s.get("workers") or (os.cpu_count() or 4)),
                         max(len(audio_jobs) + 4, len(tasks)), 16))
    spawn = mp.get_context("spawn")
    queue = spawn.Queue()
    results: dict[str, Any] = {}
    timings: dict[str, float] = {}
    offsets: dict[str, dict[str, Any]] = {}
    emit(progress=0.0, stage=L("liest den VDR-Export", "reading the VDR export"))
    with spawn.Pool(workers, initializer=_worker_init,
                    initargs=(queue, os.getpid(), os.environ.get("NVAI_AUDIO_TORCH_SITE", ""))) as pool:
        # Vorlauf und kurze Aufgaben zuerst; der Ton startet, sobald die Versätze feststehen
        pending = [pool.apply_async(_run_task, (kind, job)) for kind, job, _ in tasks]
        audio_started = not audio_jobs
        if audio_jobs and not any(k == "granules" for k, _, _ in tasks):
            pending += [pool.apply_async(_run_task, (kind, job)) for kind, job, _ in audio_jobs]
            audio_started = True
        last_emit = 0.0
        while pending:
            try:
                while True:
                    k, f = queue.get(timeout=0.3)
                    fracs[k] = max(fracs.get(k, 0.0), f)
            except Exception:  # noqa: BLE001 - leere Warteschlange
                pass
            still = []
            for a in pending:
                if a.ready():
                    kind, key, res, secs = a.get()   # Fehler einer Aufgabe brechen hier ab
                    results[key] = (kind, res)
                    timings[key] = secs
                    fracs[key] = 1.0
                else:
                    still.append(a)
            pending = still
            if not audio_started and all(k in results for k in weights if k.startswith("granules")):
                offsets = _audio_offsets(blocks, t0, [results[k][1] for k in results if k.startswith("granules")],
                                         files)
                for kind, job, _ in audio_jobs:
                    job["offset_s"] = offsets.get(job["file"], {}).get("offset_s", 0.0)
                    pending.append(pool.apply_async(_run_task, (kind, job)))
                audio_started = True
            now = time.time()
            if now - last_emit > 0.5:
                total = sum(weights.values()) or 1.0
                done = sum(fracs[k] * weights[k] for k in weights) / total
                busy = sorted(k for k in weights if fracs[k] < 1.0)
                emit(progress=round(0.98 * done, 4), stage=L("Ton, Daten, Bilder", "audio, data, images") +
                     f" ({len(weights) - len(busy)}/{len(weights)})")
                last_emit = now
    emit(progress=0.985, stage=L("schreibt die Übersicht", "writing the summary"))
    tracks = [results[c["id"]][1] for c in chans if c["id"] in results]
    data_res = results.get("data", (None, {}))[1] if "data" in results else {}
    events = list(data_res.get("events") or [])
    for g in ex["gaps"]:
        events.append({"t": g["t"], "end": g["t"] + max(0, g["seconds"]), "kind": "gap",
                       "label": L("Lücke in der Aufnahme", "Gap in the recording"),
                       "detail": L(f"{g['missing_ids']} Blöcke fehlen, {g['seconds']} s", f"{g['missing_ids']} blocks missing, "
                                   f"{g['seconds']} s"), "source": "Track.txt"})
    after_gap = {g["next"] for g in ex["gaps"]}
    seen_pad: set[tuple[str, int]] = set()
    for tr in tracks:
        for p in tr["pads"]:
            # an Lücken aus Track.txt erwartet (steht schon als Lücke da); je Ogg-Datei nur einmal melden
            if abs(p["seconds"]) >= 0.5 and p["block"] not in after_gap and (tr["file"], p["block"]) not in seen_pad:
                seen_pad.add((tr["file"], p["block"]))
                events.append({"t": p["t"], "end": p["t"] + max(0.0, p["seconds"]), "kind": "gap",
                               "label": L("Ton neu ausgerichtet", "Audio realigned") + f" ({tr['file']})",
                               "detail": f"{p['kind']} {p['seconds']} s, block {p['block']}", "source": tr["file"]})
    events.sort(key=lambda e: (e["t"], e["kind"]))
    _dump(out / "data" / "events.json", events)
    # Bilder zusammenführen
    frames: dict[str, list[Any]] = {}
    img_stats: dict[str, dict[str, Any]] = {}
    img_info: dict[str, dict[str, Any]] = {}
    no_signal: dict[str, set[str]] = {}
    for key in sorted(k for k in results if k.startswith("images")):
        r = results[key][1]
        for name, fl in r["frames"].items():
            frames.setdefault(name, []).extend(fl)
            no_signal.setdefault(name, set()).update((r["info"].get(name) or {}).get("no_signal", []))
        for name, st in r["stats"].items():
            agg = img_stats.setdefault(name, {"count": 0, "bytes": 0, "kinds": {}, "no_signal": 0, "converted": 0})
            for k2 in ("count", "bytes", "no_signal", "converted"):
                agg[k2] += st[k2]
            for k2, v in st["kinds"].items():
                agg["kinds"][k2] = agg["kinds"].get(k2, 0) + v
        for name, inf in r["info"].items():
            tgt = img_info.setdefault(name, {})
            for k2, v in inf.items():
                if k2 != "no_signal" and k2 not in tgt:
                    tgt[k2] = v
    labels = {x["id"]: x.get("label") or x["id"] for x in summary["images"]}
    sources = []
    for name in sorted(frames):
        frames[name].sort(key=lambda f: f[0])
        inf = img_info.get(name, {})
        st = img_stats.get(name, {})
        ns = no_signal.get(name) or set()
        sources.append({"id": name, "label": labels.get(name, name), "count": len(frames[name]),
                        "mime": inf.get("mime"), "stored_as": st.get("kinds"), "width": inf.get("width"),
                        "height": inf.get("height"), "time": inf.get("time", "record"),
                        "location": inf.get("location", ""),
                        "no_signal": [i for i, f in enumerate(frames[name]) if f[1] in ns],
                        "bytes": st.get("bytes", 0)})
    if frames or s.get("images", True):
        _dump(out / "data" / "images.json", {"sources": sources, "frames": frames})
    _dump(out / "data" / "levels.json", {"dt": 1.0, "unit": "dBFS", "tracks": {tr["id"]: tr["levels"] for tr in tracks}})
    integrity = results.get("verify", (None, None))[1]
    ch_by_id = {c["id"]: c for c in summary["audio"]}
    track_out = []
    for tr in tracks:
        c = ch_by_id[tr["id"]]
        track_out.append({**{k: c[k] for k in ("id", "input", "position", "category", "equipment", "channel", "file",
                                               "side", "delay_ms", "model")},
                          **{k: tr[k] for k in ("frames", "bars", "peak", "duration", "sample_rate", "analysis", "rms_db",
                                                "offset_s")}})
    vdr = {
        "format": summary["format"], "summary": summary, "t0_utc": t0, "duration": duration,
        "blocks": [[b["id"], b["start"] - t0, b["path"].name] for b in blocks],
        "integrity": integrity,
        "alignment": {"method": "median_cut_drift", "files": offsets},
        "audio": [{k: v for k, v in tr.items() if k != "levels"} for tr in tracks],
        "data": {k: v for k, v in data_res.items() if k not in ("events", "ecdis_info")},
        "ecdis_info": data_res.get("ecdis_info") or {},
        "events": _count_kinds(events),
        "images": {"sources": [{k: v for k, v in x.items() if k != "no_signal"} for x in sources],
                   "stats": img_stats},
        "timings": {**timings, "total": round(time.time() - t_start, 1), "workers": workers},
    }
    _dump(out / "data" / "vdr.json", vdr)
    return {"t0_utc": t0, "duration": duration, "blocks": len(blocks), "tracks": track_out,
            "events": _count_kinds(events), "images": {x["id"]: x["count"] for x in sources},
            "integrity_ok": (integrity or {}).get("ok") if integrity else None,
            "timings": vdr["timings"], "summary": _small_summary(summary)}


def _count_kinds(events: list[dict[str, Any]]) -> dict[str, int]:
    out: dict[str, int] = {}
    for e in events:
        out[e["kind"]] = out.get(e["kind"], 0) + 1
    return out


def _small_summary(summary: dict[str, Any]) -> dict[str, Any]:
    """Was das Projekt sich merkt (project.json bleibt klein)."""
    return {k: summary.get(k) for k in ("product", "format", "folder", "layout", "track", "blocks", "first_id", "last_id",
                                        "start_utc", "end_utc", "start", "end", "duration", "gap_count", "vessel",
                                        "system", "versions", "audio", "serial", "digital", "analog", "images",
                                        "size_bytes")}


# ------------------------------------------------------------------------------------------------ Rohdaten

def block_at(path: str | Path, t: float) -> tuple[dict[str, Any], dict[str, Any]]:
    """Der Block, der die Zeit t (Sekunden ab Aufnahmebeginn) enthält."""
    ex = _export_cached(path)
    t_abs = ex["t0"] + float(t)
    if t_abs < ex["t0"] - 1 or t_abs > ex["end"] + 1:
        raise VdrError("Zu dieser Zeit gibt es keinen Block.", "There is no block at this time.")
    starts = [b["start"] for b in ex["blocks"]]
    i = max(0, bisect.bisect_right(starts, t_abs) - 1)   # in einer Lücke: der Block davor
    return ex, ex["blocks"][i]


_EXPORTS: dict[str, tuple[float, dict[str, Any]]] = {}


def _export_cached(path: str | Path) -> dict[str, Any]:
    """find_export mit kurzem Zwischenspeicher (die Rohdaten-Ansicht fragt Sekunde für Sekunde)."""
    key = str(path)
    hit = _EXPORTS.get(key)
    if hit and time.time() - hit[0] < 300:
        return hit[1]
    ex = find_export(path)
    _EXPORTS[key] = (time.time(), ex)
    return ex


def raw_lines(path: str | Path, t: float, serial_names: dict[int, str] | None = None) -> dict[str, Any]:
    """Serielle Zeilen (NMEA, wie empfangen) und VDR-Protokoll des Blocks zur Zeit t, direkt aus dem Export gelesen."""
    ex, b = block_at(path, t)
    blk = read_block(b["path"], b["gz"], lambda n: n in ("serial", "alarmblock"))
    t0 = ex["t0"]
    lines = []
    for ln in blk.get("serial", b"").decode("latin-1", "replace").split("\n"):
        if not ln.strip():
            continue
        pr = parse_serial_line(ln)
        if pr is None:
            lines.append({"t": None, "channel": None, "text": ln.strip()[:400]})
            continue
        t_abs, chan, s = pr
        item = {"t": round(t_abs - t0, 3), "channel": chan, "text": s[:400]}
        if serial_names and chan in serial_names:
            item["device"] = serial_names[chan]
        if _nmea_ok(s) is False:
            item["checksum"] = False
        lines.append(item)
    log = [ln.strip()[:400] for ln in blk.get("alarmblock", b"").decode("latin-1", "replace").split("\n") if ln.strip()]
    return {"block": b["id"], "start": b["start"] - t0, "end": b["start"] - t0 + BLOCK_SECONDS, "lines": lines,
            "log": log}


# ------------------------------------------------------------------------------------------------ Befehle

def cmd_inspect(s: dict[str, Any]) -> dict[str, Any]:
    return inspect(s["path"], s.get("track"))


def cmd_verify(s: dict[str, Any]) -> dict[str, Any]:
    return verify(s["path"], lambda f, st: emit(progress=round(f, 4), stage=st))


def cmd_raw(s: dict[str, Any]) -> dict[str, Any]:
    return raw_lines(s["path"], float(s.get("t") or 0))


COMMANDS: dict[str, Callable[[dict[str, Any]], dict[str, Any]]] = {
    "inspect": cmd_inspect, "verify": cmd_verify, "import": cmd_import, "raw": cmd_raw}


def main() -> None:
    global _LANG
    cmd = sys.argv[1]
    settings = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8")) if len(sys.argv) > 2 else {}
    _LANG = settings.get("lang") or "de"
    t0 = time.time()
    try:
        result = COMMANDS[cmd](settings)
    except VdrError as e:
        emit(error=e.de if _LANG == "de" else e.en)
        raise SystemExit(2) from None
    except SystemExit as e:
        emit(error=str(e))
        raise SystemExit(2) from None
    result["seconds"] = round(time.time() - t0, 2)
    emit(result=result)


if __name__ == "__main__":
    main()
