"""NVAI-open -- lokale Asset-Generierung auf eigener GPU, mit MCP-Bruecke zu Claude Code."""

import os

__version__ = "0.5.16"

# Downloads ueber klassisches HTTP statt Xet (huggingface_hub >= 1.0): Xet laedt in Rust und
# meldet erst nach ~1 Minute und dann in 134-MB-Spruengen Fortschritt -- Fortschrittsbalken
# und Abbrechen haengen daran (gemessen 2026-10-21: ohne Xet alle 10 MB, Abbruch in 2 s).
# Muss vor dem ersten Import von huggingface_hub gesetzt sein, deshalb hier.
os.environ.setdefault("HF_HUB_DISABLE_XET", "1")
