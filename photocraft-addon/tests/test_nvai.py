"""NVAI-open-Client: Versionsprüfung, Masken-Erkennung und Token – ohne laufendes NVAI-open."""
from __future__ import annotations

import json

import httpx
import pytest

from bridge.nvai import NVAI, NVAIIncompatible, NVAIUnavailable
from tests.test_contract import SNAPSHOT, VERSION, FakeNVAI


def _client(version, token: str | None = None) -> tuple[NVAI, FakeNVAI]:
    fake = FakeNVAI(json.loads(SNAPSHOT.read_text(encoding="utf-8")), version)
    return NVAI("http://127.0.0.1:8100", token=token, transport=httpx.MockTransport(fake)), fake


def test_current_server_is_compatible_and_has_masks():
    nv, fake = _client(VERSION)
    assert nv.check_compatible()["version"] == "0.2.0"
    assert nv.supports_masks()
    nv.version()
    assert [r.url.path for r in fake.requests] == ["/api/version"]  # gemerkt, kein openapi.json


def test_features_without_mask_mean_no_masks():
    nv, _ = _client({**VERSION, "features": ["model_features", "references"]})
    assert not nv.supports_masks()


def test_other_api_version_is_refused():
    nv, _ = _client({**VERSION, "api": 2, "version": "1.0.0"})
    with pytest.raises(NVAIIncompatible, match="API version 2"):
        nv.check_compatible()


def test_unauthorized_is_reported_in_plain_words():
    nv, _ = _client({**VERSION, "authorized": False})
    with pytest.raises(NVAIIncompatible, match="token is missing or wrong"):
        nv.check_compatible()


def test_local_only_server_says_how_to_open_it():
    nv, _ = _client({**VERSION, "auth": "local", "authorized": False})
    with pytest.raises(NVAIIncompatible, match="own computer.*-Lan"):
        nv.check_compatible()


def test_server_before_0_2_falls_back_to_openapi():
    nv, fake = _client(None)  # /api/version → 404
    assert nv.version() is None
    assert nv.check_compatible() is None
    assert nv.supports_masks()  # laut openapi.json kennt GenerateImageRequest mask_asset_id
    assert "/openapi.json" in [r.url.path for r in fake.requests]


def test_unreachable_server_is_not_mistaken_for_an_old_one():
    def refuse(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("abgelehnt", request=request)

    nv = NVAI("http://127.0.0.1:8100", transport=httpx.MockTransport(refuse))
    with pytest.raises(NVAIUnavailable):
        nv.version()


def test_set_token_switches_header_and_forgets_version():
    nv, fake = _client({**VERSION, "authorized": False})
    with pytest.raises(NVAIIncompatible):
        nv.check_compatible()
    fake.version = VERSION
    nv.set_token("neu")
    assert nv.check_compatible()["authorized"]
    assert fake.requests[-1].headers["x-nvai-token"] == "neu"
    nv.set_token(None)
    nv.health()
    assert "x-nvai-token" not in fake.requests[-1].headers
