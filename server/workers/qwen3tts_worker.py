"""Qwen3-TTS-Worker: Sprache aus Text fuer die Sprecherstimme (Studio-Spur "voice", REST, MCP).

Rechnet mit faster-qwen3-tts (MIT): Qwen3-TTS (Apache-2.0) mit CUDA-Graphen fuer Talker und Code-Predictor, auf
NVIDIA und AMD (ROCm). Die Referenzfassung von Qwen rief fuer jeden Ton-Frame 15-mal `generate` auf und brauchte auf
der RTX 5060 Ti das 3- bis 4-fache der Tonlaenge (gemessen 2.11.2026).

Laeuft in einem EIGENEN venv und Prozess (external/qwen3tts/.venv), weil faster-qwen3-tts transformers 5.15.1
verlangt und ComfyUI seine Fassung pinnt. PyTorch kommt NICHT aus diesem venv, sondern aus dem von ComfyUI
(QWEN3TTS_TORCH_SITE wird hinten an sys.path gehaengt): keine zweite PyTorch-Installation, und auf einer AMD-Karte
rechnet der Worker mit derselben ROCm-Fassung wie ComfyUI. Die eigenen Pakete stehen vorne und haben Vorrang.

Dieses Modul importiert bewusst nichts aus `nvai`. Konfiguration aus der Umgebung:

    QWEN3TTS_PORT        Port (Standard 8202)
    QWEN3TTS_TORCH_SITE  site-packages mit torch (das venv von ComfyUI)

Schnittstelle wie die Mesh-Worker: GET /health, POST /unload, POST /generate, dazu POST /cancel (bricht nach dem
naechsten erzeugten Ton-Frame ab, 12 je Sekunde Sprache).
"""
from __future__ import annotations

import gc
import importlib.machinery
import os
import random
import sys
import threading
import time
import types
from pathlib import Path
from typing import Any

PORT = int(os.environ.get("QWEN3TTS_PORT", "8202"))
_torch_site = os.environ.get("QWEN3TTS_TORCH_SITE", "")
if _torch_site and Path(_torch_site).is_dir() and _torch_site not in sys.path:
    sys.path.append(_torch_site)  # hinten: eigene Pakete gehen vor

import numpy as np  # noqa: E402
import soundfile as sf  # noqa: E402
import torch  # noqa: E402
from fastapi import FastAPI, HTTPException  # noqa: E402
from pydantic import BaseModel, Field  # noqa: E402
import transformers  # noqa: E402,F401  - VOR den Stubs: prueft beim Import per find_spec, ob torchaudio da ist


def _stub(name: str, **attrs: Any) -> types.ModuleType:
    mod = types.ModuleType(name)
    mod.__spec__ = importlib.machinery.ModuleSpec(name, loader=None)
    for k, v in attrs.items():
        setattr(mod, k, v)
    sys.modules[name] = mod
    return mod


def _missing(what: str):
    def fail(*_a: Any, **_k: Any) -> Any:
        raise RuntimeError(f"{what} ist nicht installiert (nur fuer den 25-Hz-Tokenizer noetig)")
    return fail


# qwen_tts importiert den 25-Hz-Tokenizer auf Modulebene und damit torchaudio, sox und onnxruntime. Genutzt werden
# sie nur dort; NVAI-open nimmt die 12-Hz-Modelle. torchaudio gibt es zu PyTorch 2.14 nicht passend, deshalb Stubs.
try:
    import torchaudio.compliance.kaldi  # noqa: F401
except Exception:  # noqa: BLE001 - jede Importpanne (fehlend, falsche ABI) fuehrt zum Stub
    _kaldi = _stub("torchaudio.compliance.kaldi", fbank=_missing("torchaudio"))
    _comp = _stub("torchaudio.compliance", kaldi=_kaldi)
    _stub("torchaudio", compliance=_comp, __version__="0-stub")
for _name in ("sox", "onnxruntime"):
    try:
        __import__(_name)
    except Exception:  # noqa: BLE001
        _stub(_name, Transformer=_missing(_name), InferenceSession=_missing(_name), SessionOptions=_missing(_name),
              GraphOptimizationLevel=types.SimpleNamespace(ORT_ENABLE_ALL=99))

import faster_qwen3_tts.generate as _fast_generate  # noqa: E402
from faster_qwen3_tts import FasterQwen3TTS  # noqa: E402

app = FastAPI(title="NVAI-open Qwen3-TTS-Worker")

_lock = threading.Lock()          # ein Auftrag zur Zeit (der Server schickt ohnehin nacheinander)
_cancel = threading.Event()
_model: FasterQwen3TTS | None = None
_model_path: str | None = None
_load_s = 0.0

# Kurzformen wie in der Oberflaeche -> Namen, die Qwen3-TTS erwartet
LANGUAGES = {
    "auto": "Auto", "de": "German", "en": "English", "fr": "French", "es": "Spanish", "it": "Italian",
    "pt": "Portuguese", "ru": "Russian", "zh": "Chinese", "ja": "Japanese", "ko": "Korean",
}


class _Cancelled(Exception):
    pass


# Abbrechen: Die Decode-Schleife von faster-qwen3-tts ruft je Ton-Frame sample_logits auf; dort einhaken.
_original_sample = _fast_generate.sample_logits


def _sample_or_cancel(*args: Any, **kwargs: Any) -> Any:
    if _cancel.is_set():
        raise _Cancelled()
    return _original_sample(*args, **kwargs)


_fast_generate.sample_logits = _sample_or_cancel


def _load(path: str) -> FasterQwen3TTS:
    """Laedt das Modell aus `path`; ein anderes geladenes Modell wird vorher freigegeben."""
    global _model, _model_path, _load_s
    if _model is not None and _model_path == path:
        return _model
    _unload()
    if not (Path(path) / "config.json").exists():
        raise HTTPException(404, f"Modellordner unvollstaendig oder fehlt: {path}")
    if not torch.cuda.is_available():
        raise HTTPException(503, "Qwen3-TTS braucht eine NVIDIA- oder AMD-Grafikkarte (CUDA/ROCm).")
    t0 = time.time()
    model = FasterQwen3TTS.from_pretrained(path, device="cuda", dtype=torch.bfloat16, attn_implementation="sdpa",
                                           local_files_only=True)
    model.warmup(prefill_len=100)  # CUDA-Graphen jetzt aufnehmen, nicht im ersten Auftrag
    _model, _model_path, _load_s = model, path, time.time() - t0
    print(f"[qwen3tts] geladen in {_load_s:.1f} s: {path}", flush=True)
    return model


def _unload() -> None:
    global _model, _model_path
    if _model is None:
        return
    _model, _model_path = None, None
    gc.collect()
    if torch.cuda.is_available():
        torch.cuda.empty_cache()


def _seed(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed % (2**32))
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)


def _language(model: FasterQwen3TTS, code: str) -> str:
    """'de' -> 'German' usw.; die Schreibweise nimmt das Modell aus seiner eigenen Liste."""
    name = LANGUAGES.get(code.lower(), code)
    getter = getattr(model.model.model, "get_supported_languages", None)
    supported = getter() if callable(getter) else None
    if supported:
        for s in supported:
            if s.lower() == name.lower():
                return s
        raise HTTPException(422, f"Sprache nicht unterstuetzt: {code}. Moeglich: {', '.join(sorted(supported))}")
    return name


REF_MAX_SECONDS = 20.0


def _decode(path: str) -> tuple[np.ndarray, int]:
    """Ton einer Datei als Mono-float32: WAV/FLAC/OGG per soundfile, alles andere (MP4, MKV, MP3, M4A ...) per PyAV
    aus dem venv von ComfyUI (liegt ueber QWEN3TTS_TORCH_SITE mit auf sys.path)."""
    try:
        data, sr = sf.read(path, dtype="float32", always_2d=True)
        return data.mean(axis=1), int(sr)
    except Exception:  # noqa: BLE001 - soundfile kennt keine Videos und kein MP3/AAC
        pass
    import av  # noqa: PLC0415

    chunks: list[np.ndarray] = []
    with av.open(path) as container:
        if not container.streams.audio:
            raise HTTPException(422, "Die Aufnahme hat keine Tonspur.")
        stream = container.streams.audio[0]
        sr = int(stream.rate or 24000)
        resampler = av.AudioResampler(format="flt", layout="mono", rate=sr)
        for frame in container.decode(stream):
            for out in resampler.resample(frame):
                chunks.append(out.to_ndarray().reshape(-1))
            if sum(c.shape[0] for c in chunks) > (REF_MAX_SECONDS + 5) * sr:
                break
    if not chunks:
        raise HTTPException(422, "Die Tonspur der Aufnahme ist leer.")
    return np.concatenate(chunks).astype(np.float32), sr


def _prepare_reference(path: str, ref_text: str, work: Path) -> tuple[str, str, str]:
    """Referenz fuer das Klonen: Mono-WAV, hoechstens REF_MAX_SECONDS. Laengeres wird gekuerzt; dann passt der Text
    nicht mehr, und es zaehlt nur der Stimmklang (x-vector). Gibt (Pfad, Text, Art) zurueck."""
    mono, sr = _decode(path)
    if mono.size < sr:
        raise HTTPException(422, "Die Aufnahme ist kuerzer als eine Sekunde; drei Sekunden und mehr sind gut.")
    trimmed = mono.shape[0] > REF_MAX_SECONDS * sr
    if trimmed:
        mono = mono[: int(REF_MAX_SECONDS * sr)]
        ref_text = ""
    work.mkdir(parents=True, exist_ok=True)
    out = work / "voice_reference.wav"
    sf.write(str(out), mono, sr, subtype="PCM_16", format="WAV")
    kind = "text" if ref_text else ("klang (gekuerzt)" if trimmed else "klang")
    return str(out), ref_text, kind


def _tidy(wav: np.ndarray, sr: int, peak_dbfs: float) -> tuple[np.ndarray, float]:
    """Raender kuerzen und Pegel angleichen, wie die Mac-App (SpeechEngine.tidy): Qwen3-TTS beginnt oder endet einen
    Satz je nach Seed mit Stille (gemessen bis 0,33 s vorn und 0,66 s hinten, auf dem Mac 0,87 s vorn), die Spitze lag
    1,5-8 dB unter -1 dBFS (Mac bis 11,6 dB). Stille: 20-ms-Fenster unter Spitze - 45 dB; 0,15 s Vorlauf und 0,3 s
    Nachlauf bleiben. Spitze auf peak_dbfs, hoechstens +20 dB."""
    peak = float(np.abs(wav).max())
    if peak <= 0:
        return wav, 0.0
    win = max(1, sr // 50)
    floor = peak * 10 ** (-45 / 20)
    n = wav.shape[0]
    nwin = (n + win - 1) // win
    pad = np.zeros(nwin * win, dtype=np.float32)
    pad[:n] = np.abs(wav)
    loud = np.nonzero(pad.reshape(nwin, win).max(axis=1) >= floor)[0]
    if loud.size:
        start = max(0, int(loud[0] * win - 0.15 * sr))
        end = min(n, int((loud[-1] + 1) * win + 0.3 * sr))
        wav = wav[start:end]
    gain = min(10 ** (peak_dbfs / 20) / peak, 10.0)
    return (wav * gain).astype(np.float32), round(20 * float(np.log10(gain)), 2)


def _dbfs(x: float) -> float:
    return round(20 * float(np.log10(max(x, 1e-9))), 2)


class GenerateRequest(BaseModel):
    mode: str = Field(..., pattern="^(design|clone)$", description="design = Stimme aus Beschreibung (VoiceDesign), "
                                                                  "clone = Stimme aus einer Aufnahme (Base)")
    model_path: str = Field(..., description="Ordner des passenden Modells (VoiceDesign bzw. Base)")
    text: str = Field(..., min_length=1, max_length=5000)
    output_path: str
    language: str = "auto"
    instruct: str = Field("", description="Beschreibung der Stimme (design)")
    ref_audio_path: str | None = Field(None, description="Referenzaufnahme (clone): Ton- oder Videodatei")
    ref_text: str | None = Field(None, description="Was in der Referenz gesagt wird; ohne: nur Stimmklang (x-vector)")
    work_dir: str | None = Field(None, description="Ordner fuer die aufbereitete Referenz (Standard: neben der Ausgabe)")
    seed: int | None = None
    max_new_tokens: int = Field(1900, ge=16, le=1990)  # statischer Cache 2048 inklusive Prompt
    temperature: float | None = Field(None, gt=0.0, le=2.0)
    top_p: float | None = Field(None, gt=0.0, le=1.0)
    peak_dbfs: float = Field(-1.0, le=0.0, description="Spitze danach (Pegel angleichen, hoechstens +20 dB)")


@app.get("/health")
def health() -> dict[str, Any]:
    info: dict[str, Any] = {
        "ok": True, "loaded": _model_path, "torch": torch.__version__,
        "torch_from": str(Path(torch.__file__).parent.parent), "cuda": torch.cuda.is_available(),
    }
    if torch.cuda.is_available():
        info["device"] = torch.cuda.get_device_name(0)
        info["vram_allocated_mb"] = round(torch.cuda.memory_allocated() / 2**20)
    return info


@app.post("/unload")
def unload() -> dict[str, bool]:
    with _lock:
        _unload()
    return {"ok": True}


@app.post("/cancel")
def cancel() -> dict[str, bool]:
    _cancel.set()
    return {"ok": True}


@app.post("/generate")
def generate(req: GenerateRequest) -> dict[str, Any]:
    with _lock:
        _cancel.clear()
        model = _load(req.model_path)
        lang = _language(model, req.language)
        gen: dict[str, Any] = {"max_new_tokens": req.max_new_tokens}
        if req.temperature is not None:
            gen["temperature"] = req.temperature
        if req.top_p is not None:
            gen["top_p"] = req.top_p
        seed = req.seed if req.seed is not None else random.randrange(2**31)
        _seed(seed)
        if torch.cuda.is_available():
            torch.cuda.reset_peak_memory_stats()
        t0 = time.time()
        try:
            if req.mode == "design":
                wavs, sr = model.generate_voice_design(text=req.text, instruct=req.instruct, language=lang, **gen)
            else:
                if not req.ref_audio_path or not Path(req.ref_audio_path).exists():
                    raise HTTPException(422, f"Referenzaufnahme fehlt: {req.ref_audio_path}")
                ref_path, ref_text, ref_mode = _prepare_reference(req.ref_audio_path, (req.ref_text or "").strip(),
                                                                  Path(req.work_dir or Path(req.output_path).parent / ".tts-ref"))
                wavs, sr = model.generate_voice_clone(text=req.text, language=lang, ref_audio=ref_path,
                                                      ref_text=ref_text, xvec_only=not ref_text, **gen)
        except _Cancelled:
            raise HTTPException(409, "abgebrochen") from None
        except ValueError as exc:  # falsches Modell fuer die Art, unbekannte Sprache u. ae.
            raise HTTPException(422, str(exc)) from exc
        finally:
            _cancel.clear()
        gen_s = time.time() - t0
        wav = np.asarray(wavs[0], dtype=np.float32).reshape(-1)
        if wav.size == 0 or not np.isfinite(wav).all():
            raise HTTPException(500, "Das Modell lieferte keinen gueltigen Ton.")
        peak = float(np.abs(wav).max())
        wav, gain_db = _tidy(wav, int(sr), req.peak_dbfs)
        out = Path(req.output_path)
        out.parent.mkdir(parents=True, exist_ok=True)
        tmp = out.with_name(out.name + ".part")
        sf.write(str(tmp), wav, sr, subtype="PCM_16", format="WAV")
        os.replace(tmp, out)
        seconds = wav.shape[0] / sr
        result = {
            "output_path": str(out), "sample_rate": int(sr), "seconds": round(seconds, 3), "seed": seed,
            "language": lang, "gen_s": round(gen_s, 2), "load_s": round(_load_s, 2),
            "speed": round(seconds / max(gen_s, 1e-3), 2),  # > 1 = schneller als Echtzeit
            "peak_dbfs_in": _dbfs(peak), "gain_db": gain_db, "rms_dbfs": _dbfs(float(np.sqrt(np.mean(wav ** 2)))),
        }
        if req.mode == "clone":
            result["ref_mode"] = ref_mode
        if torch.cuda.is_available():
            result["vram_peak_mb"] = round(torch.cuda.max_memory_allocated() / 2**20)
        print(f"[qwen3tts] {req.mode} {lang}: {seconds:.1f} s Ton in {gen_s:.1f} s", flush=True)
        return result


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="127.0.0.1", port=PORT, log_level="warning")
