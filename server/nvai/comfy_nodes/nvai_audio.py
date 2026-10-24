"""NVAI-opens eigene ComfyUI-Knoten fuer Audio. NVAI-open kopiert diese Datei beim Start von ComfyUI nach
custom_nodes/ (comfy._install_nodes); ComfyUI laedt sie wie jede andere Erweiterung.

NVAIAudioLimiter: Spitzenbegrenzer vor dem Speichern. ACE-Step 1.5 liefert ungemasterten Klang mit
Spitzen bis +5,7 dBFS (gemessen 23.10.2026); der MP3-Encoder schneidet alles ueber 0 dB hart ab, das
klingt verzerrt und schwingt im MP3 wieder ueber. Der Limiter senkt nur die Spitzen ueber der Grenze ab:
Er schaut `lookahead_ms` voraus, damit die Absenkung schon vor dem Ausschlag beginnt, und regelt danach
mit `release_ms` weich zurueck. Was unter der Grenze bleibt, geht unveraendert durch.
"""
from __future__ import annotations

import numpy as np

try:  # ComfyUI stellt torch bereit; zum Testen geht es auch ohne
    import torch
except ImportError:  # pragma: no cover
    torch = None

BLOCK = 32  # Proben je Block fuer die Pegelkurve (bei 48 kHz 0,67 ms)


def gain_curve(x: np.ndarray, sample_rate: int, ceiling_db: float = -1.0, lookahead_ms: float = 5.0,
               release_ms: float = 80.0) -> np.ndarray:
    """Verstaerkung je Probe (<= 1), mit der x ([Kanaele, Proben]) unter ceiling_db bleibt.

    Sie entsteht blockweise und wird zwischen den Blockmitten linear verteilt. Gewaehrleistet ist die
    Grenze so: Jeder Block nimmt das Minimum des Bedarfs von einem Block davor bis `lookahead` Bloecke
    danach, darueber ein gleitender Mittelwert gleicher Laenge (sanfter Einsatz; vor dem Anfang mit dem
    ersten Wert aufgefuellt, sonst kaeme eine Spitze in den ersten Millisekunden durch) und ein Minimum
    ueber die Nachbarbloecke (fuer die Verteilung zwischen den Mitten). Die Rueckkehr darf nur
    langsamer sein, nie schneller.
    """
    ceil = 10.0 ** (ceiling_db / 20.0)
    channels, n = x.shape
    nb = -(-n // BLOCK)
    env = np.abs(np.pad(x, ((0, 0), (0, nb * BLOCK - n)))).reshape(channels, nb, BLOCK).max(axis=(0, 2))
    # in float64: mit float32 verlor der Mittelwert an der fuenften Stelle, die Grenze wurde um
    # 0,0004 dB ueberschritten (gemessen)
    need = np.minimum(1.0, ceil / np.maximum(env.astype(np.float64), 1e-9))

    la = max(1, int(round(lookahead_ms * sample_rate / 1000.0 / BLOCK)))
    window = np.lib.stride_tricks.sliding_window_view
    # Minimum ueber [k-1, k+la]
    g1 = window(np.pad(need, (1, la), constant_values=1.0), la + 2).min(axis=1)
    # gleitender Mittelwert ueber [k-la, k]: an jedem Ausschlag p liegen alle beteiligten g1 <= need[p]
    g2 = window(np.pad(g1, (la, 0), mode="edge"), la + 1).mean(axis=1)
    # Minimum ueber die Nachbarbloecke, damit die lineare Verteilung zwischen den Mitten haelt
    g3 = window(np.pad(g2, (1, 1), constant_values=1.0), 3).min(axis=1)

    r = float(np.exp(-BLOCK / (release_ms / 1000.0 * sample_rate)))
    g = np.empty(nb, dtype=np.float64)
    prev = 1.0
    for k in range(nb):
        prev = min(g3[k], 1.0 - (1.0 - prev) * r)
        g[k] = prev
    centres = np.arange(nb) * BLOCK + BLOCK / 2.0
    return np.interp(np.arange(n), centres, g).astype(np.float32)


def limit(x: np.ndarray, sample_rate: int, ceiling_db: float = -1.0, lookahead_ms: float = 5.0,
          release_ms: float = 80.0) -> tuple[np.ndarray, float]:
    """Begrenzt x ([Kanaele, Proben], float) auf ceiling_db. Gibt (Ergebnis, staerkste Absenkung in dB).
    Zum Schluss eine harte Grenze als Sicherung; die Verstaerkungskurve haelt sie schon selbst ein."""
    ceil = 10.0 ** (ceiling_db / 20.0)
    x = np.asarray(x, dtype=np.float32)
    if x.shape[1] == 0 or float(np.abs(x).max()) <= ceil:
        return x.copy(), 0.0
    gain = gain_curve(x, sample_rate, ceiling_db, lookahead_ms, release_ms)
    y = np.clip(x * gain, -ceil, ceil)
    return y, float(20.0 * np.log10(max(float(gain.min()), 1e-9)))


class NVAIAudioLimiter:
    """Spitzenbegrenzer fuer AUDIO (siehe Moduldoku)."""

    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {
            "audio": ("AUDIO",),
            "ceiling_db": ("FLOAT", {"default": -1.0, "min": -12.0, "max": 0.0, "step": 0.1}),
            "lookahead_ms": ("FLOAT", {"default": 5.0, "min": 0.5, "max": 50.0, "step": 0.5}),
            "release_ms": ("FLOAT", {"default": 80.0, "min": 5.0, "max": 2000.0, "step": 5.0}),
        }}

    RETURN_TYPES = ("AUDIO",)
    FUNCTION = "run"
    CATEGORY = "audio/NVAI-open"
    DESCRIPTION = "Begrenzt Spitzen auf ceiling_db, bevor gespeichert wird (NVAI-open)."

    def run(self, audio, ceiling_db, lookahead_ms, release_ms):
        wave = audio["waveform"]
        sr = int(audio["sample_rate"])
        out = []
        for item in wave:  # [Batch, Kanaele, Proben]
            y, _ = limit(item.float().cpu().numpy(), sr, ceiling_db, lookahead_ms, release_ms)
            out.append(torch.from_numpy(y).to(wave.dtype))
        return ({"waveform": torch.stack(out), "sample_rate": sr},)


NODE_CLASS_MAPPINGS = {"NVAIAudioLimiter": NVAIAudioLimiter}
NODE_DISPLAY_NAME_MAPPINGS = {"NVAIAudioLimiter": "NVAI-open Audio Limiter"}
