"""Ton-Forensik (seit 17.11.2026 abends; Nutzer: „Ton wird zum Ton Forensik Tool, es braucht ähnlich wie in dem Studio
unterschiedliche tracks mit unterschiedlichen spuren (waveform) dann spuren für die Forensik, und tools die mann
braucht eben. dann auch eine Spur für die Übersetzer KI …“).

Baut auf audio_lab.py auf (Projekte, Spuren, Aufträge) und ergänzt die Spuren der Forensik:
- Spektrogramm je Spur in vier Auflösungen (forensic_tools.py spectro), per Range-Anfrage abschnittsweise geladen,
- Sprachaktivität je Spur (aus demselben Durchgang, ohne KI; mit Silero VAD genauer),
- Transkript mit Übersetzung (data/transcript.json): Blöcke mit Original, Übersetzung je Zielsprache, Sprecher,
  Spur, Sicherheit und Prüfstand („Entwurf“ der KI oder „geprüft“).
Kundenaufnahmen bleiben lokal; nichts davon geht an fremde Dienste.
"""
from __future__ import annotations

import asyncio
import contextlib
import hashlib
import json
import re
import time
import uuid
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Request
from fastapi.responses import FileResponse, Response
from pydantic import BaseModel, Field

from . import audio_lab as al
from . import db, jobs
from .i18n import t
from .schemas import Job

TOOL = Path(__file__).with_name("forensic_tools.py")
SPEC_FILES = {"0": ".spec", "1": ".spec1", "2": ".spec2", "3": ".spec3", "act": ".act", "vad": ".vad"}
SEG_KINDS = ("speech", "radio", "sound", "note")
PLAN_VERSION = 2  # 2: Abschnitte wechseln die Spur, wenn ein anderes Mikrofon 2 s klar vorn liegt (17.11.)
WORDS_VERSION = 2  # 2: Ampel aus Whispers Sicherheit, Zweitmeinung lateinisch und unscharf verglichen (17.11.)
MAX_SEGMENTS = 20000


def _spec_base(pid: str, tid: str) -> Path:
    return al.ROOT / pid / "spec" / tid


def _data_dir(pid: str) -> Path:
    d = al.ROOT / pid / "data"
    d.mkdir(parents=True, exist_ok=True)
    return d


# ------------------------------------------------------------------------------------------- Spektrogramm

async def submit_spectro(pid: str, tid: str) -> Job:
    p = al.load(pid)
    if p.get("status") != "ready":
        raise al.AudioError(t("Das Projekt ist noch nicht eingelesen.", "The project has not been read yet."))
    al._track(p, tid)
    busy = [j for j in db.list_jobs(limit=200, active=True)
            if j.kind == "audio_spectro" and (j.params or {}).get("project_id") == pid and j.params.get("track") == tid]
    if busy:
        return busy[0]
    return await jobs.submit("audio_spectro", {"project_id": pid, "track": tid})


async def _spectro(job: Job, ctx: jobs.JobContext) -> list[str]:
    await _compute_spectro(job.params["project_id"], job.params["track"], ctx, 0.0, 1.0)
    return []


async def _compute_spectro(pid: str, tid: str, ctx: jobs.JobContext, base_p: float, span: float) -> None:
    """Spektrogramm und grobe Sprachaktivität einer Spur rechnen und im Projekt eintragen."""
    src = al._track_paths(pid, tid)["flac"]
    base = _spec_base(pid, tid)
    res = await al._run_tool("spectro", {"src": src, "out": str(base)}, ctx, base_p, span, t("Spektrogramm", "spectrogram"),
                             tool=TOOL)
    act = res.get("activity") or {}
    (_data_dir(pid) / f"act_{tid}.json").write_text(json.dumps({"track": tid, **act}), encoding="utf-8")

    def fn(q: dict[str, Any]) -> None:
        tr = al._track(q, tid)
        tr["spec"] = {k: res[k] for k in ("bins", "hop", "sr", "fmax", "levels")}
        tr["activity"] = {"method": act.get("method"), "rate": act.get("rate"), "segments": len(act.get("segments") or []),
                          "speech_seconds": act.get("speech_seconds")}
        q["history"].append({"time": time.time(), "op": "spectro", "label": t(f"Spektrogramm: {tr['name']}",
                                                                           f"Spectrogram: {tr['name']}"),
                             "seconds": res.get("seconds"), "track": tid})
    al.update(pid, fn)


# ------------------------------------------------------------------------------------------- Sprache finden

def _installed(model_id: str) -> bool:
    try:
        return al.model_installed(al.manifest(model_id))
    except LookupError:
        return False


def vad_ready() -> bool:
    return al.model_installed(al.manifest("silero_vad"))


async def _compute_vad(pid: str, tids: list[str], ctx: jobs.JobContext, base_p: float, span: float) -> None:
    """Silero-Sprachkarte (je 0,1 s) für die Spuren rechnen und eintragen (Prozessor, ~45 s je Stunde und Kanal)."""
    if not tids:
        return
    for tid in tids:
        _spec_base(pid, tid).parent.mkdir(parents=True, exist_ok=True)
    res = await al._run_tool("vadmap", {"vad_dir": str(al.MODELS_DIR / "silero_vad"),
                                        "tracks": [{"id": tid, "file": al._track_paths(pid, tid)["flac"],
                                                    "out": str(_spec_base(pid, tid).with_suffix(".vad"))} for tid in tids]},
                             ctx, base_p, span, t("Sprache finden", "finding speech"), tool=TOOL)

    def fn(q: dict[str, Any]) -> None:
        for tid, r in (res.get("tracks") or {}).items():
            tr = al._track(q, tid)
            tr["vad"] = {"method": "silero", "rate": 10, "speech_seconds": r.get("speech_seconds"), "time": time.time()}
        q["history"].append({"time": time.time(), "op": "vad", "seconds": res.get("seconds"),
                             "label": t(f"Sprache finden (Silero VAD) in {len(tids)} Spuren",
                                        f"Find speech (Silero VAD) in {len(tids)} tracks")})
    al.update(pid, fn)


async def submit_vad(pid: str, tids: list[str]) -> Job:
    p = al.load(pid)
    if p.get("status") != "ready":
        raise al.AudioError(t("Das Projekt ist noch nicht eingelesen.", "The project has not been read yet."))
    if not vad_ready():
        raise al.AudioError(t("Erst Silero VAD laden (Modelle und Einrichten, 2 MB).", "Download Silero VAD first (Models and setup, 2 MB)."))
    tracks = [al._track(p, tid) for tid in tids] or [x for x in p["tracks"] if x.get("kind") == "original"]
    return await jobs.submit("audio_vad", {"project_id": pid, "tracks": [x["id"] for x in tracks if not x.get("offset")]})


async def _vad(job: Job, ctx: jobs.JobContext) -> list[str]:
    await _compute_vad(job.params["project_id"], job.params["tracks"], ctx, 0.0, 1.0)
    return []


# ------------------------------------------------------------------------------- Übersetzer-Spur (KI-Entwurf)

ASR_MODEL = "whisper_large_v3"
# Übersetzen mit Qwen3.5-9B (Apache-2.0), dem Text-Encoder von MOSS-Image, über ComfyUIs TextGenerate (gierig). Der
# Upsampler von FLUX 3 ist zwar auch ein Qwen3.5-9B, aber auf Bildbeschreibungen nachtrainiert (Recherche 17.11.).
TEXT_ENCODER = "qwen3.5_9b_w4a8_gptq.safetensors"
# Hinweis bei der Übersetzung (Nutzer 18.11.2026: „bei der übersetzung soll ein hinweiss stehen, mit welchem model auf
# lokaler hardware unter welcher lizenz wurden die berechnet“): Modell, Hersteller und Lizenz je Aufgabe aus den
# Manifesten, dazu Grafikkarte und Programmstand je Lauf (seit 18.11. im Lauf-Eintrag; bei älteren Läufen die Karte des
# Auswerte-Rechners, als solche gekennzeichnet).
TRANSLATOR_INFO = {"id": TEXT_ENCODER, "name": "Qwen3.5-9B W4A8", "by": "Alibaba Qwen", "license": "Apache-2.0",
                   "license_url": "https://www.apache.org/licenses/LICENSE-2.0"}
MODEL_NAMES = {"whisper_large_v3": ("Whisper large-v3", "OpenAI"), "omnilingual_ctc1b": ("Omnilingual ASR CTC 1B v2", "Meta"),
               "silero_vad": ("Silero VAD", "Silero")}
LANG_NAMES = {"tl": "Tagalog/Filipino", "ceb": "Cebuano", "en": "English", "de": "German", "es": "Spanish", "fr": "French",
              "it": "Italian", "nl": "Dutch", "pl": "Polish", "ru": "Russian", "uk": "Ukrainian", "zh": "Chinese",
              "ja": "Japanese", "ko": "Korean", "id": "Indonesian", "vi": "Vietnamese", "hi": "Hindi", "tr": "Turkish"}
TRANSLATE_RULES = (
    "Rules: Every line must come out in the target language; never return a line unchanged in the source language. "
    "Translate faithfully and literally for a legal review: do not add, omit, summarise, explain or correct anything. "
    "Only words that are already in the target language, names, numbers, courses, headings, positions, times and "
    "standard nautical orders (e.g. 'midships', 'hard a port') stay as they are. If a word is unclear, translate the "
    "rest and write that word as [?word?]. Keep markers such as [unintelligible], [?word?], //overlap// and [sound] "
    "unchanged. Answer with exactly one line per input line, each starting with its number and a full stop, the same "
    "numbers in the same order, and nothing else.")
# Beispiele aus dem Alltag an Bord, frei erfunden (keine Inhalte aus Aufnahmen); ohne sie kopierte Qwen3.5-9B viele
# Tagalog-Zeilen unverändert in die Antwort (Test 17.11.). Nummerierte Zeilen statt JSON: Bei JSON fehlten in der
# Probe oft Einträge, die Halbierungen machten aus 38 Aufrufen 124 und aus 4 min 25 min (17.11. abends).
EXAMPLES_EN = [
    ("Sige, sige.", "Okay, okay."),
    ("Bakit ba? Hindi pwede.", "Why? That is not allowed."),
    ("Dahan-dahan lang, kapitan.", "Slowly, just slowly, captain."),
    ("Nasaan na yung barko sa kanan?", "Where is the ship on the right now?"),
    ("Hard port na, bilisan mo!", "Hard port now, hurry up!"),
    ("Opo, sir, naka-standby na po ang makina.", "Yes, sir, the engine is on standby now, sir."),
]
EXAMPLES_TARGET = {
    "de": [("Sige, sige.", "Okay, okay.", "Okay, okay."),
           ("Bakit ba? Hindi pwede.", "Why? That is not allowed.", "Warum denn? Das geht nicht."),
           ("Hard port na, bilisan mo!", "Hard port now, hurry up!", "Jetzt hart Backbord, beeil dich!"),
           ("Opo, sir, naka-standby na po ang makina.", "Yes, sir, the engine is on standby now, sir.",
            "Jawohl, Sir, die Maschine ist jetzt in Bereitschaft, Sir.")],
}


def _one_line(text: str) -> str:
    return " ".join((text or "").split())


def _sys_en(src_name: str) -> str:
    ex_in = "\n".join(f"{i + 1}. {a}" for i, (a, _) in enumerate(EXAMPLES_EN))
    ex_out = "\n".join(f"{i + 1}. {b}" for i, (_, b) in enumerate(EXAMPLES_EN))
    return ("You are a court interpreter. You translate transcripts of ship-bridge audio recordings (seafarers speaking "
            + src_name + ", often mixed with English and maritime orders) into English. The input is a numbered list "
            "of lines. " + TRANSLATE_RULES + "\nExample input:\n" + ex_in + "\nExample answer:\n" + ex_out)


def _sys_target(src_name: str, tgt_name: str, target: str) -> str:
    ex = EXAMPLES_TARGET.get(target, [])
    ex_in = "\n".join(f"{i + 1}. {a} || EN: {b}" for i, (a, b, _) in enumerate(ex))
    ex_out = "\n".join(f"{i + 1}. {c}" for i, (_, _, c) in enumerate(ex))
    return ("You are a court interpreter. You translate transcripts of ship-bridge audio recordings (seafarers speaking "
            + src_name + ", often mixed with English and maritime orders) into " + tgt_name + ". The input is a "
            "numbered list; each line holds the original, then after \"|| EN:\" an English draft translation. Translate "
            "the original into " + tgt_name + "; use the English draft to understand it, but where the draft differs "
            "from the original, the original counts. " + TRANSLATE_RULES
            + (("\nExample input:\n" + ex_in + "\nExample answer:\n" + ex_out) if ex else ""))


def _translate_graph(system: str, user: str, max_tokens: int = 1024) -> dict[str, Any]:
    return {
        "1": {"class_type": "CLIPLoader", "inputs": {"clip_name": TEXT_ENCODER, "type": "moss_image", "device": "default"}},
        "2": {"class_type": "PrimitiveStringMultiline", "inputs": {"value": system}},
        "3": {"class_type": "TextGenerate", "inputs": {
            "clip": ["1", 0], "prompt": user, "max_length": int(max_tokens), "sampling_mode": "off", "thinking": False,
            "use_default_template": True, "mtp": "auto", "system_prompt": ["2", 0]}},
        "4": {"class_type": "PreviewAny", "inputs": {"source": ["3", 0]}},
    }


# Schleifen des Übersetzers (18.11.: drei deutsche Zeilen mit 2139 bis 2913 Zeichen ohne Leerzeichen, alle bei Blöcken,
# die Whisper schon als Wiederholung markiert hatte; die Liste der Übersetzer-Spur wurde davon 15 841 px breit)
_LOOP = re.compile(r"(.{1,24}?)\1{4,}", re.S)


def _tame(src: str, out: str) -> tuple[str, bool]:
    """Übersetzung kürzen, wenn das Modell in eine Schleife lief: Muster, die sich mehr als viermal am Stück wiederholen,
    bleiben dreimal stehen, dann „…“; danach höchstens viermal so lang wie das Original (plus 120 Zeichen). Normale
    Zeilen bleiben unberührt. Ergebnis: Text und ob gekürzt wurde."""
    if not out:
        return out, False
    limit = 4 * len(src or "") + 120
    if len(out) <= limit and max((len(w) for w in out.split()), default=0) <= 60:
        return out, False
    new = out
    for _ in range(3):
        cut = _LOOP.sub(lambda m: m.group(1) * 3 + "…", new)
        if cut == new:
            break
        new = cut
    if len(new) > limit:
        new = new[:limit].rstrip() + " …"
    return new, new != out


def _parse_lines(text: str) -> dict[int, str]:
    out: dict[int, str] = {}
    for line in (text or "").splitlines():
        m = re.match(r"^\s*(\d{1,3})\s*[.):\]]\s*(.*\S)?\s*$", line)
        if m:
            out.setdefault(int(m.group(1)), (m.group(2) or "").strip())
    return out


async def _llm_lines(system: str, lines: list[str]) -> list[str]:
    """Ein Stapel nummerierter Zeilen an das Sprachmodell; fehlende Zeilen werden einmal einzeln nachgefragt."""
    from . import comfy
    user = "\n".join(f"{i + 1}. {_one_line(x)}" for i, x in enumerate(lines))
    budget = min(2048, 96 + sum(len(x) for x in lines) // 2 + 24 * len(lines))
    texts = await comfy.run_text_workflow(_translate_graph(system, user, budget))
    got = _parse_lines(texts[-1] if texts else "")
    out = [got.get(i + 1, "") for i in range(len(lines))]
    if len(lines) > 1:
        for i, x in enumerate(lines):
            if not out[i]:
                texts = await comfy.run_text_workflow(_translate_graph(system, f"1. {_one_line(x)}", 96 + len(x)))
                out[i] = _parse_lines(texts[-1] if texts else "").get(1, "")
    return out


async def _translate(segs: list[dict[str, Any]], source: str, target: str, ctx: jobs.JobContext, base_p: float,
                     span: float) -> None:
    """Übersetzen in zwei Stufen (Recherche 17.11.: Paare ohne Englisch sind schwächer): erst nach Englisch, dann aus
    dem Original in die Zielsprache mit dem englischen Entwurf als Hilfe. Ergebnis in seg["translation"]."""
    src_name = LANG_NAMES.get(source, "Tagalog/Filipino (mixed with English)") if source not in ("", "auto") else \
        "Tagalog/Filipino (mixed with English)"
    tgt_name = LANG_NAMES.get(target, target)
    todo = [s for s in segs if s.get("text")]
    if not todo:
        return
    batch = 12
    stages = 1 if target == "en" else 2
    sys_en = _sys_en(src_name)
    done = 0
    total = len(todo) * stages
    for i in range(0, len(todo), batch):
        part = todo[i:i + batch]
        need = [s for s in part if s.get("lang") != "en"]
        res = await _llm_lines(sys_en, [s["text"] for s in need]) if need else []
        by_id = {s["id"]: r for s, r in zip(need, res)}
        for s in part:
            en, cut = _tame(s["text"], s["text"] if s.get("lang") == "en" else by_id.get(s["id"], ""))
            s.setdefault("translation", {})["en"] = en
            if cut and "repetition" not in s.setdefault("flags", []):
                s["flags"].append("repetition")
        done += len(part)
        ctx.progress(base_p + span * done / total, t(f"übersetzen nach Englisch {min(done, len(todo))}/{len(todo)}",
                                                     f"translating to English {min(done, len(todo))}/{len(todo)}"))
        if ctx.should_stop():
            raise asyncio.CancelledError
    if stages == 2:
        sys_tgt = _sys_target(src_name, tgt_name, target)
        for i in range(0, len(todo), batch):
            part = todo[i:i + batch]
            res = await _llm_lines(sys_tgt, [f"{s['text']} || EN: {s['translation'].get('en', '')}" for s in part])
            for s, r in zip(part, res):
                r, cut = _tame(s["text"], r)
                s["translation"][target] = r
                if cut and "repetition" not in s.setdefault("flags", []):
                    s["flags"].append("repetition")
            # Zeilen, die das Modell nur kopiert hat, einzeln nachfragen; bleibt es dabei: Vermerk „nicht übersetzt“
            for s in part:
                if s.get("lang") != target and len(s["text"].split()) > 1 and \
                        s["translation"].get(target, "").strip().lower() == s["text"].strip().lower():
                    again = _tame(s["text"], (await _llm_lines(sys_tgt, [f"{s['text']} || EN: {s['translation'].get('en', '')}"]))[0])[0]
                    if again and again.strip().lower() != s["text"].strip().lower():
                        s["translation"][target] = again
                    else:
                        s["translation"][target] = ""
                        s.setdefault("flags", []).append("untranslated")
            done += len(part)
            ctx.progress(base_p + span * done / total, t(f"übersetzen nach {tgt_name} {done - len(todo)}/{len(todo)}",
                                                         f"translating to {tgt_name} {done - len(todo)}/{len(todo)}"))
            if ctx.should_stop():
                raise asyncio.CancelledError


async def submit_transcribe(pid: str, req: dict[str, Any]) -> Job:
    p = al.load(pid)
    if p.get("status") != "ready":
        raise al.AudioError(t("Das Projekt ist noch nicht eingelesen.", "The project has not been read yet."))
    m = al.manifest(ASR_MODEL)
    if not al.model_installed(m):
        raise al.AudioError(t(f"„{m['label_de']}“ ist noch nicht geladen (Modelle und Einrichten).",
                              f"“{m['label_en']}” is not downloaded yet (Models and setup)."))
    tracks = [al._track(p, tid) for tid in (req.get("tracks") or [])]
    if not tracks:
        raise al.AudioError(t("Mindestens eine Spur wählen.", "Choose at least one track."))
    if any(x.get("offset") for x in tracks):
        raise al.AudioError(t("Vorschau-Spuren lassen sich nicht transkribieren.", "Preview tracks cannot be transcribed."))
    region = req.get("region")
    if region:
        a, b = sorted(float(x) for x in region[:2])
        region = [max(0.0, a), b]
    # Feste Spur (Nutzer 17.11.): genau diese Spur für den Bereich, KI-Entwürfe der übrigen Mikrofone dort ersetzen
    force = bool(req.get("force"))
    if force and len(tracks) != 1:
        raise al.AudioError(t("Für eine feste Spur genau eine Spur wählen.", "Choose exactly one track for a fixed track."))
    if force and not region:
        raise al.AudioError(t("Eine feste Spur gilt für einen markierten Bereich: erst im Zeitstrahl ziehen.",
                              "A fixed track applies to a marked range: drag in the timeline first."))
    return await jobs.submit("audio_transcribe", {
        "project_id": pid, "tracks": [x["id"] for x in tracks], "region": region, "force": force,
        "source_lang": str(req.get("source_lang") or "tl")[:12], "target_lang": str(req.get("target_lang") or "de")[:12],
        "translate": bool(req.get("translate", True))})


async def _transcribe(job: Job, ctx: jobs.JobContext) -> list[str]:
    pid = job.params["project_id"]
    prm = job.params
    p = al.load(pid)
    tids = prm["tracks"]
    # 1. Sprachkarte (Silero) für Spuren ohne; ohne Silero die grobe Aktivität aus dem Spektrogramm-Durchgang
    if vad_ready():
        await _compute_vad(pid, [tid for tid in tids if not _spec_base(pid, tid).with_suffix(".vad").exists()], ctx, 0.0, 0.1)
    else:
        missing = [tid for tid in tids if not _spec_base(pid, tid).with_suffix(".act").exists()]
        for k, tid in enumerate(missing):
            await _compute_spectro(pid, tid, ctx, 0.0 + 0.1 * k / len(missing), 0.1 / len(missing))
    p = al.load(pid)
    # 2. Spracherkennung (Grafikkarte; ComfyUI gibt vorher seinen Speicher frei)
    await al._free_gpu(ctx)
    m = al.manifest(ASR_MODEL)
    key = hashlib.sha1(json.dumps([tids, prm.get("region"), prm["source_lang"], ASR_MODEL, PLAN_VERSION, WORDS_VERSION]).encode()).hexdigest()[:12]
    work = al.ROOT / pid / "work" / f"asr_{key}"
    work.mkdir(parents=True, exist_ok=True)
    out = work / "asr.jsonl"
    src = prm["source_lang"]
    tracks = []
    for tid in tids:
        tr = al._track(p, tid)
        cat = ((tr.get("channel") or {}).get("category") or "").upper()
        tracks.append({"id": tid, "file": al._track_paths(pid, tid)["flac"], "act": str(_spec_base(pid, tid).with_suffix(".act")),
                       "vad": str(_spec_base(pid, tid).with_suffix(".vad")), "kind": "radio" if cat == "VHF" else "speech"})
    settings = {"model": ASR_MODEL, "weights_dir": str(al.MODELS_DIR / ASR_MODEL), "device": m.get("device") or "cuda",
                "tracks": tracks, "region": prm.get("region"), "out": str(out), "beams": 5,
                "vad_dir": str(al.MODELS_DIR / "silero_vad") if al.model_installed(al.manifest("silero_vad")) else None,
                "align_dir": str(al.MODELS_DIR / "omnilingual_ctc1b") if _installed("omnilingual_ctc1b") else None,
                "language": "auto" if src in ("", "auto", "tl") else src,
                # Tagalog-Mitschnitte enthalten viel Englisch: Whisper wählt je Abschnitt zwischen beiden
                "allowed": ["tl", "en"] if src in ("", "auto", "tl") else []}
    t0 = time.time()
    res = await al._run_tool("transcribe", settings, ctx, 0.1, 0.45, t("Sprache erkennen", "recognising speech"), tool=TOOL)
    asr_s = time.time() - t0
    segs = []
    for line in out.read_text(encoding="utf-8").splitlines():
        with contextlib.suppress(ValueError):
            r = json.loads(line)
            if not r.get("dropped") and r.get("text"):
                segs.append(r)
    # 3. Übersetzen (Sprachmodell in ComfyUI, nach dem Whisper-Prozess, 16 GB tragen nur eins)
    for s in segs:
        s["translation"] = {}
    t1 = time.time()
    if prm.get("translate", True) and segs:
        from . import comfy
        if comfy.text_backend() is comfy.MAIN:
            await jobs._ensure_backend(ctx)
        await _translate(segs, src, prm["target_lang"], ctx, 0.55, 0.43)
    tr_s = time.time() - t1
    # 4. In die Übersetzer-Spur: ungeprüfte KI-Blöcke dieser Spuren im Bereich ersetzen, geprüfte bleiben
    region = prm.get("region") or [0.0, float(p.get("duration") or 0) + 1]
    doc = load_transcript(pid)
    names = {x["id"]: x["name"] for x in p["tracks"]}

    def radio(tid: str) -> bool:
        tr = next((x for x in p["tracks"] if x["id"] == tid), None) or {}
        return ((tr.get("channel") or {}).get("category") or "").upper() == "VHF"
    force = bool(prm.get("force"))
    # Mikrofone hören dasselbe Gespräch (eine Gruppe), Funkkanäle je für sich
    if force:
        group = {tids[0]} if radio(tids[0]) else {x["id"] for x in p["tracks"] if not radio(x["id"])}
    else:
        group = set(tids)

    def stale(s: dict[str, Any]) -> bool:
        # Von Hand festgelegte Spur (pinned) ersetzt nur ein neuer Lauf mit fester Spur
        return (s.get("status") == "draft" and s.get("origin") == "ai" and s.get("track") in group
                and (force or not s.get("pinned")) and s["end"] > region[0] and s["start"] < region[1])
    keep = [s for s in doc.get("segments") or [] if not stale(s)]
    blocking = [s for s in keep if s.get("status") == "checked" or (s.get("pinned") and s.get("origin") == "ai")]

    def same_place(c: dict[str, Any], s: dict[str, Any]) -> bool:
        both_mics = not radio(c["track"]) and not radio(s["track"])
        return (c["track"] == s["track"] or both_mics) and c["start"] < s["end"] and c["end"] > s["start"]
    new = []
    for s in segs:
        # Nicht über einen geprüften oder von Hand festgelegten Block derselben Stelle legen
        if any(same_place(c, s) for c in blocking):
            continue
        new.append({"id": f"ai{hashlib.sha1(s['id'].encode()).hexdigest()[:10]}", "start": s["start"], "end": s["end"],
                    "track": s["track"], "speaker": "", "kind": "radio" if s.get("kind") == "radio" else "speech",
                    "text": s["text"], "lang": s.get("lang") or "", "translation": s.get("translation") or {},
                    "conf": s.get("conf"), "status": "draft", "origin": "ai",
                    "note": ", ".join(s.get("flags") or []), "words": s.get("words") or [],
                    "second": s.get("second"), "alt_text": s.get("alt_text") or "", "second_sim": s.get("second_sim"),
                    "pinned": force})
    doc["segments"] = keep + new
    doc["source_lang"] = src
    doc["target_lang"] = prm["target_lang"]
    from . import __version__
    doc.setdefault("runs", []).append({"time": time.time(), "model": ASR_MODEL, "translator": TEXT_ENCODER,
                                       "second_opinion": "omnilingual_ctc1b" if settings.get("align_dir") else None,
                                       "vad": "silero_vad" if settings.get("vad_dir") else None,
                                       "hardware": _hardware(), "program": f"NVAI-open {__version__}",
                                       "words_version": WORDS_VERSION,
                                       "tracks": [names.get(x, x) for x in tids], "region": prm.get("region"), "fixed_track": force,
                                       "segments": len(new), "asr_seconds": round(asr_s, 1),
                                       "translate_seconds": round(tr_s, 1), "asr": res})
    save_transcript(pid, doc, client="ai", runs=doc["runs"])

    def fn(q: dict[str, Any]) -> None:
        q["history"].append({"time": time.time(), "op": "transcribe", "seconds": round(asr_s + tr_s, 1),
                             "label": t(f"Übersetzer-Spur: {len(new)} Blöcke (Whisper large-v3, Qwen3.5-9B), Entwurf",
                                        f"Translation track: {len(new)} blocks (Whisper large-v3, Qwen3.5-9B), draft")})
    al.update(pid, fn)
    return []


# --------------------------------------------------------------------------------------------- Bester Kanal

async def submit_automix(pid: str, tids: list[str]) -> Job:
    """„Bester Kanal“: aus mehreren Mikrofonen je Moment das mit der klarsten Sprache (nur Auswahl und Überblendung,
    kein Kanal wird verändert; wie Untersuchungsstellen bei VDR-Mitschnitten)."""
    p = al.load(pid)
    if p.get("status") != "ready":
        raise al.AudioError(t("Das Projekt ist noch nicht eingelesen.", "The project has not been read yet."))
    tracks = [al._track(p, tid) for tid in tids]
    if len(tracks) < 2:
        raise al.AudioError(t("Mindestens zwei Spuren wählen.", "Choose at least two tracks."))
    if any(x.get("offset") for x in tracks):
        raise al.AudioError(t("Vorschau-Spuren gehen hier nicht.", "Preview tracks do not work here."))
    rates = {int(x.get("sr") or p.get("sample_rate") or 0) for x in tracks}
    if len(rates) > 1:
        raise al.AudioError(t("Die Spuren haben verschiedene Abtastraten.", "The tracks have different sample rates."))
    return await jobs.submit("audio_mix", {"project_id": pid, "tracks": [x["id"] for x in tracks]})


async def _automix(job: Job, ctx: jobs.JobContext) -> list[str]:
    pid, tids = job.params["project_id"], job.params["tracks"]
    vads = []
    if vad_ready():
        await _compute_vad(pid, [x for x in tids if not _spec_base(pid, x).with_suffix(".vad").exists()], ctx, 0.0, 0.4)
        vads = [str(_spec_base(pid, x).with_suffix(".vad")) for x in tids]
    p = al.load(pid)
    tid = f"t_{uuid.uuid4().hex[:8]}"
    dec = _data_dir(pid) / f"automix_{tid}.json"
    res = await al._run_tool("automix", {"srcs": [al._track_paths(pid, x)["flac"] for x in tids], **al._track_paths(pid, tid),
                                         "decisions": str(dec), "vads": vads}, ctx, 0.4 if vads else 0.0, 0.6 if vads else 1.0,
                             t("bester Kanal", "best channel"), tool=TOOL)
    names = [al._track(p, x)["name"] for x in tids]
    sr = al._track(p, tids[0]).get("sr")

    def fn(q: dict[str, Any]) -> None:
        tr = al._new_track(q, t("Bester Kanal", "Best channel"), "processed", res,
                           {"kind": "automix", "tracks": tids, "label": t("Bester Kanal", "Best channel"),
                            "seconds": res.get("seconds")}, tid)
        if sr:
            tr["sr"] = sr
        tr["mix_of"] = tids
        q["history"].append({"time": time.time(), "op": "automix", "seconds": res.get("seconds"), "track": tid,
                             "label": t(f"Bester Kanal aus {', '.join(names)}: {res.get('switches')} Abschnitte, "
                                        f"{res.get('speech_seconds')} s mit Sprache",
                                        f"Best channel from {', '.join(names)}: {res.get('switches')} sections, "
                                        f"{res.get('speech_seconds')} s with speech")})
    al.update(pid, fn)
    return []


def automix_decisions(pid: str, tid: str) -> dict[str, Any]:
    al._dir(pid)
    if not al._FILE.match(tid):
        raise LookupError(tid)
    path = _data_dir(pid) / f"automix_{tid}.json"
    if not path.is_file():
        raise LookupError(tid)
    return json.loads(path.read_text(encoding="utf-8"))


# ------------------------------------------------------------------------------- Video zuordnen und exportieren

# Lage der Uhr „System Time“ im Furuno Live Player V5, Fenster maximiert auf 1920 × 1080 (gemessen 17.11.)
LIVEPLAYER_CLOCK = [150, 84, 156, 22]


async def submit_align(pid: str, path: str, method: str = "clock", box: list[int] | None = None) -> Job:
    """Ein Video (die Bildschirmaufnahme des Wiedergabeprogramms) zuordnen und über den Ton auf die Zeit der Aufnahme
    ausrichten (Nutzer 17.11.: „Video mit Ton“ für die Anwälte = die Live-Player-Aufnahme mit neuem Ton)."""
    p = al.load(pid)
    if p.get("status") != "ready":
        raise al.AudioError(t("Das Projekt ist noch nicht eingelesen.", "The project has not been read yet."))
    src = Path((path or "").strip().strip('"'))
    if not src.is_file():
        raise al.AudioError(t(f"Datei nicht gefunden: {src}", f"File not found: {src}"))
    refs = [x["id"] for x in p["tracks"] if x.get("kind") == "original" and not x.get("offset")]
    if not refs:
        raise al.AudioError(t("Keine Original-Spuren zum Abgleich.", "No original tracks to compare."))
    if method == "clock" and not p.get("time_origin"):
        raise al.AudioError(t("Für die Uhr im Bild braucht das Projekt eine Uhrzeit (Schiffsschreiber).",
                              "Reading the clock in the picture needs a project with a time base (voyage data recorder)."))
    return await jobs.submit("audio_align", {"project_id": pid, "path": str(src), "tracks": refs,
                                             "method": "clock" if method == "clock" else "audio",
                                             "box": [int(x) for x in (box or LIVEPLAYER_CLOCK)][:4]})


async def _align(job: Job, ctx: jobs.JobContext) -> list[str]:
    pid = job.params["project_id"]
    out = _data_dir(pid) / "video_align.json"
    if job.params.get("method") == "clock":
        # Uhr im Bild: das Bild zeigt die Aufnahme-Zeit; der Ton des Live Players läuft dagegen rund 2 s nach und
        # seine Mikrofongruppen sind gegeneinander versetzt (Messung 17.11.), daher nicht über den Ton
        res = await al._run_tool("clockalign", {"video": job.params["path"], "box": job.params["box"],
                                                "origin": al.load(pid)["time_origin"], "step_s": 300, "out": str(out)},
                                 ctx, 0, 1, t("Uhr im Bild lesen", "reading the clock in the picture"), tool=TOOL)
    else:
        res = await al._run_tool("align", {"video": job.params["path"], "ref": [al._track_paths(pid, x)["flac"] for x in job.params["tracks"]],
                                           "out": str(out)}, ctx, 0, 1, t("Video ausrichten", "aligning video"), tool=TOOL)
    pr_path = Path(job.params["path"])
    method = "clock" if job.params.get("method") == "clock" else "audio"

    def fn(q: dict[str, Any]) -> None:
        q["video"] = {"path": str(pr_path), "name": pr_path.name, "size": pr_path.stat().st_size, "fit": res["fit"], "method": method,
                      "drift_ppm": res.get("drift_ppm"), "residual_ms": res.get("residual_ms"),
                      "points": res.get("used_points"), "duration": res.get("video_duration"), "time": time.time()}
        fit = res["fit"]
        q["history"].append({"time": time.time(), "op": "align", "seconds": res.get("seconds"),
                             "label": t(f"Video zugeordnet ({'Uhr im Bild' if method == 'clock' else 'über den Ton'}): {pr_path.name}; Video-Zeit = {fit['a']:.6f} × Aufnahme-Zeit "
                                        f"{fit['b']:+.2f} s, Drift {res.get('drift_ppm')} ppm, Restfehler "
                                        f"{(res.get('residual_ms') or {}).get('median')} ms (Median) / "
                                        f"{(res.get('residual_ms') or {}).get('max')} ms (max), {res.get('used_points')} Messpunkte",
                                        f"Video linked ({'clock in the picture' if method == 'clock' else 'by sound'}): {pr_path.name}; video time = {fit['a']:.6f} × recording time "
                                        f"{fit['b']:+.2f} s, drift {res.get('drift_ppm')} ppm, residual "
                                        f"{(res.get('residual_ms') or {}).get('median')} ms (median) / "
                                        f"{(res.get('residual_ms') or {}).get('max')} ms (max), {res.get('used_points')} points")})
    al.update(pid, fn)
    return []


def video_file(pid: str) -> Path:
    p = al.load(pid)
    v = p.get("video") or {}
    if not v.get("path") or not Path(v["path"]).is_file():
        return source_file(pid)
    return Path(v["path"])


async def submit_vexport(pid: str, req: dict[str, Any]) -> Job:
    p = al.load(pid)
    v = p.get("video") or {}
    if not v.get("fit"):
        raise al.AudioError(t("Erst ein Video zuordnen (Export → Video zuordnen).", "Link a video first (Export → Link video)."))
    chosen = []
    for tr in req.get("tracks") or []:
        x = al._track(p, tr["id"])
        if x.get("offset"):
            raise al.AudioError(t("Vorschau-Spuren lassen sich nicht exportieren.", "Preview tracks cannot be exported."))
        if not tr.get("mute"):
            chosen.append({"id": x["id"], "gain_db": float(tr.get("gain_db") or 0)})
    if not chosen:
        raise al.AudioError(t("Keine Spur zu hören.", "No track audible."))
    rates = {int(al._track(p, x["id"]).get("sr") or p.get("sample_rate") or 0) for x in chosen}
    if len(rates) > 1:
        raise al.AudioError(t("Die hörbaren Spuren haben verschiedene Abtastraten.", "The audible tracks have different sample rates."))
    return await jobs.submit("audio_vexport", {"project_id": pid, "tracks": chosen, "region": req.get("region"),
                                               "subtitles": req.get("subtitles") or "none", "mono": bool(req.get("mono")),
                                               "name": str(req.get("name") or "")[:80],
                                               "dest_dir": al.check_dest_dir(req.get("dest_dir"))})


async def _vexport(job: Job, ctx: jobs.JobContext) -> list[str]:
    import re as _re
    from . import config
    pid = job.params["project_id"]
    p = al.load(pid)
    v = p["video"]
    srt = None
    mode = job.params.get("subtitles")
    if mode in ("original", "translation"):
        doc = load_transcript(pid)
        lang = doc.get("target_lang") or "de"
        srt = []
        for s in doc.get("segments") or []:
            txt = s["text"] if mode == "original" else (s.get("translation") or {}).get(lang) or ""
            if txt:
                srt.append({"start": s["start"], "end": s["end"], "text": f"[{txt}]" if s.get("kind") == "sound" else txt})
    stem = _re.sub(r"[^\w\-. ]+", "_", job.params.get("name") or f"{p['name']} mit Ton")[:80].strip() or "video"
    dest, as_asset = al.export_target(job.params.get("dest_dir"), stem, ".mp4")
    out_name = dest.name
    res = await al._run_tool("videoexport", {"video": v["path"], "fit": v["fit"],
                                             "tracks": [{"file": al._track_paths(pid, x["id"])["flac"], "gain_db": x["gain_db"]}
                                                        for x in job.params["tracks"]],
                                             "region": job.params.get("region"), "out": str(dest), "mono": job.params.get("mono"),
                                             "srt": srt}, ctx, 0, 1, t("Video mit Ton", "video with sound"), tool=TOOL)
    if not as_asset:
        al.update(pid, lambda q: q["history"].append({"time": time.time(), "op": "export", "format": "mp4", "path": str(dest),
                                                       "file": out_name, "srt": Path(res["srt"]).name if res.get("srt") else None}))
        return []
    asset = db.create_asset(kind="video", filename=out_name, job_id=job.id, prompt=p["name"], model_id="audio-forensic",
                            meta={"audio_project": pid, "tracks": job.params["tracks"], "region": job.params.get("region"),
                                  "subtitles": mode, "srt": Path(res["srt"]).name if res.get("srt") else None,
                                  "video_start": res.get("video_start"), "record_start": res.get("record_start"),
                                  "size_mb": res.get("size_mb")})
    al.update(pid, lambda q: q["history"].append({"time": time.time(), "op": "export", "format": "mp4", "asset_id": asset.id,
                                                   "file": out_name, "srt": Path(res["srt"]).name if res.get("srt") else None}))
    jobs.publish({"type": "assets.changed"})
    return [asset.id]


# ------------------------------------------------------------------------------------------- Lagebild-Video

RENDER_PANELS = {"tracks", "text", "conning", "map", "events", "video"}


async def submit_render(pid: str, req: dict[str, Any]) -> Job:
    """Lagebild-Video: die angekreuzten Ansichten oben, die gewählten Spuren unten mit laufendem Zeitmarker, Uhrzeit im
    Kopf, Ton aus den Spuren (forensic_tools.cmd_render)."""
    p = al.load(pid)
    if p.get("status") != "ready":
        raise al.AudioError(t("Das Projekt ist noch nicht bereit.", "The project is not ready yet."))
    panels = []
    for x in req.get("panels") or []:
        x = str(x)
        if (x in RENDER_PANELS or (x.startswith("img:") and re.fullmatch(r"img:[\w.\-]{1,40}", x))) and x not in panels:
            panels.append(x)
    if "video" in panels and not (p.get("video") or {}).get("fit"):
        panels.remove("video")
    if not panels:
        raise al.AudioError(t("Nichts zum Zeigen angekreuzt.", "Nothing ticked to show."))
    chosen = []
    for tr in req.get("tracks") or []:
        x = al._track(p, tr["id"])
        if x.get("offset"):
            raise al.AudioError(t("Vorschau-Spuren lassen sich nicht exportieren.", "Preview tracks cannot be exported."))
        view = tr.get("view") if tr.get("view") in ("wave", "spec", "both") else "wave"
        chosen.append({"id": x["id"], "gain_db": float(tr.get("gain_db") or 0), "view": view})
    dur = float(p.get("duration") or 0)
    region = req.get("region") or [0.0, dur]
    a, b = max(0.0, float(region[0])), min(dur, float(region[1]))
    if b - a < 1:
        raise al.AudioError(t("Der Bereich ist zu kurz (mindestens 1 s).", "The range is too short (at least 1 s)."))
    fps = int(req.get("fps") or 10)
    if fps not in (5, 10, 25):
        fps = 10
    spec = req.get("spec") or {}
    return await jobs.submit("audio_render", {
        "project_id": pid, "panels": panels, "tracks": chosen, "region": [round(a, 3), round(b, 3)], "fps": fps,
        "mono": bool(req.get("mono")), "lang": "en" if req.get("lang") == "en" else "de",
        "spec": {"lo": float(spec.get("lo", -95)), "hi": float(spec.get("hi", -20)), "fmax": float(spec.get("fmax", 8000))},
        "dest_dir": al.check_dest_dir(req.get("dest_dir"))})


async def _render(job: Job, ctx: jobs.JobContext) -> list[str]:
    from . import config
    pid = job.params["project_id"]
    p = al.load(pid)
    folder = al._dir(pid)
    data = folder / "data"
    names = {x["id"]: x.get("name") or x["id"] for x in p.get("tracks") or []}
    doc = load_transcript(pid)
    segments = [{**g, "track_name": names.get(g.get("track"), "")} for g in doc.get("segments") or []]
    notes = [m for m in p.get("markers") or [] if m.get("kind") == "note"]
    events: list[dict[str, Any]] = []
    with contextlib.suppress(OSError, ValueError):
        events = json.loads((data / "events.json").read_text(encoding="utf-8"))
    # Ton-Suche wie im Zeitstrahl (Workspace.tsx): Alarme und Piepser als Ereignisse
    for cl in ((p.get("scan") or {}).get("clusters") or [])[:6]:
        for ea, eb in cl.get("events") or []:
            events.append({"t": ea, "end": eb, "kind": "tone", "label": " + ".join(str(f) for f in cl.get("freqs") or []) + " Hz",
                           "detail": t("Ton-Suche", "tone scan"), "source": "scan"})
    tracks = []
    for x in job.params["tracks"]:
        tr = al._track(p, x["id"])
        spec_base = _spec_base(pid, x["id"])
        tracks.append({"file": al._track_paths(pid, x["id"])["flac"], "gain_db": x["gain_db"], "view": x["view"],
                       "name": tr.get("name"), "color": tr.get("color"), "spec_base": str(spec_base)})
    a, b = job.params["region"]
    v = p.get("video") or {}

    def hms(x: float) -> str:
        if p.get("time_origin"):
            return time.strftime("%H%M%S", time.gmtime(p["time_origin"] + x))
        return f"{int(x // 3600)}h{int(x % 3600 // 60):02d}m{int(x % 60):02d}s"
    stem = re.sub(r"[^\w\-. ]+", "_", f"{p['name']} Lagebild {hms(a)}-{hms(b)}")[:90].strip() or "lagebild"
    dest, as_asset = al.export_target(job.params.get("dest_dir"), stem, ".mp4")
    out_name = dest.name
    res = await al._run_tool("render", {
        "out": str(dest), "region": [a, b], "fps": job.params["fps"], "origin": p.get("time_origin"),
        "lang": job.params.get("lang") or "de", "title": p["name"], "panels": job.params["panels"], "tracks": tracks,
        "spec": job.params.get("spec") or {}, "segments": segments, "target_lang": doc.get("target_lang") or "de",
        "credits": credits_line(doc, (job.params.get("lang") or "de") == "de"),
        "notes": notes, "events": events, "series": str(data / "series.json"), "images": str(data / "images.json"),
        "images_dir": str(folder / "images"), "video": {"path": v["path"], "fit": v["fit"]} if v.get("fit") else None,
        "mono": job.params.get("mono")}, ctx, 0, 1, t("Lagebild-Video", "situation video"), tool=TOOL)
    if not as_asset:
        al.update(pid, lambda q: q["history"].append({"time": time.time(), "op": "export", "format": "mp4", "kind": "render",
                                                       "path": str(dest), "file": out_name, "region": [a, b],
                                                       "panels": job.params["panels"]}))
        return []
    asset = db.create_asset(kind="video", filename=out_name, job_id=job.id, prompt=p["name"], model_id="audio-forensic",
                            meta={"audio_project": pid, "render": True, "panels": job.params["panels"],
                                  "tracks": job.params["tracks"], "region": [a, b], "fps": job.params["fps"],
                                  "encoder": res.get("encoder"), "size_mb": res.get("size_mb")})
    al.update(pid, lambda q: q["history"].append({"time": time.time(), "op": "export", "format": "mp4", "kind": "render",
                                                   "asset_id": asset.id, "file": out_name, "region": [a, b],
                                                   "panels": job.params["panels"]}))
    jobs.publish({"type": "assets.changed"})
    return [asset.id]


# ------------------------------------------------------------------------------------------- Beweiskette

async def submit_hash(pid: str) -> Job:
    """SHA-256 der Quelldatei (SWGDE: Originale per Prüfsumme belegen). Schiffsschreiber prüfen ihre eigene Liste
    (audio_vdr.py)."""
    p = al.load(pid)
    if (p.get("source") or {}).get("kind") == "vdr":
        raise al.AudioError(t("Schiffsschreiber: Prüfsummen über „Prüfen“ im Protokoll.", "Voyage data recorder: checksums via “Verify” in the log."))
    return await jobs.submit("audio_hash", {"project_id": pid})


def _sha256_file(path: Path, ctx: jobs.JobContext) -> tuple[str, int]:
    h = hashlib.sha256()
    size = path.stat().st_size
    done = 0
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1 << 23), b""):
            h.update(block)
            done += len(block)
            ctx.progress(done / max(1, size), t("Prüfsumme der Quelle", "checksum of the source"))
            if ctx.should_stop():
                raise asyncio.CancelledError
    return h.hexdigest(), size


async def _hash(job: Job, ctx: jobs.JobContext) -> list[str]:
    pid = job.params["project_id"]
    p = al.load(pid)
    if (p.get("source") or {}).get("kind") == "vdr":
        return []
    path = al._source_path(p["source"])
    t0 = time.time()
    digest, size = await asyncio.to_thread(_sha256_file, path, ctx)

    def fn(q: dict[str, Any]) -> None:
        q["source"].update({"sha256": digest, "size": size, "sha256_time": time.time(),
                            "mtime": path.stat().st_mtime})
        q["history"].append({"time": time.time(), "op": "hash", "label": t(f"SHA-256 der Quelle: {digest}",
                                                                         f"SHA-256 of the source: {digest}"),
                             "seconds": round(time.time() - t0, 1)})
    al.update(pid, fn)
    return []


def spec_file(pid: str, tid: str, level: str) -> Path:
    al._dir(pid)
    if level not in SPEC_FILES or not al._FILE.match(tid):
        raise LookupError(level)
    path = _spec_base(pid, tid).with_suffix(SPEC_FILES[level])
    if not path.is_file():
        raise LookupError(t("Für diese Spur ist noch kein Spektrogramm gerechnet.", "No spectrogram computed for this track yet."))
    return path


def activity(pid: str, tid: str) -> dict[str, Any]:
    al._dir(pid)
    if not al._FILE.match(tid):
        raise LookupError(tid)
    path = _data_dir(pid) / f"act_{tid}.json"
    if not path.is_file():
        raise LookupError(t("Keine Sprachaktivität für diese Spur.", "No speech activity for this track."))
    return json.loads(path.read_text(encoding="utf-8"))


# --------------------------------------------------------------------------------------------- Transkript

def _clean_segment(s: dict[str, Any]) -> dict[str, Any]:
    start, end = float(s.get("start") or 0), float(s.get("end") or 0)
    if end < start:
        start, end = end, start
    tr = s.get("translation") if isinstance(s.get("translation"), dict) else {}
    words = s.get("words") if isinstance(s.get("words"), list) else []
    return {"id": str(s.get("id") or uuid.uuid4().hex[:10])[:16], "start": round(start, 3), "end": round(end, 3),
            "track": str(s.get("track") or "")[:40], "speaker": str(s.get("speaker") or "")[:40],
            "kind": s.get("kind") if s.get("kind") in SEG_KINDS else "speech",
            "text": str(s.get("text") or "")[:4000], "lang": str(s.get("lang") or "")[:12],
            "translation": {str(k)[:12]: str(v)[:4000] for k, v in list(tr.items())[:6]},
            "conf": None if s.get("conf") is None else round(float(s["conf"]), 3),
            "status": s.get("status") if s.get("status") in ("draft", "checked") else "draft",
            # ai: ungeänderter Entwurf der KI (ein neuer Lauf ersetzt ihn), human: von Hand angelegt oder geändert
            "origin": s.get("origin") if s.get("origin") in ("ai", "human") else "human",
            "second": str(s.get("second") or "")[:40] or None,
            # Spur von Hand festgelegt (Übersetzer-KI mit fester Spur); ein Lauf mit Automatik lässt den Block stehen
            "pinned": bool(s.get("pinned")),
            "note": str(s.get("note") or "")[:2000],
            "alt_text": str(s.get("alt_text") or "")[:4000],
            "second_sim": None if s.get("second_sim") is None else round(float(s["second_sim"]), 3),
            "words": [w[:5] for w in words[:2000] if isinstance(w, list)]}


def _hardware() -> dict[str, Any]:
    """Grafikkarten dieses Rechners für den Lauf-Eintrag (Name, Speicher); gerechnet wird lokal, ohne Internetdienst."""
    from . import gpu
    try:
        cards = gpu.list_gpus()
    except Exception:  # noqa: BLE001
        cards = []
    return {"gpus": [{"name": str(c.get("name") or ""), "vram_gb": c.get("vram_total_gb")} for c in cards if c.get("name")]}


def _model_info(mid: str) -> dict[str, Any]:
    try:
        m = al.manifest(mid) or {}
    except Exception:  # noqa: BLE001
        m = {}
    name, by = MODEL_NAMES.get(mid, (mid, ""))
    return {"id": mid, "name": name, "by": by, "license": m.get("license_weights") or m.get("license_code") or "",
            "license_url": m.get("license_url") or ""}


def transcript_credits(doc: dict[str, Any]) -> dict[str, Any] | None:
    """Womit die Übersetzer-Spur berechnet wurde, über alle Läufe: je Aufgabe Modell, Hersteller und Lizenz, die
    Grafikkarten, der Programmstand. Läufe ohne festgehaltene Karte (vor dem 18.11.) bekommen die Karte des
    Auswerte-Rechners, gekennzeichnet über unrecorded/gpus_now."""
    runs = [r for r in doc.get("runs") or [] if isinstance(r, dict)]
    if not runs:
        return None
    models: list[dict[str, Any]] = []
    seen: set[tuple[str, str]] = set()

    def add(role: str, info: dict[str, Any]) -> None:
        if (role, info["id"]) not in seen:
            seen.add((role, info["id"]))
            models.append({"role": role, **info})

    def label(g: dict[str, Any]) -> str:
        # nvidia-smi meldet GiB (16-GB-Karte: 15,9); angezeigt wie auf der Karte
        return f"{g['name']} ({round(float(g['vram_gb']))} GB)" if g.get("vram_gb") else str(g["name"])
    gpus: list[str] = []
    unrecorded = 0
    for r in runs:
        if r.get("model"):
            add("asr", _model_info(str(r["model"])))
        if r.get("translator"):
            add("translate", TRANSLATOR_INFO if r["translator"] == TEXT_ENCODER
                else {"id": str(r["translator"]), "name": str(r["translator"]), "by": "", "license": "", "license_url": ""})
        if r.get("second_opinion"):
            add("second", _model_info(str(r["second_opinion"])))
        if r.get("vad"):
            add("vad", _model_info(str(r["vad"])))
        hw = r.get("hardware")
        if not isinstance(hw, dict):
            unrecorded += 1
            continue
        for g in hw.get("gpus") or []:
            if isinstance(g, dict) and g.get("name") and label(g) not in gpus:
                gpus.append(label(g))
    return {"local": True, "models": models, "gpus": gpus, "runs": len(runs), "unrecorded": unrecorded,
            "gpus_now": [label(g) for g in _hardware()["gpus"]] if unrecorded else [],
            "programs": sorted({str(r["program"]) for r in runs if r.get("program")})}


def credits_line(doc: dict[str, Any], de: bool) -> str:
    """Hinweis in einer Zeile (Lagebild-Video, Mitlesen): Spracherkennung und Übersetzung mit Lizenz, lokale Grafikkarte."""
    c = transcript_credits(doc)
    if not c:
        return ""
    role = {"asr": ("Spracherkennung", "speech recognition"), "translate": ("Übersetzung", "translation")}
    parts = [f"{role[m['role']][0 if de else 1]} {m['name']} ({m['license']})" for m in c["models"] if m["role"] in role]
    gpus = list(dict.fromkeys((c["gpus"] or []) + (c["gpus_now"] or [])))
    where = (("lokal auf " if de else "locally on ") + ", ".join(gpus)) if gpus else ("lokal" if de else "locally")
    return ("KI-Entwurf: " if de else "AI draft: ") + ", ".join(parts) + ", " + where


def load_transcript(pid: str) -> dict[str, Any]:
    al._dir(pid)
    path = al.ROOT / pid / "data" / "transcript.json"
    if not path.is_file():
        return {"version": 1, "source_lang": "", "target_lang": "de", "speakers": [], "segments": [], "runs": []}
    return json.loads(path.read_text(encoding="utf-8"))


def save_transcript(pid: str, doc: dict[str, Any], client: str = "", runs: list[dict[str, Any]] | None = None) -> dict[str, Any]:
    """Ganze Übersetzer-Spur speichern. client: Kennung des Browserfensters, das speichert; es lädt bei der eigenen
    Meldung nicht neu (sonst überschreibt das Neuladen, was dort gerade getippt wird)."""
    al._dir(pid)
    segs = [_clean_segment(s) for s in (doc.get("segments") or [])[:MAX_SEGMENTS] if isinstance(s, dict)]
    segs.sort(key=lambda s: (s["start"], s["end"]))
    speakers = [{"id": str(x.get("id") or "")[:40], "name": str(x.get("name") or "")[:80], "color": str(x.get("color") or "")[:16]}
                for x in (doc.get("speakers") or [])[:50] if isinstance(x, dict) and x.get("id")]
    old = load_transcript(pid)
    out = {"version": 1, "source_lang": str(doc.get("source_lang") or old.get("source_lang") or "")[:12],
           "target_lang": str(doc.get("target_lang") or old.get("target_lang") or "de")[:12],
           "speakers": speakers, "segments": segs, "runs": (runs if runs is not None else old.get("runs") or [])[-50:],
           "updated": time.time()}
    al._write(_data_dir(pid) / "transcript.json", out)
    jobs.publish({"type": "audio.transcript", "project_id": pid, "client": str(client or "")[:40]})
    return out


# -------------------------------------------------------------------------------------------------- REST

router = APIRouter(prefix="/api/audio")


class TranscriptDoc(BaseModel):
    source_lang: str | None = Field(None, max_length=12)
    target_lang: str | None = Field(None, max_length=12)
    speakers: list[dict[str, Any]] = Field(default_factory=list, max_length=50)
    segments: list[dict[str, Any]] = Field(default_factory=list, max_length=MAX_SEGMENTS)
    client: str | None = Field(None, max_length=40)


@router.post("/projects/{pid}/tracks/{tid}/spectro", response_model=Job)
async def api_spectro(pid: str, tid: str) -> Job:
    return await al._ahttp(submit_spectro(pid, tid))


@router.get("/projects/{pid}/spec/{tid}/{level}")
async def api_spec_file(pid: str, tid: str, level: str) -> FileResponse:
    path = al._http(spec_file, pid, tid, level)
    return FileResponse(path, media_type="application/octet-stream", headers={"Cache-Control": "no-cache"})


def source_file(pid: str) -> Path:
    """Die Quelldatei eines Projekts (Video zum Mitlaufen im Monitor); Schiffsschreiber haben keine."""
    p = al.load(pid)
    if (p.get("source") or {}).get("kind") == "vdr":
        raise LookupError(t("Ein Schiffsschreiber hat keine einzelne Quelldatei.", "A voyage data recorder has no single source file."))
    return al._source_path(p["source"])


@router.get("/projects/{pid}/source")
async def api_source(pid: str) -> FileResponse:
    path = al._http(source_file, pid)
    media = {".mp4": "video/mp4", ".m4v": "video/mp4", ".mov": "video/quicktime", ".mkv": "video/x-matroska",
             ".webm": "video/webm"}.get(path.suffix.lower(), "application/octet-stream")
    return FileResponse(path, media_type=media)


@router.get("/projects/{pid}/activity/{tid}")
async def api_activity(pid: str, tid: str) -> dict[str, Any]:
    return al._http(activity, pid, tid)


def _with_credits(doc: dict[str, Any]) -> dict[str, Any]:
    return {**doc, "credits": transcript_credits(doc)}


@router.get("/projects/{pid}/transcript")
async def api_transcript(pid: str) -> dict[str, Any]:
    doc = al._http(load_transcript, pid)
    return await asyncio.to_thread(_with_credits, doc)


@router.put("/projects/{pid}/transcript")
async def api_transcript_save(pid: str, req: TranscriptDoc) -> dict[str, Any]:
    doc = await asyncio.to_thread(al._http, save_transcript, pid, req.model_dump(exclude={"client"}), req.client or "")
    return await asyncio.to_thread(_with_credits, doc)


class TranscribeRequest(BaseModel):
    tracks: list[str] = Field(..., max_length=32)
    source_lang: str = Field("tl", max_length=12)
    target_lang: str = Field("de", max_length=12)
    region: list[float] | None = None
    translate: bool = True


@router.post("/projects/{pid}/transcribe", response_model=Job)
async def api_transcribe(pid: str, req: TranscribeRequest) -> Job:
    return await al._ahttp(submit_transcribe(pid, req.model_dump()))


class TracksRequest(BaseModel):
    tracks: list[str] = Field(default_factory=list, max_length=32)


@router.post("/projects/{pid}/vad", response_model=Job)
async def api_vad(pid: str, req: TracksRequest) -> Job:
    return await al._ahttp(submit_vad(pid, req.tracks))


class VideoLink(BaseModel):
    path: str = Field(..., max_length=1000)
    method: str = Field("clock", max_length=10)
    box: list[int] | None = Field(None, max_length=4)


@router.post("/projects/{pid}/video", response_model=Job)
async def api_video_link(pid: str, req: VideoLink) -> Job:
    return await al._ahttp(submit_align(pid, req.path, req.method, req.box))


@router.get("/projects/{pid}/video")
async def api_video_file(pid: str, request: Request) -> Response:
    path = al._http(video_file, pid)
    media = "video/mp4" if path.suffix.lower() in (".mp4", ".m4v") else "application/octet-stream"
    return await asyncio.to_thread(al.capped_file, request, path, media, 8 << 20)


class VideoExportRequest(BaseModel):
    tracks: list[dict[str, Any]] = Field(..., max_length=32)
    region: list[float] | None = None
    subtitles: str = Field("none", max_length=20)
    mono: bool = False
    name: str = Field("", max_length=80)
    dest_dir: str | None = Field(None, max_length=500)


@router.post("/projects/{pid}/video/export", response_model=Job)
async def api_video_export(pid: str, req: VideoExportRequest) -> Job:
    return await al._ahttp(submit_vexport(pid, req.model_dump()))


class RenderRequest(BaseModel):
    panels: list[str] = Field(..., max_length=16)
    tracks: list[dict[str, Any]] = Field(default_factory=list, max_length=32)
    region: list[float] | None = None
    fps: int = 10
    mono: bool = False
    lang: str = Field("de", max_length=5)
    spec: dict[str, float] | None = None
    dest_dir: str | None = Field(None, max_length=500)


@router.post("/projects/{pid}/render", response_model=Job)
async def api_render(pid: str, req: RenderRequest) -> Job:
    return await al._ahttp(submit_render(pid, req.model_dump()))


class AutomixRequest(BaseModel):
    tracks: list[str] = Field(..., min_length=2, max_length=16)


@router.post("/projects/{pid}/automix", response_model=Job)
async def api_automix(pid: str, req: AutomixRequest) -> Job:
    return await al._ahttp(submit_automix(pid, req.tracks))


@router.get("/projects/{pid}/automix/{tid}")
async def api_automix_decisions(pid: str, tid: str) -> dict[str, Any]:
    return al._http(automix_decisions, pid, tid)


@router.post("/projects/{pid}/hash", response_model=Job)
async def api_hash(pid: str) -> Job:
    return await al._ahttp(submit_hash(pid))


jobs.register("audio_spectro")(_spectro)
jobs.register("audio_hash")(_hash)
jobs.register("audio_transcribe")(_transcribe)
jobs.register("audio_mix")(_automix)
jobs.register("audio_vad")(_vad)
jobs.register("audio_align")(_align)
jobs.register("audio_vexport")(_vexport)
jobs.register("audio_render")(_render)
jobs.RENDER_KINDS.update({"audio_spectro", "audio_hash", "audio_mix", "audio_vad", "audio_align", "audio_vexport", "audio_render"})
