"""Vertrag mit NV-AI: nutzt die Brücke nur Endpunkte und Felder, die NV-AI zusagt?

Grundlage ist ``contract/nvai-openapi.json``, eine Kopie von ``NV-AI/server/openapi.json``
(``info.x-api-version``). Liegt NV-AI daneben, wird zusätzlich gegen dessen aktuellen Stand
geprüft – eine brechende Änderung fällt so auf, bevor die Kopie erneuert wird
(``python tools/export_golden.py --refresh-contract``).

NV-AI ignoriert unbekannte Felder im Request still. Ein Tippfehler oder ein Feld, das es dort
(noch) nicht gibt, würde also nicht auffallen – deshalb zählt hier jedes Feld.
"""
from __future__ import annotations

import io
import json
import re
from pathlib import Path
from typing import Any

import httpx
import pytest
from PIL import Image

from bridge import config
from bridge.nvai import API_VERSION, NVAI

ROOT = Path(__file__).resolve().parent.parent
SNAPSHOT = ROOT / "contract" / "nvai-openapi.json"
LIVE = config.NVAI_ROOT / "server" / "openapi.json"
SWIFT_COPY = ROOT / "PhotoCraftKit" / "Tests" / "PhotoCraftKitTests" / "Golden" / "nvai-openapi.json"

VERSION = {"name": "NV-AI", "version": "0.2.0", "api": 1, "auth": "token", "authorized": True,
           "features": ["model_features", "mask", "references", "upsampler", "upload"]}

# Alles, was bridge/nvai.py bei NV-AI aufruft – der Test unten muss jede Zeile auslösen.
USED = {
    ("get", "/api/version"), ("get", "/api/health"), ("get", "/api/models"), ("get", "/api/assets"),
    ("get", "/api/assets/{asset_id}"), ("delete", "/api/assets/{asset_id}"), ("post", "/api/upload"),
    ("post", "/api/generate/image"), ("get", "/api/jobs/{job_id}"), ("delete", "/api/jobs/{job_id}"),
    ("post", "/api/jobs/current/cancel"), ("get", "/files/{filename}"),
}

# Antwortfelder, die Brücke und Swift-Port lesen. /api/health ist bewusst untypisiert (Diagnose,
# ändert sich oft) – dessen Felder werden tolerant gelesen und hier nicht geprüft.
READ_FIELDS = {
    "VersionInfo": {"version", "api", "features", "auth", "authorized"},
    "Job": {"id", "status", "progress", "stage", "error", "asset_ids"},
    "Asset": {"id", "kind", "url", "meta", "created_at"},
    "ModelInfo": {"id", "name", "workflow", "runnable", "features", "vram_gb", "commercial_ok", "warning",
                  "best_for"},
}


@pytest.fixture(params=[
    pytest.param(SNAPSHOT, id="kopie"),
    pytest.param(LIVE, id="nvai", marks=pytest.mark.skipif(not LIVE.exists(), reason="NV-AI liegt nicht daneben")),
])
def spec(request: pytest.FixtureRequest) -> dict[str, Any]:
    return json.loads(Path(request.param).read_text(encoding="utf-8"))


# ------------------------------------------------------- Schema-Prüfung

def resolve(spec: dict[str, Any], schema: dict[str, Any]) -> dict[str, Any]:
    while "$ref" in schema:
        schema = spec["components"]["schemas"][schema["$ref"].rsplit("/", 1)[-1]]
    return schema


def _type_ok(value: Any, t: str | None) -> bool:
    if t is None:
        return True
    if t == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if t == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    return isinstance(value, {"string": str, "boolean": bool, "array": list, "object": dict,
                              "null": type(None)}[t])


def violations(spec: dict[str, Any], value: Any, schema: dict[str, Any], where: str = "") -> list[str]:
    """Die Teile von JSON Schema, die FastAPI für NV-AI erzeugt – plus: keine unbekannten Felder."""
    schema = resolve(spec, schema)
    if "anyOf" in schema:
        options = [violations(spec, value, s, where) for s in schema["anyOf"]]
        return [] if any(not o for o in options) else min(options, key=len)
    if not _type_ok(value, schema.get("type")):
        return [f"{where}: {value!r} ist kein {schema['type']}"]
    errors = []
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{where}: {value!r} nicht in {schema['enum']}")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if value < schema.get("minimum", value) or value > schema.get("maximum", value):
            errors.append(f"{where}: {value} außerhalb [{schema.get('minimum')}, {schema.get('maximum')}]")
        if schema.get("multipleOf") and value % schema["multipleOf"]:
            errors.append(f"{where}: {value} kein Vielfaches von {schema['multipleOf']}")
    if isinstance(value, list):
        if len(value) > schema.get("maxItems", len(value)):
            errors.append(f"{where}: mehr als {schema['maxItems']} Einträge")
        for i, item in enumerate(value):
            errors += violations(spec, item, schema.get("items", {}), f"{where}[{i}]")
    if isinstance(value, dict) and "properties" in schema:
        props = schema["properties"]
        errors += [f"{where}.{k}: fehlt" for k in schema.get("required", []) if k not in value]
        for key, item in value.items():
            if key in props:
                errors += violations(spec, item, props[key], f"{where}.{key}")
            elif not schema.get("additionalProperties"):
                errors.append(f"{where}.{key}: unbekanntes Feld – nicht im Vertrag")
    return errors


def operation(spec: dict[str, Any], method: str, path: str) -> tuple[str, dict[str, Any]] | None:
    # Feste Pfade vor Platzhaltern („/api/jobs/current/cancel“ vor „/api/jobs/{job_id}“).
    for template in sorted(spec["paths"], key=lambda t: t.count("{")):
        pattern = "^" + re.sub(r"\{[^}]+\}", "[^/]+", template) + "$"
        if re.match(pattern, path) and method.lower() in spec["paths"][template]:
            return template, spec["paths"][template][method.lower()]
    return None


def request_problems(spec: dict[str, Any], request: httpx.Request) -> tuple[str | None, list[str]]:
    method, path = request.method.lower(), request.url.path
    found = operation(spec, method, path)
    if not found:
        return None, [f"{method.upper()} {path}: nicht im Vertrag"]
    template, op = found
    where = f"{method.upper()} {template}"
    known = {p["name"] for p in op.get("parameters", []) if p["in"] == "query"}
    problems = [f"{where}: Query-Parameter {q} unbekannt" for q in request.url.params if q not in known]
    content = op.get("requestBody", {}).get("content", {})
    ctype = request.headers.get("content-type", "")
    if ctype.startswith("application/json"):
        if "application/json" not in content:
            problems.append(f"{where}: nimmt kein JSON")
        else:
            problems += violations(spec, json.loads(request.content), content["application/json"]["schema"], where)
    elif ctype.startswith("multipart/form-data"):
        if "multipart/form-data" not in content:
            problems.append(f"{where}: nimmt kein multipart/form-data")
        else:
            schema = resolve(spec, content["multipart/form-data"]["schema"])
            sent = set(re.findall(rb'[;\s]name="([^"]+)"', request.content))  # nicht filename="…"
            fields = {f.decode() for f in sent}
            problems += [f"{where}: Feld {f} unbekannt" for f in fields - set(schema["properties"])]
            problems += [f"{where}: Feld {f} fehlt" for f in set(schema.get("required", [])) - fields]
    return template, problems


def _media_ok(declared: list[str], actual: str) -> bool:
    actual = actual.split(";")[0].strip()
    return any(d == actual or (d.endswith("/*") and actual.startswith(d[:-1])) for d in declared)


def response_problems(spec: dict[str, Any], request: httpx.Request, response: httpx.Response) -> list[str]:
    """Antwortet die Attrappe so, wie der Vertrag es zusagt? Sonst prüfen die Tests ins Leere."""
    found = operation(spec, request.method, request.url.path)
    if not found or response.status_code != 200:
        return []
    template, op = found
    where = f"Antwort {request.method} {template}"
    content = op.get("responses", {}).get("200", {}).get("content", {})
    ctype = response.headers.get("content-type", "")
    if not _media_ok(list(content), ctype):
        return [f"{where}: {ctype} nicht in {list(content)}"]
    schema = content.get("application/json", {}).get("schema")
    return violations(spec, response.json(), schema, where) if schema and ctype.startswith("application/json") else []


# ----------------------------------------------------------- NV-AI-Attrappe

def _golden_payloads() -> list[dict[str, Any]]:
    """Alle Requests, die die Planung erzeugt – samt Upload-ids, wie tasks.py sie ergänzt."""
    cases = json.loads((ROOT / "golden" / "planning.json").read_text(encoding="utf-8"))["plan"]
    out = []
    for case in cases:
        plan = case["out"]
        if "payload" not in plan:
            continue
        payload = dict(plan["payload"])
        if plan["send_image"]:
            if plan["technique"] == "reference":
                payload["reference_asset_ids"] = ["upload-1"]
            else:
                payload["image_asset_id"] = "upload-1"
            if plan["send_mask"]:
                payload["mask_asset_id"] = "upload-2"
        out.append(payload)
    return out


class FakeNVAI:
    """Antwortet wie NV-AI 0.2.0 laut Vertrag und merkt sich jede Anfrage."""

    def __init__(self, spec: dict[str, Any], version: dict[str, Any] | None = VERSION) -> None:
        self.spec = spec
        self.version = version
        self.requests: list[httpx.Request] = []
        self.responses: list[httpx.Response] = []
        now = 1_760_000_000.0
        self.asset = {"id": "a1", "job_id": "job-r", "kind": "image", "filename": "a1.png", "url": "/files/a1.png",
                      "thumb_url": None, "prompt": "", "model_id": "qwen-image-2512-nvfp4",
                      "meta": {"seed": 7, "model_name": "Qwen-Image 2512"}, "created_at": now}
        self.jobs = {jid: {"id": jid, "kind": "img2img", "status": status, "progress": 0.5, "stage": "", "params": {},
                           "asset_ids": ["a1"], "error": None, "created_at": now, "started_at": None,
                           "finished_at": None}
                     for jid, status in (("job-q", "queued"), ("job-r", "running"))}
        self.model = {"id": "qwen-image-2512-nvfp4", "name": "Qwen-Image 2512", "kind": "image", "family": "qwen",
                      "workflow": "qwen_image", "size_gb": 20.0, "license": "Apache-2.0", "commercial_ok": True,
                      "runnable": True, "features": {"img2img": True, "mask": True}}

    def __call__(self, request: httpx.Request) -> httpx.Response:
        response = self._answer(request)
        self.requests.append(request)
        self.responses.append(response)
        return response

    def _answer(self, request: httpx.Request) -> httpx.Response:
        method, path = request.method, request.url.path
        if path == "/api/version":
            return httpx.Response(200, json=self.version) if self.version else httpx.Response(404, json={"detail": "Not Found"})
        if path == "/openapi.json":
            return httpx.Response(200, json=self.spec)
        if path == "/api/health":
            return httpx.Response(200, json={"current_job": "job-r", "active_models": {"image": self.model["id"]}})
        if path == "/api/models":
            return httpx.Response(200, json=[self.model])
        if path == "/api/assets":
            return httpx.Response(200, json=[self.asset])
        if path.startswith("/api/assets/"):
            return httpx.Response(200, json=self.asset if method == "GET" else {"ok": True})
        if path == "/api/upload":
            return httpx.Response(200, json={**self.asset, "id": "upload-1", "kind": "upload", "job_id": None})
        if path == "/api/generate/image":
            return httpx.Response(200, json=self.jobs["job-r"])
        if path == "/api/jobs/current/cancel":
            return httpx.Response(200, json={"ok": True})
        if path.startswith("/api/jobs/"):
            job = self.jobs.get(path.rsplit("/", 1)[-1])
            if not job:
                return httpx.Response(404, json={"detail": "Job nicht gefunden"})
            return httpx.Response(200, json=job if method == "GET" else {"ok": True})
        if path.startswith("/files/"):
            buf = io.BytesIO()
            Image.new("RGB", (16, 16), (40, 90, 160)).save(buf, "PNG")
            return httpx.Response(200, content=buf.getvalue(), headers={"content-type": "image/png"})
        return httpx.Response(404, json={"detail": "Not Found"})


# ----------------------------------------------------------------- Tests

def test_contract_speaks_our_api_version(spec: dict[str, Any]) -> None:
    assert spec["info"]["x-api-version"] == API_VERSION


def test_swift_copy_is_current() -> None:
    assert SWIFT_COPY.exists(), "python tools/export_golden.py ausführen"
    assert json.loads(SWIFT_COPY.read_text(encoding="utf-8")) == json.loads(SNAPSHOT.read_text(encoding="utf-8"))


def test_fields_we_read_exist(spec: dict[str, Any]) -> None:
    schemas = spec["components"]["schemas"]
    for name, fields in READ_FIELDS.items():
        assert fields <= set(schemas[name]["properties"]), f"{name}: {fields - set(schemas[name]['properties'])}"


def test_planner_payloads_fit_request_schema(spec: dict[str, Any]) -> None:
    payloads = _golden_payloads()
    assert len(payloads) > 200
    schema = {"$ref": "#/components/schemas/GenerateImageRequest"}
    problems = sorted({p for payload in payloads for p in violations(spec, payload, schema, "payload")})
    assert not problems, problems[:20]


def test_client_requests_follow_contract(spec: dict[str, Any]) -> None:
    fake = FakeNVAI(spec)
    nv = NVAI("http://pc-name:8100", token="geheim", transport=httpx.MockTransport(fake))
    assert nv.check_compatible()["api"] == API_VERSION
    assert nv.supports_masks()
    nv.health()
    nv.image_models()
    nv.assets(kind="upload")
    upload = nv.upload(Image.new("RGB", (64, 64)), "photocraft-test-context.png")
    for payload in _golden_payloads():
        nv.generate_image(payload)
    nv.fetch_image(nv.asset(upload["id"]))
    nv.job("job-r")
    nv.cancel("job-q")  # wartend → DELETE /api/jobs/{id}
    nv.cancel("job-r")  # läuft gerade → POST /api/jobs/current/cancel
    nv.delete_asset(upload["id"])

    used, problems = set(), []
    for request, response in zip(fake.requests, fake.responses):
        template, found = request_problems(spec, request)
        used.add((request.method.lower(), template))
        problems += found + response_problems(spec, request, response)
    assert not sorted(set(problems)), sorted(set(problems))[:20]
    assert used == USED
    assert all(r.headers.get("x-nvai-token") == "geheim" for r in fake.requests)
