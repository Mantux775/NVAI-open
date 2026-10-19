"""Gemeinsame Test-Einstellungen."""
from __future__ import annotations

import pytest

from bridge import i18n


@pytest.fixture(autouse=True)
def english():
    """Tests laufen auf Englisch, unabhängig von der Systemsprache; Deutsch prüft, wer es setzt."""
    before = i18n.choice()
    i18n.set_choice("en")
    yield
    i18n.set_choice(before)
