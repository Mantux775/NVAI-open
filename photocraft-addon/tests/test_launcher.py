"""Programmstart: Prozessliste robust lesen, WebView2 erkennen."""
from __future__ import annotations

import subprocess

from bridge import launcher, winutil


def _tasklist(monkeypatch, stdout: bytes) -> None:
    def fake_run(*args, **kwargs):
        return subprocess.CompletedProcess(args[0], 0, stdout=stdout, stderr=b"")

    monkeypatch.setattr(launcher.subprocess, "run", fake_run)


def test_no_photocraft_with_localized_message(monkeypatch):
    # Deutsche Meldung ohne Treffer, wie tasklist sie in der OEM-Codepage schreibt (ü = 0x81).
    message = "INFORMATION: Es werden keine Aufgaben mit den angegebenen Kriterien ausgeführt.\r\n"
    _tasklist(monkeypatch, message.encode("cp850"))
    assert launcher.photocraft_pids() == []


def test_photocraft_pids_from_csv(monkeypatch):
    _tasklist(monkeypatch, b'"photocraft.exe","2752","Console","1","412.400 K"\r\n'
                           b'"photocraft.exe","9120","Console","1","98.112 K"\r\n')
    assert launcher.photocraft_pids() == [2752, 9120]


def test_webview2_check_returns_bool():
    assert isinstance(winutil.webview2_available(), bool)
