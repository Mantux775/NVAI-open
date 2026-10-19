"""Macht TRELLIS.2 mit transformers 5.x kompatibel.

DinoV3FeatureExtractor greift auf `self.model.layer` zu. In transformers 4.x lag
die ModuleList dort; ab 5.x steckt sie eine Ebene tiefer unter `self.model.model`.
Der Patch sucht sie an beiden Stellen, funktioniert also mit beiden Versionen.

Idempotent: mehrfaches Ausfuehren aendert nichts.
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = (Path(sys.argv[1]) if len(sys.argv) > 1
        else Path(__file__).resolve().parents[1] / "external" / "trellis2")

OLD = "        for i, layer_module in enumerate(self.model.layer):"
NEW = """        # transformers 4.x: model.layer -- ab 5.x liegt die ModuleList unter model.model
        blocks = getattr(self.model, "layer", None)
        if blocks is None:
            blocks = self.model.model.layer
        for i, layer_module in enumerate(blocks):"""

# BiRefNet: der Wrapper schiebt einen float32-Tensor in ein Modell, das die
# Pipeline vorher auf fp16 gesetzt hat -> "Input type (float) and bias type
# (c10::Half) should be the same". Input an das Modell-dtype angleichen.
BIREFNET_OLD = '        input_images = self.transform_image(image).unsqueeze(0).to("cuda")'
BIREFNET_NEW = """        # dtype vom Modell uebernehmen: die Pipeline setzt es auf fp16,
        # der Transform liefert aber immer float32.
        _dtype = next(self.model.parameters()).dtype
        input_images = self.transform_image(image).unsqueeze(0).to("cuda", _dtype)"""

birefnet = ROOT / "trellis2" / "pipelines" / "rembg" / "BiRefNet.py"
if birefnet.exists():
    text = birefnet.read_text(encoding="utf-8")
    if "_dtype = next(self.model.parameters())" in text:
        print("  bereits gepatcht: BiRefNet.py")
    elif BIREFNET_OLD in text:
        birefnet.write_text(text.replace(BIREFNET_OLD, BIREFNET_NEW), encoding="utf-8")
        print("  gepatcht: BiRefNet.py (dtype)")
    else:
        print("  Muster nicht gefunden: BiRefNet.py")

targets = [
    ROOT / "trellis2" / "modules" / "image_feature_extractor.py",
    ROOT / "trellis2" / "trainers" / "flow_matching" / "mixins" / "image_conditioned.py",
]

patched = 0
for path in targets:
    if not path.exists():
        print(f"  uebersprungen (fehlt): {path.name}")
        continue
    text = path.read_text(encoding="utf-8")
    if "blocks = getattr(self.model" in text:
        print(f"  bereits gepatcht: {path.name}")
        continue
    if OLD not in text:
        print(f"  Muster nicht gefunden: {path.name}")
        continue
    path.write_text(text.replace(OLD, NEW), encoding="utf-8")
    print(f"  gepatcht: {path.name}")
    patched += 1

print(f"\n{patched} Datei(en) angepasst")
