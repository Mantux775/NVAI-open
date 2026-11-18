"""Prüf-Baustein ohne Modell: liefert die Eingabe halbiert als „voice“ (für Tests der Abschnitts-Maschine)."""
SAMPLE_RATE = 44100
CHANNELS = 2
STEMS = ["voice"]
CHUNK_SECONDS = 7.0
OVERLAP_SECONDS = 1.0


def load(weights_dir, device, params):
    return None


def process(model, audio, params):
    return {"voice": audio * 0.5}
