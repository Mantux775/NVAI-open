"""Was das Panel über PhotoCraft und NV-AI erfährt: installiert, Version, startbar, startet gerade."""
from __future__ import annotations

import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from bridge import config, launcher, server
from bridge.nvai import NVAIError
from bridge.photocraft import NotConnected


def _fail(exc):
    def raise_(*_args, **_kwargs):
        raise exc
    return raise_


@pytest.fixture
def client(monkeypatch):
    """Weder PhotoCraft noch NV-AI laufen; nichts aus vorherigen Abfragen zwischengespeichert."""
    for key in ("pc", "nv", "pc-install", "pids", "models"):
        server.cache.drop(key)
    monkeypatch.setattr(server.pc, "inspect", _fail(NotConnected("PhotoCraft läuft nicht.")))
    monkeypatch.setattr(server.nv, "health", _fail(NVAIError("NV-AI ist nicht erreichbar.")))
    monkeypatch.setattr(launcher, "photocraft_pids", lambda: [])
    monkeypatch.setattr(launcher, "nvai_running", lambda: False)
    monkeypatch.setattr(launcher, "_nvai_started_at", None)
    monkeypatch.setattr(config, "nvai_is_local", lambda: True)
    yield TestClient(server.app)
    for key in ("pc", "nv", "pc-install", "pids", "models"):
        server.cache.drop(key)


def test_missing_programs(client, monkeypatch):
    monkeypatch.setattr(config, "photocraft_exe", lambda: None)
    monkeypatch.setattr(launcher, "nvai_starter", lambda: None)
    state = client.get("/api/state").json()
    pc, nv = state["photocraft"], state["nvai"]
    assert (pc["connected"], pc["installed"], pc["outdated"]) == (False, False, False)
    assert pc["download_url"] == config.PHOTOCRAFT_DOWNLOAD_URL and pc["tested_version"] == "0.10.0"
    assert (nv["connected"], nv["startable"], nv["starting"]) == (False, False, False)

    answer = client.post("/api/nvai/start")
    assert answer.status_code == 409 and "not installed" in answer.json()["detail"]
    answer = client.post("/api/photocraft/start")
    assert answer.status_code == 409 and config.PHOTOCRAFT_DOWNLOAD_URL in answer.json()["detail"]


def test_outdated_photocraft_and_starting_nvai(client, monkeypatch, tmp_path):
    exe = tmp_path / "photocraft.exe"
    monkeypatch.setattr(config, "photocraft_exe", lambda: exe)
    monkeypatch.setattr(launcher.winutil, "file_version", lambda path: "0.7.0")
    monkeypatch.setattr(launcher, "nvai_starter", lambda: ("setup", Path("nvai-start.cmd")))
    monkeypatch.setattr(launcher, "_nvai_started_at", time.monotonic())
    state = client.get("/api/state").json()
    assert state["photocraft"]["installed"] and state["photocraft"]["outdated"]
    assert state["photocraft"]["version"] == "0.7.0" and state["photocraft"]["exe"] == str(exe)
    assert state["nvai"]["startable"] and state["nvai"]["starting"]


def test_download_link_opens_in_browser(client, monkeypatch):
    opened = []
    monkeypatch.setattr(server.os, "startfile", opened.append, raising=False)
    assert client.post("/api/open/photocraft-download").json() == {"ok": True}
    assert opened == [config.PHOTOCRAFT_DOWNLOAD_URL]


def test_expand_prompt_passes_text_through(client, monkeypatch):
    monkeypatch.setattr(server.nv, "check_compatible", lambda: {"api": 1})
    monkeypatch.setattr(server.nv, "supports_expand", lambda: True)
    monkeypatch.setattr(server.nv, "expand_prompt",
                        lambda prompt: {"prompt": prompt, "expanded": f"A forge with {prompt}.", "seconds": 13.2})
    answer = client.post("/api/expand", json={"prompt": "a blacksmith"})
    assert answer.json() == {"expanded": "A forge with a blacksmith.", "seconds": 13.2}


def test_expand_prompt_needs_a_current_nvai(client, monkeypatch):
    monkeypatch.setattr(server.nv, "check_compatible", lambda: {"api": 1})
    monkeypatch.setattr(server.nv, "supports_expand", lambda: False)
    answer = client.post("/api/expand", json={"prompt": "a blacksmith"})
    assert answer.status_code == 409 and "update NV-AI" in answer.json()["detail"]
