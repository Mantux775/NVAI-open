"""Nachbildung des PhotoCraft-Steuerkanals für Tests und Mitschnitte.

Bildet genau die Befehle nach, die die Brücke benutzt, mit dem Verhalten, das an PhotoCraft
0.10 unter Windows und macOS gemessen wurde (tools/chain_probe.py): Arbeitskopie übernimmt die
Auswahl, image.crop hebt sie auf, file.close per engine.execute fragt nicht nach und aktiviert
den Nachbar-Tab, app.open trägt sich unter „Zuletzt geöffnet“ ein, revealSelection hebt die
Auswahl auf.

Jeder Aufruf wird als ``{"request": …, "response": …}`` mitgeschnitten – daraus entstehen die
Befehlsfolgen in golden/sequences.json, gegen die der Swift-Port seinen Ablauf prüft.
"""
from __future__ import annotations

import copy
import struct
import zlib
from pathlib import Path
from typing import Any


class FakeError(RuntimeError):
    pass


def write_png(path: Path, w: int, h: int, gray: bool = False, value: int = 128) -> None:
    """Kleines PNG ohne Pillow (einfarbig) – genügt für Größe und Lesbarkeit."""
    channels = 1 if gray else 3
    row = b"\x00" + bytes([value]) * (w * channels)
    raw = row * h

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    color_type = 0 if gray else 2
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, color_type, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def png_size(path: Path) -> tuple[int, int]:
    head = path.read_bytes()[:24]
    return struct.unpack(">II", head[16:24])


class FakePhotoCraft:
    """Gleiche Schnittstelle wie bridge.photocraft.PhotoCraft (call/execute/inspect/document/activate)."""

    def __init__(self, exchange: Path) -> None:
        self.exchange = exchange
        self.docs: list[dict[str, Any]] = []
        self.active: int | None = None
        self.recent: list[str] = []
        self._next_layer = 100
        self.transcript: list[dict[str, Any]] = []
        self.canvas_steps: list[dict[str, Any]] = []

    # --------------------------------------------------------- Aufbau

    def add_document(self, name: str, width: int, height: int, selection: list[int] | None = None) -> int:
        self.docs.append({"name": name, "width": width, "height": height, "selection": selection,
                          "layers": [self._layer("Background", [0, 0, width, height])], "channels": [],
                          "dirty": False, "active_layer": None})
        self.active = len(self.docs) - 1
        self.docs[-1]["active_layer"] = self.docs[-1]["layers"][0]["id"]
        return self.active

    def _layer(self, name: str, bounds: list[int], mask: bool = False) -> dict[str, Any]:
        self._next_layer += 1
        return {"id": self._next_layer, "name": name, "hasMask": mask, "bounds": list(bounds), "kind": "Pixel",
                "visible": True}

    # ---------------------------------------------------- Schnittstelle

    def call(self, method: str, params: dict[str, Any] | None = None, *, read: bool = False) -> Any:
        params = params or {}
        result = self._dispatch(method, params)
        self.transcript.append({"request": {"method": method, "params": copy.deepcopy(params)},
                                "response": {"ok": True, "result": copy.deepcopy(result)}})
        return result

    def execute(self, command: str, params: dict[str, Any] | None = None, *, read: bool = False) -> Any:
        return self.call("engine.execute", {"command": command, "params": params or {}}, read=read)

    def inspect(self) -> dict[str, Any]:
        return self.call("ui.inspect", read=True)

    def document(self) -> dict[str, Any]:
        return self.execute("document.inspect", read=True)

    def activate(self, index: int) -> None:
        self.call("ui.menu.invoke", {"id": f"window.document.{index}"})

    # ------------------------------------------------------- Verhalten

    def _doc(self) -> dict[str, Any]:
        if self.active is None:
            raise FakeError("no document")
        return self.docs[self.active]

    def _doc_json(self, d: dict[str, Any]) -> dict[str, Any]:
        return {"name": d["name"], "width": d["width"], "height": d["height"],
                "hasSelection": d["selection"] is not None, "selectionBounds": d["selection"],
                "activeLayer": d["active_layer"], "layers": list(reversed(d["layers"])),
                "channels": {"alpha": [{"name": c} for c in d["channels"]]}}

    def _session(self) -> dict[str, Any]:
        return {"active": self.active, "documents": [
            {"index": i, "name": d["name"], "width": d["width"], "height": d["height"], "dirty": d["dirty"]}
            for i, d in enumerate(self.docs)]}

    def _dispatch(self, method: str, p: dict[str, Any]) -> Any:
        if method == "ui.inspect":
            return {"session": self._session(),
                    "document": self._doc_json(self._doc()) if self.active is not None else None,
                    "dialogs": []}
        if method == "ui.menu.invoke":
            index = int(p["id"].rsplit(".", 1)[1])
            self.active = index
            return {"document": index}
        if method == "app.save":
            d = self._doc()
            write_png(self.exchange / p["path"], d["width"], d["height"], gray=d.get("gray", False),
                      value=255 if d.get("gray") else 128)
            return {"path": p["path"], "warnings": []}
        if method == "app.open":
            w, h = png_size(self.exchange / p["path"])
            name = Path(p["path"]).name
            self.add_document(name, w, h)
            self.recent = [p["path"]] + [r for r in self.recent if r != p["path"]]
            return {"path": p["path"], "name": name, "warnings": []}
        if method == "engine.execute":
            return self._command(p["command"], p.get("params") or {})
        raise FakeError(f"unknown method `{method}`")

    def _command(self, c: str, p: dict[str, Any]) -> Any:
        d = self._doc() if self.active is not None else None
        if c == "document.inspect":
            return self._doc_json(d)
        if c == "image.duplicate":
            copy_ = {"name": p.get("name") or d["name"] + " copy", "width": d["width"], "height": d["height"],
                     "selection": d["selection"], "channels": [], "dirty": False,
                     "layers": [self._layer("Background", [0, 0, d["width"], d["height"]])] if p.get("mergedOnly")
                     else copy.deepcopy(d["layers"]), "active_layer": None}
            self.docs.append(copy_)
            self.active = len(self.docs) - 1
            return {"document": self.active, "name": copy_["name"]}
        if c == "select.saveSelection":
            d["channels"].append(p.get("name") or "Alpha 1")
            d["dirty"] = True
            return {"channel": len(d["channels"]) - 1, "document": self.active, "name": d["channels"][-1]}
        if c == "image.canvasSize":
            self.canvas_steps.append(dict(p))
            w = d["width"] + p["width"] if p.get("relative") else p["width"]
            h = d["height"] + p["height"] if p.get("relative") else p["height"]
            d.update(width=w, height=h, dirty=True)
            return {"width": w, "height": h, "offset": [0, 0]}
        if c == "image.crop":
            d.update(width=p["width"], height=p["height"], selection=None, dirty=True)
            return {"x": p["x"], "y": p["y"], "width": p["width"], "height": p["height"],
                    "documentWidth": p["width"], "documentHeight": p["height"], "resolution": 72.0}
        if c == "channel.duplicate":
            self.add_document(f"{p['channel']} copy", d["width"], d["height"])
            self.docs[-1]["gray"] = True
            return {"document": self.active}
        if c == "file.close":
            index = int(p.get("document", self.active))
            self.docs.pop(index)
            if not self.docs:
                self.active = None
            elif self.active is not None and self.active >= index:
                self.active = max(0, min(self.active - (self.active > index), len(self.docs) - 1))
            return None
        if c == "prefs.get":
            return list(self.recent)
        if c == "prefs.set":
            self.recent = list(p["value"])
            return {p["path"]: p["value"]}
        if c == "layer.select":
            d["active_layer"] = p["layer"]
            return None
        if c == "layer.copyToDocument":
            src = self.docs[int(p["source"])]
            dest = self.docs[int(p["document"])]
            new_ids = []
            for lid in p["layers"]:
                layer = next(item for item in src["layers"] if item["id"] == lid)
                x, y = p.get("offset", [0, 0])
                new = self._layer(p.get("name") or layer["name"],
                                  [layer["bounds"][0] + x, layer["bounds"][1] + y, layer["bounds"][2], layer["bounds"][3]])
                pos = next((i for i, item in enumerate(dest["layers"]) if item["id"] == dest["active_layer"]),
                           len(dest["layers"]) - 1)
                dest["layers"].insert(pos + 1, new)
                dest["active_layer"] = new["id"]
                new_ids.append(new["id"])
            self.active = int(p["document"])
            return {"document": self.active, "layers": new_ids, "offset": p.get("offset", [0, 0])}
        if c == "layer.layerMask.revealSelection":
            layer = next(item for item in d["layers"] if item["id"] == p["layer"])
            layer["hasMask"], layer["mask_bounds"] = True, d["selection"]
            d["selection"] = None
            return None
        if c == "select.loadSelection":
            layer = next(item for item in d["layers"] if item["id"] == p["layer"])
            d["selection"] = layer.get("mask_bounds")
            return None
        if c == "layer.delete":
            d["layers"] = [item for item in d["layers"] if item["id"] != p["layer"]]
            return None
        raise FakeError(f"unknown command `{c}`")
