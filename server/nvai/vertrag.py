"""API-Vertrag: das OpenAPI-Schema der REST-API, festgehalten in server/openapi.json.

    python -m nvai.vertrag              # pruefen: bricht der jetzige Stand einen Client?
    python -m nvai.vertrag --schreiben  # server/openapi.json neu festhalten

Brechend ist, was ein bestehender Client merkt (Mac-App, PhotoCraft-Bruecke, iOS):
ein Endpunkt, eine Methode, ein Schema oder ein Feld faellt weg, ein Feld wechselt
den Typ, oder eine Anfrage verlangt ein neues Pflichtfeld. Dann muss
main.API_VERSION steigen. Neue Endpunkte und Felder brechen nichts -- sie gehoeren
in main.API_FEATURES, wenn ein Client vorher wissen muss, ob der Server sie kennt.
"""
from __future__ import annotations

import json
import sys
from typing import Any

from . import config
from .main import API_VERSION, app

SNAPSHOT = config.ROOT / "server" / "openapi.json"


def current() -> dict[str, Any]:
    schema = app.openapi()
    schema["info"]["x-api-version"] = API_VERSION
    return schema


def _type(prop: dict[str, Any]) -> str:
    """Typ einer Eigenschaft als vergleichbarer Text."""
    if "$ref" in prop:
        return prop["$ref"].rsplit("/", 1)[-1]
    if "anyOf" in prop:
        return "|".join(sorted(_type(p) for p in prop["anyOf"]))
    if prop.get("type") == "array":
        return f"list[{_type(prop.get('items', {}))}]"
    return prop.get("type", "any")


def _request_schemas(schema: dict[str, Any]) -> set[str]:
    names = set()
    for methods in schema.get("paths", {}).values():
        for op in methods.values():
            for media in op.get("requestBody", {}).get("content", {}).values():
                ref = media.get("schema", {}).get("$ref")
                if ref:
                    names.add(ref.rsplit("/", 1)[-1])
    return names


def breaking(old: dict[str, Any], new: dict[str, Any]) -> list[str]:
    found = []
    new_paths = new.get("paths", {})
    for path, methods in old.get("paths", {}).items():
        for method in methods:
            if method not in new_paths.get(path, {}):
                found.append(f"{method.upper()} {path} fehlt")
    old_schemas = old.get("components", {}).get("schemas", {})
    new_schemas = new.get("components", {}).get("schemas", {})
    requests = _request_schemas(new)
    for name, o in old_schemas.items():
        n = new_schemas.get(name)
        if n is None:
            found.append(f"Schema {name} fehlt")
            continue
        for field, prop in o.get("properties", {}).items():
            np = n.get("properties", {}).get(field)
            if np is None:
                found.append(f"{name}.{field} fehlt")
            elif _type(np) != _type(prop):
                found.append(f"{name}.{field}: Typ {_type(prop)} -> {_type(np)}")
        if name in requests:
            for field in sorted(set(n.get("required", [])) - set(o.get("required", []))):
                found.append(f"{name}.{field} ist neu Pflicht")
    return found


def main(argv: list[str]) -> int:
    sys.stdout.reconfigure(encoding="utf-8")
    new = current()
    if "--schreiben" in argv:
        SNAPSHOT.write_text(json.dumps(new, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
        print(f"{SNAPSHOT} festgehalten (API {API_VERSION}).")
        return 0
    if not SNAPSHOT.exists():
        print("Noch kein Vertrag festgehalten: python -m nvai.vertrag --schreiben")
        return 1
    old = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
    problems = breaking(old, new)
    old_api = old.get("info", {}).get("x-api-version")
    if problems and old_api == API_VERSION:
        print(f"Bricht den Vertrag API {API_VERSION}. Zuruecknehmen oder main.API_VERSION erhoehen:")
        for p in problems:
            print(f"  - {p}")
        return 1
    if new == old:
        print(f"Vertrag API {API_VERSION} unveraendert.")
        return 0
    if problems:
        print(f"API {old_api} -> {API_VERSION}, brechende Aenderungen:")
        for p in problems:
            print(f"  - {p}")
    else:
        print(f"Erweitert, ohne Clients zu brechen (API {API_VERSION}).")
    print("Festhalten mit: python -m nvai.vertrag --schreiben")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
