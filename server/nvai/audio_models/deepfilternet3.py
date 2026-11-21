"""DeepFilterNet3 (Hendrik Schröter u. a., Code und Gewichte MIT oder Apache-2.0): Sprache entrauschen bei 48 kHz,
nur CPU, ohne PyTorch. Gerechnet wird mit der C-Schnittstelle von libDF (capi.rs) per ctypes: Die Bibliothek
(deepfilter.dll/.so/.dylib) bringt das Paket deepfilternet-slim 0.1.0 mit (gebaut aus Rikorose/DeepFilterNet,
Commit d375b2d8309e0935d165700c91da9de862a99c31), das Modell DeepFilterNet3_onnx.tar.gz liegt im Gewichte-Ordner.

Das Modell ist mono und arbeitet in Schritten zu 10 ms: Jeder Kanal bekommt einen eigenen Zustand (Stereo bleibt
erhalten), beide laufen parallel (ctypes gibt die GIL frei). Je Fenster ein frischer Zustand mit 2 s gespiegeltem
Vorlauf zum Einschwingen; die Verzögerung (STFT + Vorschau, 1440 Proben) wird abgezogen, damit „removed“
(Mischung minus „clean“) genau passt. Einstellungen: atten_lim_db (höchstens so viel dämpfen, 100 = voll,
12–24 klingt natürlicher), post_filter_beta (0 = aus, bis 0,05 dämpft Restrauschen stärker)."""
from __future__ import annotations

import configparser
import ctypes
import hashlib
import math
import os
import tarfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np

try:
    from . import L
except ImportError:  # einzeln geladen, ohne das Paket audio_models
    def L(de: str, en: str) -> str:
        return de

SAMPLE_RATE = 48000
CHANNELS = 2
STEMS = ["clean"]
CHUNK_SECONDS = 60.0
OVERLAP_SECONDS = 2.0

MODEL_FILE = "DeepFilterNet3_onnx.tar.gz"
MODEL_SHA256 = "c94d91f70911001c946e0fabb4aa9adc37045f45a03b56008cb0c8244cb63616"
WARMUP_SECONDS = 2.0


class _DF:
    def __init__(self, lib: ctypes.CDLL, model: Path, hop: int, delay: int) -> None:
        self.lib = lib
        self.model = os.fspath(model).encode("utf-8")
        self.hop = hop
        self.delay = delay


def _bind(lib: ctypes.CDLL) -> None:
    lib.df_create.argtypes = [ctypes.c_char_p, ctypes.c_float, ctypes.c_char_p]
    lib.df_create.restype = ctypes.c_void_p
    lib.df_get_frame_length.argtypes = [ctypes.c_void_p]
    lib.df_get_frame_length.restype = ctypes.c_size_t
    lib.df_set_post_filter_beta.argtypes = [ctypes.c_void_p, ctypes.c_float]
    lib.df_set_post_filter_beta.restype = None
    lib.df_process_frame.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
    lib.df_process_frame.restype = ctypes.c_float
    lib.df_free.argtypes = [ctypes.c_void_p]
    lib.df_free.restype = None


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for part in iter(lambda: f.read(1 << 20), b""):
            h.update(part)
    return h.hexdigest()


def load(weights_dir, device, params):
    # device wird bewusst übergangen: libDF rechnet nur auf der CPU
    try:
        import deepfilternet_slim
    except ImportError:
        raise SystemExit(L("DeepFilterNet3 braucht das Paket deepfilternet-slim 0.1.0 im Audio-venv.",
                           "DeepFilterNet3 needs the package deepfilternet-slim 0.1.0 in the audio venv.")) from None
    model = Path(weights_dir) / MODEL_FILE
    if not model.is_file():
        model = deepfilternet_slim.model_path()  # gleiche Datei, im Paket mitgeliefert
    # Eine kaputte Datei bringt libDF zum Absturz (panic über FFI), deshalb vorher prüfen
    if _sha256(model) != MODEL_SHA256:
        raise SystemExit(L(f"DeepFilterNet3: Modelldatei beschädigt ({model}). Bitte neu laden.",
                           f"DeepFilterNet3: model file damaged ({model}). Please download it again."))
    with tarfile.open(model) as t:
        member = next(m for m in t.getmembers() if m.name.endswith("config.ini"))
        cfg = configparser.ConfigParser()
        cfg.read_string(t.extractfile(member).read().decode("utf-8"))
    fft = cfg.getint("df", "fft_size")
    hop = cfg.getint("df", "hop_size")
    look = max(cfg.getint("df", "df_lookahead"), cfg.getint("deepfilternet", "conv_lookahead"))
    lib = deepfilternet_slim.load_library()
    _bind(lib)
    df = _DF(lib, model, hop, fft - hop + look * hop)  # wie enhance_wav.rs (compensate_delay)
    st = lib.df_create(df.model, ctypes.c_float(100.0), None)
    try:
        if lib.df_get_frame_length(st) != hop:
            raise SystemExit(L("DeepFilterNet3: unerwartete Schrittweite der Bibliothek.",
                               "DeepFilterNet3: unexpected hop size of the library."))
    finally:
        lib.df_free(st)
    return df


def _channel(df: _DF, x: np.ndarray, atten: float, beta: float) -> np.ndarray:
    """Ein Kanal mit frischem Zustand: Vorlauf gespiegelt, Ende mit Nullen ausspülen, Verzögerung abziehen."""
    n = len(x)
    warm = min(int(WARMUP_SECONDS * SAMPLE_RATE), max(0, n - 1))
    pre = np.pad(x, (warm, 0), mode="reflect")[:warm] if warm else np.zeros(0, np.float32)
    # libDF überspringt nach 5 stillen Schritten; Verzögerung + 1 Schritt Nullen liegen sicher darunter
    total = math.ceil((warm + n + df.delay + df.hop) / df.hop) * df.hop
    buf = np.zeros(total, np.float32)
    buf[:warm] = pre
    buf[warm:warm + n] = x
    out = np.zeros(total, np.float32)
    lib, hop = df.lib, df.hop
    st = lib.df_create(df.model, ctypes.c_float(atten), None)
    try:
        if beta > 0:
            lib.df_set_post_filter_beta(st, ctypes.c_float(beta))
        ip, op, step = buf.ctypes.data, out.ctypes.data, 4 * hop
        f = lib.df_process_frame
        for i in range(total // hop):
            f(st, ip + i * step, op + i * step)
    finally:
        lib.df_free(st)
    s = warm + df.delay
    return out[s:s + n]


def process(model, audio, params):
    df: _DF = model
    atten = min(100.0, max(0.0, float(params.get("atten_lim_db", 100.0))))
    beta = min(0.1, max(0.0, float(params.get("post_filter_beta", 0.0))))
    x = np.ascontiguousarray(audio, dtype=np.float32)
    if atten < 0.01 or len(x) < 2:
        return {"clean": x.copy()}  # 0 dB: libDF reicht nur durch
    chans = [np.ascontiguousarray(x[:, c]) for c in range(x.shape[1])]
    if len(chans) == 2 and np.array_equal(chans[0], chans[1]):
        y = _channel(df, chans[0], atten, beta)  # Doppel-Mono nur einmal rechnen
        return {"clean": np.stack([y, y], axis=1)}
    with ThreadPoolExecutor(max_workers=len(chans)) as ex:
        ys = list(ex.map(lambda c: _channel(df, c, atten, beta), chans))
    return {"clean": np.stack(ys, axis=1)}
