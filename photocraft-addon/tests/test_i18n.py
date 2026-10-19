"""Sprache: Englisch als Standard, Deutsch als Option – für Texte, Ebenennamen und NV-AI."""
from __future__ import annotations

import json

import httpx
from fastapi.testclient import TestClient

from bridge import config, i18n, planning, server
from bridge.nvai import NVAI


def test_t_follows_the_choice(monkeypatch):
    assert i18n.t("Füllen", "Fill") == "Fill"
    i18n.set_choice("de")
    assert i18n.t("Füllen", "Fill") == "Füllen"
    assert planning.layer_name("refine", "make it blue", 1, 2) == "NV-AI Überarbeiten: make it blue (2)"
    i18n.set_choice("unbekannt")  # gilt als „auto“
    assert i18n.choice() == "auto"
    monkeypatch.setattr(i18n, "system_language", lambda: "de")
    i18n.set_choice("auto")
    assert i18n.lang() == "de"
    monkeypatch.setattr(i18n, "system_language", lambda: "en")
    i18n.set_choice("auto")
    assert i18n.lang() == "en"


def test_nvai_gets_accept_language():
    seen = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request.headers.get("accept-language"))
        return httpx.Response(200, json={"ok": True})

    nv = NVAI("http://nvai.test", transport=httpx.MockTransport(handler))
    nv.health()
    i18n.set_choice("de")
    nv.health()
    assert seen == ["en", "de"]


def test_language_choice_is_saved(monkeypatch, tmp_path):
    settings = tmp_path / "settings.json"
    settings.write_text(json.dumps({"nvai_token": "geheim"}), encoding="utf-8")
    monkeypatch.setattr(config, "SETTINGS_FILE", settings)
    monkeypatch.setattr(config, "_settings", {})
    monkeypatch.setattr(config, "DATA_DIR", tmp_path)
    monkeypatch.setattr(config, "ensure_dirs", lambda: None)
    monkeypatch.setattr(server, "state", lambda: {"lang": i18n.lang(), "language": i18n.choice()})
    client = TestClient(server.app)

    assert client.post("/api/language", json={"language": "de"}).json() == {"lang": "de", "language": "de"}
    assert json.loads(settings.read_text(encoding="utf-8")) == {"nvai_token": "geheim", "language": "de"}
    assert client.post("/api/language", json={"language": "fr"}).status_code == 422
