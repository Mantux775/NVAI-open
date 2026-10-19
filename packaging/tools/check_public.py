"""Leak check before publishing: scans an export for secrets and private data.

    python packaging/tools/check_public.py <folder> [--extra <pattern> ...]

Exit code 1 if anything suspicious is found. The built-in patterns cover tokens and keys
(Hugging Face, GitHub, OpenAI/Anthropic style, App Store Connect, private key blocks),
private file types (.p12, .p8, .env, keychains), local absolute paths, private IP ranges and
e-mail addresses. Private names, IDs and paths that are not generic are passed with --extra,
so they never have to be written into this public file.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

PATTERNS = {
    "hugging face token": r"hf_[A-Za-z0-9]{30,}",
    "github token": r"gh[pousr]_[A-Za-z0-9]{30,}",
    "api key (sk-)": r"\bsk-[A-Za-z0-9_\-]{20,}",
    "private key block": r"-----BEGIN [A-Z ]*PRIVATE KEY-----",
    "app store connect key file": r"AuthKey_[A-Z0-9]{10}\.p8",
    "aws key": r"AKIA[0-9A-Z]{16}",
    "windows user path": r"[A-Za-z]:\\+Users\\+[A-Za-z0-9_.-]+",
    "mac user path": r"/Users/(?!<|\$|name|you|USER)[a-z][A-Za-z0-9_.-]+",
    "private ip": r"\b(?:192\.168|10\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}\b",
    "e-mail address": r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}",
    "password assignment": r"(?i)(password|passwort|kennwort)\s*[:=]\s*['\"][^'\"]{4,}",
}
# E-mail-like strings that are fine in a public repo (package metadata, examples).
ALLOWED_EMAILS = re.compile(r"(noreply|example|users\.noreply\.github)", re.I)
BAD_FILES = {".p12", ".p8", ".pem", ".key", ".keychain", ".keychain-db", ".mobileprovision", ".env"}
TEXT_SUFFIXES = {".py", ".ts", ".tsx", ".js", ".json", ".md", ".txt", ".ps1", ".cmd", ".sh",
                 ".swift", ".yml", ".yaml", ".toml", ".iss", ".html", ".css", ".plist", ".lock",
                 ".resolved", ".entitlements", ".ini", ""}


def main(argv: list[str]) -> int:
    root = Path(argv[0])
    extra = argv[argv.index("--extra") + 1:] if "--extra" in argv else []
    checks = dict(PATTERNS) | {f"private term {i + 1}": re.escape(e) for i, e in enumerate(extra)}
    hits = 0
    for f in sorted(root.rglob("*")):
        if not f.is_file() or ".git" in f.parts:
            continue
        rel = f.relative_to(root)
        if f.suffix.lower() in BAD_FILES:
            print(f"FILE TYPE  {rel}")
            hits += 1
            continue
        if f.suffix.lower() not in TEXT_SUFFIXES or f.stat().st_size > 5_000_000:
            continue
        text = f.read_text(encoding="utf-8", errors="replace")
        for label, pattern in checks.items():
            for m in re.finditer(pattern, text, flags=re.IGNORECASE if label.startswith("private term") else 0):
                if label == "e-mail address" and ALLOWED_EMAILS.search(m.group(0)):
                    continue
                if label == "e-mail address" and f.name == "package-lock.json":
                    continue
                line = text.count("\n", 0, m.start()) + 1
                print(f"{label:<26} {rel}:{line}: {m.group(0)[:60]}")
                hits += 1
    print(f"{hits} finding(s)")
    return 1 if hits else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
