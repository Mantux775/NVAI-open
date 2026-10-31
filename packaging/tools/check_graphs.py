"""Prüft die ComfyUI-Graphen aller Katalogmodelle gegen /object_info, ohne etwas zu rechnen.

Findet fehlende Pflichteingänge, unbekannte Knoten und ungültige Auswahlwerte – die Fehlerart,
an der ACE-Step 1.5 mit ComfyUI 0.41.3 scheiterte.
    server\\.venv\\Scripts\\python.exe packaging\\tools\\check_graphs.py

Braucht ein laufendes ComfyUI auf 127.0.0.1:8188. Nach jedem ComfyUI-Update ausfuehren.
"""
import json
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "server"))
from nvai import registry, schemas, workflows  # noqa: E402

with urllib.request.urlopen("http://127.0.0.1:8188/object_info", timeout=60) as r:
    INFO = json.load(r)

REQUESTS = {
    "image": lambda: schemas.GenerateImageRequest(prompt="a wooden crate").model_dump(),
    "audio": lambda: schemas.GenerateAudioRequest(prompt="march, brass band").model_dump(),
    "video": lambda: {**schemas.GenerateVideoRequest(prompt="a torch flickering").model_dump(), "start_image": "dummy.png"},
}
BUILDERS = {"image": workflows.build_image, "audio": workflows.build_audio, "video": workflows.build_video}


def options(spec):
    """Auswahlwerte eines Combo-Eingangs (altes und neues object_info-Format)."""
    if isinstance(spec[0], list):
        return spec[0]
    if spec[0] == "COMBO" and len(spec) > 1 and isinstance(spec[1], dict):
        return spec[1].get("options")
    return None


# Zusatzwege, die ein eigener Graph sind: Krea 2 mit Stilvorlage (seit 0.5.10), LTX-2.5 mit Latent-Kette (seit 0.5.17).
CARRY = {"carry_video": "dummy.mp4", "carry_frames": 25}
VARIANTS = {"krea2_turbo": [("Stilvorlage", {"reference_images": ["dummy.png", "dummy2.png"]})],
            "ltx25": [("Latent-Kette", CARRY), ("Latent-Kette DFR", {**CARRY, "quality": "dfr"})]}
# MiniMax H3 (seit 0.5.18, minimax.py): 24 fps, Raster 17k+5; die Referenz-Fassung nimmt Referenzen statt Startbild.
# Geprueft werden auch die Vorwahl (Turbo-LoRA + sol-attn + INT8) und, wenn das Knotenpaket da ist, Veda.
MM = {"fps": 24, "frames": 124, "width": 864, "height": 480}
BASE = {"minimax_h3": MM, "minimax_h3_fast": MM,
        "minimax_h3_ref2va": {**MM, "start_image": None, "reference_images": ["dummy.png", "dummy2.png"]}}
MM_REC = {"sparse_attention": "sol-attn", "int8_attention": True}
VARIANTS |= {
    "minimax_h3": [("Vorwahl", {**MM_REC, "loras": [{"model_id": "minimax-h3-turbo-fl2v-8step-v1.1-768p"}]})]
    + ([("Veda", {"sparse_attention": "veda"})] if "VedaSparseAttention" in INFO else []),
    "minimax_h3_ref2va": [("Vorwahl", {**MM_REC, "loras": [{"model_id": "minimax-h3-turbo-ref2v-8step-v1.1-768p"}]})]
    + ([("Veda", {"sparse_attention": "veda"})] if "VedaSparseAttention" in INFO else []),
}


def check(graph):
    issues = []
    for node_id, node in graph.items():
        cls = node["class_type"]
        if cls not in INFO:
            issues.append(f"Knoten {node_id} {cls}: unbekannt")
            continue
        inputs = node.get("inputs", {})
        for name, spec in INFO[cls]["input"].get("required", {}).items():
            if name not in inputs:
                # Autogrow-Gruppen ("images.image_1" ...) mit min 0 duerfen ganz fehlen.
                if spec[0] == "COMFY_AUTOGROW_V3" and spec[1].get("template", {}).get("min", 1) == 0:
                    continue
                if any(k.startswith(name + ".") for k in inputs):
                    continue
                issues.append(f"Knoten {node_id} {cls}: Pflichteingang '{name}' fehlt")
                continue
            opts = options(spec)
            value = inputs[name]
            if opts and not isinstance(value, list) and value not in opts and not name.endswith(("_name", "_name1", "_name2", "_name3")) and name != "image":
                issues.append(f"Knoten {node_id} {cls}: '{name}'={value!r} nicht erlaubt")
    return issues


problems = 0
for entry in registry.all_entries():
    kind = entry.get("kind")
    if kind not in BUILDERS:
        continue
    for label, extra in [("", {})] + VARIANTS.get(entry.get("workflow"), []):
        p = REQUESTS[kind]() | BASE.get(entry.get("workflow"), {}) | extra
        name = f"{entry['id']} ({label})" if label else entry["id"]
        # Builder ausserhalb von workflows.py (MiniMax) laufen ueber workflows.build
        build = workflows.build if entry.get("workflow") in workflows.MODULE_BUILDERS else BUILDERS[kind]
        try:
            graph, _ = build(entry, p)
        except Exception as e:  # noqa: BLE001 - z. B. Startbild nötig
            print(f"{name}: nicht gebaut ({type(e).__name__}: {str(e)[:90]})")
            continue
        issues = check(graph)
        problems += len(issues)
        print(f"{name}: {'ok' if not issues else ''}")
        for i in issues:
            print("   ", i)
print("Probleme gesamt:", problems)
