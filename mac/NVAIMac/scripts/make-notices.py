#!/usr/bin/env python3
"""Writes Resources/Third-Party-Notices.txt from the checked-out Swift packages.

    python3 scripts/make-notices.py [checkouts-dir] [Package.resolved] [output]

Defaults: ~/NVAIMac/SourcePackages/checkouts, ./Package.resolved,
./Resources/Third-Party-Notices.txt. Every package pinned in Package.resolved is listed with
its version, its license (identified from the license text itself, not assumed) and the full
license text; Apache-2.0 NOTICE files and the libraries vendored inside mlx-swift are included.
Fails if a pinned package has no license file.
"""
import json
import os
import re
import sys
from pathlib import Path

checkouts = Path(sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/NVAIMac/SourcePackages/checkouts"))
resolved = Path(sys.argv[2] if len(sys.argv) > 2 else "Package.resolved")
output = Path(sys.argv[3] if len(sys.argv) > 3 else "Resources/Third-Party-Notices.txt")

LICENSE_NAMES = re.compile(r"^(licen[cs]e|copying)(\.(md|txt|mit))?$", re.I)
NOTICE_NAMES = re.compile(r"^notice(\.(md|txt))?$", re.I)


def classify(text: str) -> str:
    if "Apache License" in text and "Version 2.0" in text:
        kind = "Apache License 2.0"
        if "Runtime Library Exception" in text:
            kind += " with Runtime Library Exception"
        return kind
    if "Permission is hereby granted, free of charge" in text:
        return "MIT License"
    if "Redistribution and use in source and binary forms" in text:
        return "BSD 3-Clause License" if "Neither the name" in text else "BSD 2-Clause License"
    raise SystemExit("Unknown license text: " + text[:80].replace("\n", " "))


def files_in(folder: Path, pattern) -> list:
    if not folder.is_dir():
        return []
    return sorted(p for p in folder.iterdir() if p.is_file() and pattern.match(p.name))


def read(p: Path) -> str:
    raw = p.read_bytes()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        text = raw.decode("latin-1")   # the LICENSE of mlx carries a Latin-1 copyright sign
    return text.strip() + "\n"


pins = json.loads(resolved.read_text(encoding="utf-8"))["pins"]
entries = []
for pin in sorted(pins, key=lambda p: p["identity"]):
    location = pin["location"].rstrip("/")
    folder_name = location.split("/")[-1].removesuffix(".git")
    folder = checkouts / folder_name
    licenses = files_in(folder, LICENSE_NAMES)
    if not licenses:
        raise SystemExit(f"No license file in {folder} ({pin['identity']})")
    text = read(licenses[0])
    state = pin["state"]
    version = state.get("version") or state.get("branch") or state.get("revision", "")[:12]
    notices = [read(n) for n in files_in(folder, NOTICE_NAMES)]
    vendored = []
    cmlx = folder / "Source" / "Cmlx"
    if cmlx.is_dir():
        for sub in sorted(cmlx.iterdir()):
            sub_licenses = files_in(sub, LICENSE_NAMES)
            if sub_licenses:
                sub_text = read(sub_licenses[0])
                vendored.append((sub.name, classify(sub_text), sub_text))
    entries.append((folder_name, version, classify(text), location, text, notices, vendored))

# Local copies under Packages/ (not in Package.resolved): name, version, origin, folder.
LOCAL = [
    ("flux-2-swift-mlx", "3.1.0 (local copy)", "https://github.com/VincentGourbin/flux-2-swift-mlx",
     "Packages/flux-2-swift-mlx"),
    ("seedvr2-mlx-swift", "1dfa161 (local copy)", "https://github.com/xocialize/seedvr2-mlx-swift",
     "Packages/seedvr2-mlx-swift"),
    ("speech-swift (Stable Audio 3)", "cbad3be (local copy)", "https://github.com/soniqo/speech-swift",
     "Packages/stable-audio-3-swift"),
    ("z-image-swift", "eadca87 (local copy)", "https://github.com/xocialize/z-image-swift",
     "Packages/z-image-swift"),
    ("ltx-video-swift-mlx", "0.4.2 (local copy)", "https://github.com/VincentGourbin/ltx-video-swift-mlx",
     "Packages/ltx-video-swift-mlx"),
]
for name, version, location, folder in LOCAL:
    licenses = files_in(Path(folder), LICENSE_NAMES)
    if not licenses:
        raise SystemExit(f"No license file in {folder}")
    text = read(licenses[0])
    entries.append((name, version, classify(text), location, text, [read(n) for n in files_in(Path(folder), NOTICE_NAMES)], []))
entries.sort(key=lambda e: e[0].lower())

rule = "-" * 78
out = [
    "NVAI-open for Mac - Third-Party Notices",
    "NVAI-open für Mac - Hinweise zu Komponenten von Dritten",
    "=" * 78,
    "",
    "NVAI-open is released under the MIT License. It includes the open-source software listed",
    "below; their licenses follow in full. AI models are not part of the app: NVAI-open downloads",
    "them on request and shows each model's license in its model list.",
    "",
    "NVAI-open steht unter der MIT-Lizenz. Es enthält die unten aufgeführte Open-Source-Software;",
    "deren Lizenztexte folgen vollständig. Modelle gehören nicht zur App: NVAI-open lädt sie auf",
    "Wunsch herunter und zeigt die Lizenz jedes Modells in der Modellliste.",
    "",
    "Components / Komponenten:",
    "",
]
for name, version, kind, location, _, _, vendored in entries:
    out.append(f"  {name} {version}: {kind}")
    out.append(f"      {location}")
    for sub, sub_kind, _ in vendored:
        out.append(f"      includes {sub}: {sub_kind}")
out.append("")
for name, version, kind, location, text, notices, vendored in entries:
    out += [rule, f"{name} {version}", f"{kind}", location, rule, "", text]
    for notice in notices:
        out += ["NOTICE:", "", notice]
    for sub, sub_kind, sub_text in vendored:
        out += [f"{name} includes {sub} ({sub_kind}):", "", sub_text]
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text("\n".join(out), encoding="utf-8")
print(f"{output}: {len(entries)} packages, {sum(len(e[6]) for e in entries)} vendored libraries")
