"""Silero VAD 6.2.3 (MIT): Sprachwahrscheinlichkeit je 32 ms bei 16 kHz. Das TorchScript-Modell trägt seinen Zustand
von Fenster zu Fenster; vor jedem neuen Abschnitt zurücksetzen."""
from __future__ import annotations

import numpy as np

SAMPLE_RATE = 16000
CHANNELS = 1
STEMS: list[str] = []
WINDOW = 512                     # Proben je Fenster (32 ms)


def load(weights_dir, device, params):
    import torch
    torch.set_num_threads(max(1, min(4, torch.get_num_threads())))
    model = torch.jit.load(str(weights_dir / "silero_vad.jit"), map_location="cpu")
    model.eval()
    return model


def probs(model, audio_16k: np.ndarray) -> np.ndarray:
    """Sprachwahrscheinlichkeit je 32-ms-Fenster für einen Abschnitt (Zustand vorher zurückgesetzt)."""
    import torch
    if hasattr(model, "reset_states"):
        model.reset_states()
    n = len(audio_16k) // WINDOW
    out = np.zeros(n, np.float32)
    x = torch.from_numpy(np.ascontiguousarray(audio_16k[: n * WINDOW], dtype=np.float32)).reshape(n, WINDOW)
    with torch.inference_mode():
        for i in range(n):
            out[i] = float(model(x[i:i + 1], SAMPLE_RATE).item())
    return out


def speech_spans(model, audio_16k: np.ndarray, threshold: float = 0.5, min_speech: float = 0.25,
                 min_gap: float = 0.4, pad: float = 0.15) -> list[tuple[float, float, float]]:
    """Sprachstrecken (Anfang, Ende in s, mittlere Wahrscheinlichkeit) innerhalb des Abschnitts."""
    p = probs(model, audio_16k)
    step = WINDOW / SAMPLE_RATE
    on = p > threshold
    spans: list[list[float]] = []
    i = 0
    while i < len(on):
        if on[i]:
            j = i
            while j < len(on) and on[j]:
                j += 1
            a, b = i * step, j * step
            if spans and a - spans[-1][1] < min_gap:
                spans[-1][1] = b
            else:
                spans.append([a, b])
            i = j
        else:
            i += 1
    total = len(audio_16k) / SAMPLE_RATE
    out = []
    for a, b in spans:
        if b - a < min_speech:
            continue
        ia, ib = int(a / step), max(int(a / step) + 1, int(b / step))
        out.append((max(0.0, a - pad), min(total, b + pad), float(p[ia:ib].mean())))
    return out
