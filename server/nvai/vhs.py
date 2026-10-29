"""VHS-Bereich (seit 0.5.16): digitalisierte VHS-Videos aufwerten. Nutzer 28.10.2026: „heute digitalisiere ich
VHS-Videokassetten … einen neuen Bereich, der das VHS-Video mit der KI entrauscht, stabilisiert und aufbessert“, „es
braucht nur Aufwertungswerkzeuge“.

Zwei Wege:
- klassisch (Auftrag vhs_clean, Render-Warteschlange): entflechten (bwdif), beschneiden, auf quadratische Pixel
  skalieren, entrauschen, Farbe, Flackern, stabilisieren, Ton; in einem Durchgang durch vhs_tools.py run. Schnell
  genug fuer ganze Baender (gemessen am Testclip 46 Bilder/s mit mittlerem Entrauschen, 1 h Band rund 1 h).
- mit KI (Auftrag vhs, GPU-Warteschlange): dieselbe Vorbereitung, dann SeedVR2 in Abschnitten von SEGMENT Bildern mit
  OVERLAP Bildern Ueberlappung. Je Abschnitt: vhs_tools.py segment (FFV1 in ComfyUIs input/), SeedVR2
  (workflows.seedvr2_video_graph, verlustfrei zurueck), vhs_tools.py part (mit dem Ende des vorigen ueberblenden,
  kodieren). Zum Schluss vhs_tools.py concat ohne neues Kodieren, Ton dazu. Fertige Teile bleiben im Arbeitsordner;
  derselbe Auftrag mit denselben Einstellungen setzt dort fort. Gemessen 28.10.: SeedVR2 7B 960 x 720 rund 1,1 s je
  Bild, 1440 x 1080 rund 1,9 s (1 h Band bei 25 Bildern/s: rund 26 bzw. 50 h).

Vorschau (preview=True): ein Abschnitt (Vorgabe 10 s) und daneben derselbe Abschnitt nur entflochten, zum Vergleich im
Browser (MPEG-2 und DV spielt er nicht).
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import shutil
import time
from fractions import Fraction
from pathlib import Path
from typing import Any

from . import comfy, config, db, jobs, registry, workflows
from .i18n import t
from .schemas import Job

SEGMENT = 121          # Bilder je SeedVR2-Abschnitt (4n+1)
OVERLAP = 8            # Bilder, die zwei Abschnitte teilen und weich ueberblenden
PREVIEW_SECONDS = 10.0
AI_HEIGHT = {"720": 720, "1080": 1080}
SECONDS_PER_FRAME = {"720": 1.2, "1080": 2.0, "original": 0.8}  # 7B NVFP4 samt Vorbereiten und Kodieren (720p
# gemessen 28.10.: 252 s fuer 200 Bilder; 1080p und Originalgroesse aus den Messungen ohne diesen Aufwand geschaetzt)
CLASSIC_FPS = {"off": 900.0, "light": 700.0, "medium": 46.0, "strong": 18.0}   # Bilder/s, gemessen am Testclip
CHROMA_FPS = {"clean": 40.0, "strong": 110.0}   # Farbflecken: neue Farbstufe ~38, alter Filter ~99 Bilder/s (960 x 720)
RIFE_ID = "rife-4.26"   # Takt glaetten (catalog.INTERPOLATE_MODELS)
# Takt glaetten je Eingangsbild (960 x 720): ohne KI gemessen 175 s fuer 600 Bilder samt Takt, Ton, Vorbereiten und
# Kodieren (ComfyUI je Abschnitt rund 11 s, RIFE selbst rund 30 Mitten/s); mit KI kommt es zu SeedVR2 dazu
SMOOTH_SECONDS_PER_FRAME = 0.3
SMOOTH_WITH_AI_SECONDS_PER_FRAME = 0.05  # mit KI 720p gemessen 1,29 statt 1,26 s je Bild
PREFERRED_UPSCALE = ("seedvr2-7b-nvfp4", "seedvr2-7b-int8", "seedvr2-3b-nvfp4")
# Steht im Schluessel des Arbeitsordners: Aendert sich die Aufbereitung (Filter, Umrechnung), setzt ein Auftrag nicht
# mit Teilen der alten fort. 2: Helligkeitsbereich auf Video umgerechnet; 3: Entrauschen nur Helligkeit, neue
# Farbstufe, Entblocken (28.10. abends)
PIPELINE_VERSION = 3


def _tool_path() -> Path:
    return Path(__file__).with_name("vhs_tools.py")


def source_path(asset_id: str) -> Path:
    asset = db.get_asset(asset_id)
    if asset is None:
        raise FileNotFoundError(asset_id)
    path = db.asset_file(asset.filename)
    if path is None or not path.exists():
        raise FileNotFoundError(asset.filename)
    return path


async def _run_tool(cmd: str, *args: str, ctx: jobs.JobContext | None = None, base: float = 0.0, span: float = 1.0,
                    stage: str = "") -> dict[str, Any]:
    """vhs_tools.py im ComfyUI-venv; Fortschrittszeilen gehen an ctx, die letzte Zeile ist das Ergebnis."""
    proc = await asyncio.create_subprocess_exec(
        str(comfy.comfy_python()), "-I", str(_tool_path()), cmd, *args,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    err_task = asyncio.create_task(proc.stderr.read()) if proc.stderr else None
    result: dict[str, Any] = {}
    try:
        assert proc.stdout is not None
        async for raw in proc.stdout:
            line = raw.decode(errors="replace").strip()
            if not line.startswith("{"):
                continue
            msg = json.loads(line)
            if "progress" in msg and ctx is not None:
                ctx.progress(base + span * float(msg["progress"]), stage)
            if "result" in msg:
                result = msg["result"]
            if ctx is not None and ctx.should_stop():
                proc.kill()
                raise asyncio.CancelledError
        err = (await err_task).decode(errors="replace") if err_task else ""
        if await proc.wait() != 0 or not result:
            raise RuntimeError(t(f"VHS-Werkzeug ({cmd}) fehlgeschlagen: {err[-500:]}",
                                 f"VHS tool ({cmd}) failed: {err[-500:]}"))
    finally:
        if proc.returncode is None:
            proc.kill()
    return result


async def _tool_json(cmd: str, settings: dict[str, Any], work: Path, **kw: Any) -> dict[str, Any]:
    path = work / f"{cmd}_{time.time_ns()}.json"
    path.write_text(json.dumps(settings), encoding="utf-8")
    try:
        return await _run_tool(cmd, str(path), **kw)
    finally:
        path.unlink(missing_ok=True)


# ------------------------------------------------------------------------------------------------- Analyse

async def analyze(asset_id: str) -> dict[str, Any]:
    """Format und Vorschlag fuer die Einstellungen; das Vorschaubild liegt im Asset-Ordner unter vhs/."""
    src = source_path(asset_id)
    thumbs = config.ASSET_DIR / "vhs"
    thumbs.mkdir(parents=True, exist_ok=True)
    thumb = thumbs / f"{asset_id}.jpg"
    info = await _run_tool("analyze", str(src), str(thumb))
    d = defaults(info)
    return {"asset_id": asset_id, "info": info, "defaults": d, "thumb_url": db.file_url(f"vhs/{asset_id}.jpg"),
            "estimate": estimate(info, d)}


def defaults(info: dict[str, Any]) -> dict[str, Any]:
    c = info.get("crop") or {}
    return {
        "deinterlace": "double" if info.get("interlaced") else "off",
        "parity": info.get("parity") or "auto",
        "crop": [int(c.get("left", 0)), int(c.get("top", 0)), int(c.get("right", 0)), int(c.get("bottom", 0))],
        "denoise": "light", "chroma_denoise": "clean", "sharpen": "off", "deblock": bool(info.get("blocky")),
        "chroma_shift": 0, "levels": False,
        "deflicker": False,
        "stabilize": False,
        "ai": False, "ai_size": "720", "audio_denoise": bool(info.get("audio")), "loudnorm": bool(info.get("audio")),
        "codec": "h264", "aspect": info.get("suggest_aspect") or "source", "smooth": False,
    }


def out_size(info: dict[str, Any], crop: list[int], aspect: str) -> list[int]:
    """Ausgabegroesse mit quadratischen Pixeln. PAL/NTSC: volle Bildhoehe, die Raender gelten als Overscan (wie bisher).
    Andere Dateien (Wandler mit 720p und Co.): Hoehe des beschnittenen Bildes, Seitenverhaeltnis aus dem Ausschnitt,
    damit seitliche Saeulen um ein 4:3-Bild nicht wieder in die Breite gezogen werden. aspect "4:3"/"16:9" erzwingt das
    Verhaeltnis (in die Breite gezogene Aufnahme entzerren bzw. anamorphes 16:9)."""
    w, h = int(info["width"]), int(info["height"])
    cl, ct, cr, cb = (int(v) for v in crop)
    if info.get("standard") in ("PAL", "NTSC"):
        oh = int((info.get("square_size") or [w, h])[1])
        dar = 16 / 9 if info.get("aspect") == "16:9" else 4 / 3
    else:
        sar = info.get("sar") or [1, 1]
        cw, oh = max(2, w - cl - cr), max(2, h - ct - cb)
        dar = cw * sar[0] / sar[1] / oh
    if aspect == "4:3":
        dar = 4 / 3
    elif aspect == "16:9":
        dar = 16 / 9
    return [int(round(oh * dar / 2)) * 2, oh // 2 * 2]


def estimate(info: dict[str, Any], p: dict[str, Any], seconds: float | None = None) -> dict[str, Any]:
    """Grobe Dauer aus den Messwerten (Testclip, RTX 5060 Ti): klassisch nach Bildern/s, KI nach Sekunden je Bild."""
    secs = float(seconds if seconds is not None else info.get("seconds") or 0)
    fps = Fraction(*info.get("out_fps", [25, 1]))
    if p.get("deinterlace") == "single" and info.get("interlaced"):
        fps = fps / 2
    frames = secs * float(fps)
    classic = frames / CLASSIC_FPS.get(p.get("denoise") or "off", 46.0) + (frames / 92 if p.get("stabilize") else 0) \
        + (frames / CHROMA_FPS[_chroma(p.get("chroma_denoise"))] if _chroma(p.get("chroma_denoise")) != "off" else 0)
    ai = frames * SECONDS_PER_FRAME.get(str(p.get("ai_size") or "720"), 1.1) if p.get("ai") else 0.0
    if p.get("smooth"):
        ai += frames * (SMOOTH_WITH_AI_SECONDS_PER_FRAME if p.get("ai") else SMOOTH_SECONDS_PER_FRAME)
    return {"frames": int(frames), "classic_s": round(classic), "ai_s": round(ai), "total_s": round(classic + ai)}


# ------------------------------------------------------------------------------------------------ Aufbereitung

def _settings(p: dict[str, Any], info: dict[str, Any], src: Path) -> dict[str, Any]:
    """Was vhs_tools.py braucht: Quelle, Filter, Groesse, Bildrate, Abschnitt."""
    mode = p.get("deinterlace") or "auto"
    if mode == "auto":
        mode = "double" if info.get("interlaced") else "off"
    rate = Fraction(*info["fps"])
    out_fps = rate * 2 if mode == "double" else rate
    crop = p.get("crop") if p.get("crop") is not None else defaults(info)["crop"]
    aspect = p.get("aspect") or "auto"
    if aspect == "auto":
        aspect = info.get("suggest_aspect") or "source"
    start = float(p.get("start") or 0.0)
    duration = p.get("duration")
    if p.get("preview"):
        duration = float(duration or PREVIEW_SECONDS)
    if duration is None and info.get("seconds"):
        duration = max(0.0, float(info["seconds"]) - start)
    return {
        "src": str(src), "start": start, "duration": duration, "info": info,
        "deinterlace": mode, "parity": p.get("parity") if p.get("parity") not in (None, "auto") else info.get("parity", "auto"),
        "crop": [int(v) for v in crop], "aspect": aspect, "size": out_size(info, [int(v) for v in crop], aspect),
        "out_fps": [out_fps.numerator, out_fps.denominator],
        "denoise": p.get("denoise") or "off", "chroma_denoise": _chroma(p.get("chroma_denoise")),
        "deblock": bool(p.get("deblock")),
        "sharpen": p.get("sharpen") or "off",
        "chroma_shift": int(p.get("chroma_shift") or 0),
        "levels": bool(p.get("levels")), "deflicker": bool(p.get("deflicker")), "stabilize": bool(p.get("stabilize")),
        "audio_denoise": bool(p.get("audio_denoise")), "loudnorm": bool(p.get("loudnorm")), "loudness": -16.0,
        "codec": p.get("codec") or "h264", "smooth": bool(p.get("smooth")),
    }


def _chroma(v: Any) -> str:
    """Farbflecken wie vhs_tools.chroma_mode: True/clean = neue Farbstufe, strong = Filter vom 28.10. nachmittags."""
    if v is True:
        return "clean"
    return v if v in ("clean", "strong") else "off"


def ai_size(square: list[int], choice: str) -> tuple[int, int]:
    """Zielgroesse fuer SeedVR2 im Seitenverhaeltnis der quadratischen Pixel, Vielfache von 16."""
    w, h = square
    if choice not in AI_HEIGHT:
        return w // 16 * 16, h // 16 * 16
    th = AI_HEIGHT[choice]
    tw = int(round(w * th / h / 16)) * 16
    return tw, th


def _label(s: dict[str, Any], ai: dict[str, Any] | None) -> str:
    steps = []
    if s["deinterlace"] != "off":
        steps.append(t("entflochten", "deinterlaced"))
    if s.get("aspect") in ("4:3", "16:9") and s["aspect"] != (s.get("info") or {}).get("aspect"):
        steps.append(t(f"auf {s['aspect']} entzerrt", f"corrected to {s['aspect']}"))
    if s["denoise"] != "off":
        steps.append(t("entrauscht", "denoised"))
    if s.get("deblock"):
        steps.append(t("entblockt", "deblocked"))
    if s.get("chroma_denoise") == "strong":
        steps.append(t("Farbflecken kräftig gemindert", "color blotches strongly reduced"))
    elif s.get("chroma_denoise") not in (None, False, "off"):
        steps.append(t("Farbflecken gemindert", "color blotches reduced"))
    if s.get("sharpen") not in (None, "off"):
        steps.append(t("nachgeschärft", "sharpened"))
    if s["stabilize"]:
        steps.append(t("stabilisiert", "stabilized"))
    if s["chroma_shift"] or s["levels"] or s["deflicker"]:
        steps.append(t("Farbe korrigiert", "color corrected"))
    if ai:
        steps.append(t(f"mit KI aufgebessert ({ai['height']}p)", f"enhanced with AI ({ai['height']}p)"))
    if s.get("smooth"):
        steps.append(t("Takt auf 50 Bilder/s geglättet", "cadence smoothed to 50 fps"))
    return "VHS " + (", ".join(steps) or t("aufbereitet", "processed"))


def _work_dir(p: dict[str, Any], s: dict[str, Any], extra: dict[str, Any]) -> Path:
    key = json.dumps({"asset": p.get("asset_id"), "s": {k: v for k, v in s.items() if k != "info"}, **extra,
                      "v": PIPELINE_VERSION}, sort_keys=True)
    d = config.DATA_DIR / "tmp" / "vhs" / hashlib.sha1(key.encode()).hexdigest()[:16]
    d.mkdir(parents=True, exist_ok=True)
    return d


async def _info(p: dict[str, Any], src: Path) -> dict[str, Any]:
    if p.get("info"):
        return p["info"]
    thumbs = config.ASSET_DIR / "vhs"
    thumbs.mkdir(parents=True, exist_ok=True)
    return await _run_tool("analyze", str(src), str(thumbs / f"{p['asset_id']}.jpg"))


async def _before(s: dict[str, Any], work: Path, ctx: jobs.JobContext, base: float, span: float) -> str | None:
    """Vergleichsclip der Vorschau: derselbe Abschnitt nur entflochten und skaliert, mit dem Originalton."""
    plain = {**s, "denoise": "off", "chroma_denoise": False, "deblock": False, "chroma_shift": 0, "levels": False,
             "deflicker": False,
             "stabilize": False, "sharpen": "off", "audio_denoise": False, "loudnorm": False}
    name = f"vhs_{db.new_id('cmp')}.before.mp4"
    out = config.ASSET_DIR / name
    await _tool_json("run", {**plain, "out": str(out), "audio_out": str(work / "before.wav")}, work, ctx=ctx,
                     base=base, span=span, stage=t("Vergleich: nur entflochten", "comparison: deinterlaced only"))
    return name if out.exists() else None


@jobs.register("vhs_clean")
async def _clean(job: Job, ctx: jobs.JobContext) -> list[str]:
    """Klassisch: alles in einem Durchgang."""
    p = job.params
    src = source_path(p["asset_id"])
    info = await _info(p, src)
    s = _settings(p, info, src)
    work = _work_dir(p, s, {"kind": "clean"})
    stem = db.new_id("vhs")
    name = f"{stem}.mp4"
    t0 = time.time()
    try:
        before = await _before(s, work, ctx, 0.0, 0.1) if p.get("preview") else None
        base = 0.1 if p.get("preview") else 0.0
        result = await _tool_json("run", {**s, "out": str(config.ASSET_DIR / name), "audio_out": str(work / "audio.wav")},
                                  work, ctx=ctx, base=base, span=0.99 - base, stage=t("bereitet auf", "processing"))
    finally:
        shutil.rmtree(work, ignore_errors=True)
    meta = {"vhs": {k: v for k, v in s.items() if k not in ("info", "src")}, "source_asset_id": p["asset_id"],
            "vhs_info": info, "result": result, "seconds_taken": round(time.time() - t0, 1),
            "width": result.get("width"), "height": result.get("height"), "fps": result.get("fps"),
            "seconds": result.get("seconds"), "preview_clip": bool(p.get("preview"))}
    if before:
        meta["vhs_before"] = before
    asset = db.create_asset(kind="video", filename=name, job_id=job.id, prompt=_label(s, None), meta=meta)
    return [asset.id]


def _upscale_entry(p: dict[str, Any]) -> dict[str, Any]:
    if p.get("upscale_model_id"):
        return jobs._resolve_model({"model_id": p["upscale_model_id"]}, "upscale")
    for mid in PREFERRED_UPSCALE:
        entry = registry.get_entry(mid)
        if entry and registry.is_installed(entry):
            return entry
    return jobs._resolve_model({}, "upscale")


def rife_installed() -> bool:
    entry = registry.get_entry(RIFE_ID)
    return bool(entry and registry.is_installed(entry))


def smooth_applies(info: dict[str, Any]) -> bool:
    """Takt glaetten passt nur zu progressiven 30-fps-Aufnahmen eines 50-Hz-Bandes (Analyse: cadence 50to30)."""
    return not info.get("interlaced") and (info.get("cadence") or {}).get("kind") == "50to30"


def _selection(first: int, count: int, short: str, cut: str, last: bool) -> tuple[list[int], int | None]:
    """Welche Bilder aus der RIFE-Ausgabe eines Abschnitts (Original j an 2j, Mitte zwischen j und j+1 an 2j+1) bleiben:
    alle Originale und die Mitten der langen Schritte (40 ms), an einem Schnitt statt der Mitte das Bild davor. Dazu
    die Ausgabestelle, an der die Ueberlappung zum naechsten Abschnitt beginnt (dessen erste OVERLAP Eingangsbilder)."""
    select: list[int] = []
    starts: list[int] = []
    for j in range(count):
        starts.append(len(select))
        select.append(2 * j)
        g = first + j
        if j < count - 1 and g < len(short) and short[g] == "0":
            select.append(2 * j if cut[g:g + 1] == "1" else 2 * j + 1)
    return select, (None if last else starts[count - OVERLAP])


@jobs.register("vhs")
async def _ai(job: Job, ctx: jobs.JobContext) -> list[str]:
    """Mit KI und/oder Takt glaetten: klassisch vorbereiten, je Abschnitt SeedVR2 (und RIFE), Teile ueberblenden und
    aneinanderhaengen."""
    p = job.params
    src = source_path(p["asset_id"])
    info = await _info(p, src)
    s = _settings(p, info, src)
    use_ai, smooth = bool(p.get("ai")), bool(s.get("smooth"))
    if smooth and not smooth_applies(info):
        raise RuntimeError(t("„Takt glätten“ passt nur zu Aufnahmen, die ein 50-Hz-Band mit 30 Bildern/s aufgenommen "
                             "haben (die Analyse meldet das).",
                             "“Smooth cadence” only fits recordings of a 50 Hz tape made at 30 fps (the analysis "
                             "reports it)."))
    entry = _upscale_entry(p) if use_ai else None
    if entry and entry.get("workflow") not in workflows.UPSCALE_WORKFLOWS:
        raise RuntimeError(t(f"'{entry.get('name', entry['id'])}' ist kein Modell zum Aufbessern.",
                             f"'{entry.get('name', entry['id'])}' is not a model for enhancing."))
    rife = None
    if smooth:
        if not rife_installed():
            raise RuntimeError(t("Für „Takt glätten“ fehlt RIFE 4.26 (23 MB): im Reiter VHS oder unter „Modelle“ laden.",
                                 "“Smooth cadence” needs RIFE 4.26 (23 MB): download it in the VHS tab or under “Models”."))
        rife = Path(registry.get_entry(RIFE_ID)["files"][0]["file"]).name
    tw, th = ai_size(s["size"], str(p.get("ai_size") or "720")) if use_ai else tuple(int(v) for v in s["size"])
    chunk = int(p.get("frames_per_chunk") or 1)
    fps = Fraction(*s["out_fps"])                  # Takt der aufbereiteten Folge
    final_fps = fps * 5 / 3 if smooth else fps     # 30 -> 50: auf 3 Bilder kommen 2 Mitten
    total = int(round(float(s["duration"] or 0) * float(fps)))
    if total < 2:
        raise RuntimeError(t("Der Abschnitt ist zu kurz.", "The section is too short."))
    # Fester Seed als Vorgabe: Er steckt im Schluessel des Arbeitsordners, ein neuer Lauf mit denselben Einstellungen
    # setzt so nach einem Abbruch fort; SeedVR2 haengt kaum vom Seed ab (ein Schritt).
    seed = int(p["seed"]) if p.get("seed") is not None else 42
    work = _work_dir(p, s, {"kind": "ai" if use_ai else "smooth", "model": entry["id"] if entry else None,
                            "size": [tw, th], "chunk": chunk, "seed": seed, "rife": rife})
    await jobs._ensure_backend(ctx)
    t0 = time.time()
    before = await _before(s, work, ctx, 0.0, 0.02) if p.get("preview") else None
    audio_wav = work / "audio.wav"
    has_audio = False
    if info.get("audio"):
        a = await _tool_json("audio", {**s, "audio_out": str(audio_wav)}, work)
        has_audio = bool(a.get("audio"))
    short = cut = ""
    cadence: dict[str, Any] = {}
    if smooth:
        cad_path = work / "cadence.json"
        if cad_path.exists():
            cadence = json.loads(cad_path.read_text(encoding="utf-8"))
        else:
            ctx.progress(0.02, t("misst den Takt", "measuring the cadence"))
            cadence = await _tool_json("cadence", s, work)
            cad_path.write_text(json.dumps(cadence), encoding="utf-8")
        short, cut = cadence.get("short", ""), cadence.get("cut", "")
    firsts = []
    first = 0
    while True:
        firsts.append(first)
        if first + SEGMENT >= total:
            break
        first += SEGMENT - OVERLAP
    parts: list[str] = []
    comfy_in = config.COMFY_ROOT / "input"
    comfy_in.mkdir(parents=True, exist_ok=True)
    seg_times: list[float] = []
    seg_frames: list[int] = []      # nur in diesem Lauf gerechnete Abschnitte (fortgesetzt: ohne die fertigen)
    for i, first in enumerate(firsts):
        last = i == len(firsts) - 1
        count = min(SEGMENT, total - first)
        part_path = work / f"part_{i:05d}.mp4"
        tail_out = work / f"tail_{i:05d}.mkv"
        tail_in = work / f"tail_{i - 1:05d}.mkv" if i else None
        parts.append(str(part_path))
        if part_path.exists() and (last or tail_out.exists()):
            continue                                   # schon fertig (fortgesetzter Auftrag)
        if ctx.should_stop():
            raise asyncio.CancelledError
        ts = time.time()
        done_before = i / len(firsts)
        left = ""
        if seg_times:
            remaining = (len(firsts) - i) * (sum(seg_times[-5:]) / len(seg_times[-5:]))
            left = t(f" · noch etwa {remaining / 60:.0f} min", f" · about {remaining / 60:.0f} min left")
        stage = t(f"Abschnitt {i + 1} von {len(firsts)}{left}", f"section {i + 1} of {len(firsts)}{left}")
        ctx.progress(0.03 + 0.94 * done_before, stage)
        seg_name = f"nvai_vhs_{job.id}_{i:05d}.mkv"
        seg_file = comfy_in / seg_name
        masters: list[Path] = []
        try:
            await _tool_json("segment", {**s, "first": first, "count": count, "out": str(seg_file)}, work)
            if entry:
                graph = workflows.seedvr2_video_graph(entry, seg_name, tw, th, float(fps), seed, chunk)
                if rife:
                    graph = workflows.add_interpolation(graph, rife)
            else:
                graph = workflows.interpolate_video_graph(seg_name, float(fps), str(rife))
            select, tail_from = _selection(first, count, short, cut, last) if rife else (None, None)

            def on_progress(frac: float, step: str, _i: int = i) -> None:
                ctx.progress(0.03 + 0.94 * (_i + 0.9 * frac) / len(firsts), stage)

            await comfy.run_workflow(graph, on_progress=on_progress, timeout=3600.0, masters=masters)
            if not masters:
                raise RuntimeError(t("ComfyUI lieferte kein Video zurück.", "ComfyUI returned no video."))
            await _tool_json("part", {"src": str(masters[0]), "tail_in": str(tail_in) if tail_in else None,
                                      "tail_out": str(tail_out), "overlap": OVERLAP, "last": last,
                                      "select": select, "tail_from": tail_from,
                                      "out": str(part_path), "out_fps": [final_fps.numerator, final_fps.denominator],
                                      "codec": s["codec"]}, work)
        finally:
            seg_file.unlink(missing_ok=True)
            for m in masters:
                m.unlink(missing_ok=True)
        if tail_in:
            tail_in.unlink(missing_ok=True)
        seg_times.append(time.time() - ts)
        seg_frames.append(count)
    ctx.progress(0.98, t("setzt zusammen", "joining"))
    stem = db.new_id("vhs")
    name = f"{stem}.mp4"
    out = config.ASSET_DIR / name
    await _tool_json("concat", {"parts": parts, "out": str(out), "audio_out": str(audio_wav) if has_audio else None},
                     work)
    took = round(time.time() - t0, 1)
    shutil.rmtree(work, ignore_errors=True)
    spf = round(sum(seg_times) / sum(seg_frames), 2) if seg_frames else None
    ai = ({"model_id": entry["id"], "width": tw, "height": th, "frames_per_chunk": chunk, "seed": seed,
           "segments": len(firsts), "resumed": len(firsts) - len(seg_times), "seconds_per_frame": spf}
          if entry else None)
    meta = {"vhs": {k: v for k, v in s.items() if k not in ("info", "src")}, "vhs_ai": ai, "source_asset_id": p["asset_id"],
            "vhs_info": info, "seconds_taken": took, "width": tw, "height": th, "fps": float(final_fps),
            "seconds": round(total / float(fps), 3), "preview_clip": bool(p.get("preview"))}
    if rife:
        meta["vhs_smooth"] = {"model": rife, "frames_in": total, "fps_in": float(fps), "fps": float(final_fps),
                              "cuts": cadence.get("cuts"), "phases": cadence.get("phases"), "sure": cadence.get("sure"),
                              "seconds_per_frame": spf if not entry else None}
    if before:
        meta["vhs_before"] = before
    asset = db.create_asset(kind="video", filename=name, job_id=job.id, prompt=_label(s, ai),
                            model_id=entry["id"] if entry else (RIFE_ID if rife else ""), meta=meta)
    return [asset.id]


async def submit(p: dict[str, Any]) -> Job:
    return await jobs.submit("vhs" if p.get("ai") or p.get("smooth") else "vhs_clean", p)
