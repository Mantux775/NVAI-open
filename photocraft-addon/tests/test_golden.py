"""Die Golden-Daten für den Swift-Port müssen zur Python-Referenz passen.

Schlägt dieser Test fehl, hat sich das Verhalten geändert: Ist das gewollt, mit
``python tools/export_golden.py`` neu erzeugen – und den Swift-Port nachziehen.
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

import export_golden  # noqa: E402


def _load(name: str):
    return json.loads((ROOT / "golden" / name).read_text(encoding="utf-8"))


def test_imaging_golden_is_current():
    assert export_golden.imaging_cases() == _load("imaging.json")


def test_planning_golden_is_current():
    assert export_golden.planning_cases() == _load("planning.json")


def test_sequences_golden_is_current():
    assert export_golden.sequences() == _load("sequences.json")
