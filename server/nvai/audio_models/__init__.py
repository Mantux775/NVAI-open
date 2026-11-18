"""Modell-Bausteine des Bereichs „Audio“ (seit 17.11.2026). Jeder Baustein läuft im ComfyUI-venv und liefert:
SAMPLE_RATE, CHANNELS, STEMS, CHUNK_SECONDS, OVERLAP_SECONDS, load(weights_dir, device, params) und
process(model, audio, params) -> {stem: (Proben, Kanäle) float32}. Den Rest (Abschnitte, Rate, Kanäle, Überblenden,
Fortsetzen) macht audio_tools.cmd_ai."""
