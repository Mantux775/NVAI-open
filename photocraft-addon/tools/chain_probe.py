"""Prüft die komplette Steuerkette der Brücke gegen eine PhotoCraft-Testinstanz.

Nur Standardbibliothek (läuft mit Python 3.9 auf dem Mac mini wie unter Windows). Spielt
genau die Schritte nach, die bridge/tasks.py benutzt: Auswahl sichern, beschneiden, Ausschnitt
und Maske exportieren, Ergebnis öffnen, per layer.copyToDocument einfügen, Maske setzen,
Auswahl wiederherstellen, Variante tauschen, „Zuletzt geöffnet“ bereinigen.

usage: python3 chain_probe.py <port> <tokenfile> <exchange-dir>
Ausgabe: eine JSON-Zeile je Schritt plus Zusammenfassung; Dateien unter <exchange>/probe/.
"""
import json
import os
import socket
import struct
import sys
import time
import zlib

PORT, TOKEN_FILE, EXCHANGE = int(sys.argv[1]), sys.argv[2], sys.argv[3]
JOB = "probe"
os.makedirs(os.path.join(EXCHANGE, JOB), exist_ok=True)

sock = socket.create_connection(("127.0.0.1", PORT), timeout=70)
io = sock.makefile("rwb")
_rid = [0]
results = []


def call(method, params=None):
    _rid[0] += 1
    io.write((json.dumps({"id": _rid[0], "method": method, "params": params or {}}) + "\n").encode())
    io.flush()
    while True:
        reply = json.loads(io.readline())
        if reply.get("id") == _rid[0]:
            return reply


def step(name, method, params=None, expect_ok=True, show=None):
    t0 = time.time()
    reply = call(method, params)
    ms = int((time.time() - t0) * 1000)
    ok = bool(reply.get("ok")) == expect_ok
    shown = reply.get("result") if show is None else show(reply.get("result"))
    entry = {"step": name, "ok": ok, "ms": ms, "result": shown, "error": reply.get("error")}
    results.append(entry)
    print(json.dumps(entry, ensure_ascii=False)[:900])
    return reply.get("result")


def ex(name, command, params=None, **kw):
    return step(name, "engine.execute", {"command": command, "params": params or {}}, **kw)


def session():
    s = call("ui.inspect")["result"]
    return {"active": s["session"]["active"], "docs": [d["name"] for d in s["session"]["documents"]],
            "dirty": [d["dirty"] for d in s["session"]["documents"]], "dialogs": len(s.get("dialogs") or [])}


def doc():
    return call("engine.execute", {"command": "document.inspect"})["result"]


def png(path, w, h, pixel):
    raw = b"".join(b"\x00" + bytes(c for x in range(w) for c in pixel(x, y)) for y in range(h))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    with open(path, "wb") as fh:
        fh.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                 + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def png_size(path):
    with open(path, "rb") as fh:
        head = fh.read(26)
    return list(struct.unpack(">II", head[16:24])) + [head[25]]  # Breite, Höhe, Farbtyp


auth = call("auth", {"token": open(TOKEN_FILE).read().strip()})
print(json.dumps({"step": "auth", "ok": bool(auth.get("ok"))}))

# --- Testdokument wie unter Windows
ex("file.new", "file.new", {"width": 1200, "height": 800, "background": "white", "name": "Testbild"})
ex("layer.new.layer", "layer.new.layer", {"name": "Farbe"})
ex("stroke blau", "paint.stroke", {"points": [[100, 100, 1], [1100, 700, 1]], "size": 120, "color": "#2060ff"})
ex("stroke rot", "paint.stroke", {"points": [[100, 700, 1], [1100, 100, 1]], "size": 80, "color": "#ff4020"})
ex("select.rect ellipse", "select.rect", {"x": 400, "y": 250, "width": 300, "height": 220, "ellipse": True, "feather": 4})
d = doc()
results.append({"step": "selectionBounds", "result": d["selectionBounds"], "windows": [389, 239, 322, 242],
                "ok": d["selectionBounds"] == [389, 239, 322, 242]})
print(json.dumps(results[-1]))

# --- Erfassen
target = session()["active"]
dup = ex("image.duplicate mergedOnly", "image.duplicate", {"name": "NVAI-open Arbeitskopie", "mergedOnly": True})
results.append({"step": "nach duplicate", "result": session(), "dup_has_selection": doc()["hasSelection"]})
print(json.dumps(results[-1], ensure_ascii=False))
ex("select.saveSelection", "select.saveSelection", {"name": "NVAI-open Auswahl"})
ex("image.crop", "image.crop", {"x": 300, "y": 180, "width": 520, "height": 360})
d = doc()
results.append({"step": "nach crop", "size": [d["width"], d["height"]], "hasSelection": d["hasSelection"],
                "alpha": [c["name"] for c in d["channels"]["alpha"]]})
print(json.dumps(results[-1], ensure_ascii=False))
step("app.save context", "app.save", {"path": JOB + "/context.png"})
mask_doc = ex("channel.duplicate new", "channel.duplicate", {"channel": "NVAI-open Auswahl", "document": "new"})
results.append({"step": "nach channel.duplicate", "result": session()})
print(json.dumps(results[-1], ensure_ascii=False))
step("app.save mask", "app.save", {"path": JOB + "/mask.png"})
ex("file.close maske", "file.close", {"document": mask_doc["document"]})
ex("file.close arbeitskopie (dirty)", "file.close", {"document": dup["document"]})
s = session()
results.append({"step": "nach close", "result": s, "dialog_offen": s["dialogs"]})
print(json.dumps(results[-1], ensure_ascii=False))
step("window.document.N", "ui.menu.invoke", {"id": "window.document.%d" % target})
results.append({"step": "aktiv nach window.document", "result": session()["active"], "erwartet": target})
print(json.dumps(results[-1]))
for name in ("context.png", "mask.png"):
    p = os.path.join(EXCHANGE, JOB, name)
    results.append({"step": "datei " + name, "size_and_colortype": png_size(p), "bytes": os.path.getsize(p)})
    print(json.dumps(results[-1]))

# --- Einfügen (Variante 1)
png(os.path.join(EXCHANGE, JOB, "result-1.png"), 520, 360,
    lambda x, y: (250, 220, 40) if (x // 40 + y // 40) % 2 == 0 else (40, 160, 70))
png(os.path.join(EXCHANGE, JOB, "result-2.png"), 520, 360,
    lambda x, y: (200, 60, 200) if (x // 40 + y // 40) % 2 == 0 else (30, 30, 30))
recent_before = ex("prefs.get recent", "prefs.get", {"path": "fileHandling.recentFiles"})


def place(variant, old=None):
    if old is not None:
        ex("layer.select alt", "layer.select", {"layer": old})
    opened = step("app.open " + variant, "app.open", {"path": "%s/%s" % (JOB, variant)})
    temp = session()["active"]
    lid = doc()["layers"][0]["id"]
    copied = ex("layer.copyToDocument", "layer.copyToDocument",
                {"document": target, "source": temp, "layers": [lid], "offset": [300, 180], "name": "NVAI-open " + variant})
    ex("file.close temp", "file.close", {"document": temp})
    if session()["active"] != target:
        call("ui.menu.invoke", {"id": "window.document.%d" % target})
    new = copied["layers"][0]
    ex("revealSelection", "layer.layerMask.revealSelection", {"layer": new})
    results.append({"step": "auswahl nach reveal", "hasSelection": doc()["hasSelection"]})
    print(json.dumps(results[-1]))
    ex("loadSelection mask", "select.loadSelection", {"channel": "mask", "layer": new})
    d = doc()
    results.append({"step": "auswahl nach loadSelection", "hasSelection": d["hasSelection"], "bounds": d["selectionBounds"]})
    print(json.dumps(results[-1]))
    if old is not None:
        ex("layer.delete alt", "layer.delete", {"layer": old})
    return new, opened


first, opened = place("result-1.png")
recent_after = ex("prefs.get recent nach open", "prefs.get", {"path": "fileHandling.recentFiles"})
kept = [r for r in recent_after if not str(r).replace("\\", "/").startswith(JOB + "/")]
ex("prefs.set recent", "prefs.set", {"path": "fileHandling.recentFiles", "value": kept})
second, _ = place("result-2.png", old=first)
d = doc()
layers = [(layer["id"], layer["name"], layer["hasMask"], layer["bounds"]) for layer in d["layers"]]
results.append({"step": "ebenen am ende", "layers": layers, "history": d["history"][-8:], "session": session(),
                "recent": ex("prefs.get recent final", "prefs.get", {"path": "fileHandling.recentFiles"}),
                "recent_vorher": recent_before, "app.open_antwort": opened})
print(json.dumps(results[-1], ensure_ascii=False))
step("ui.screenshot", "ui.screenshot", {"path": JOB + "/shot.png"})

failed = [r["step"] for r in results if r.get("ok") is False]
print(json.dumps({"summary": {"steps": len(results), "failed": failed}}, ensure_ascii=False))
