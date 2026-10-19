"""NV-AI und PhotoCraft finden: Registry des NV-AI-Setups, App Paths, Versionen, Startweg."""
from __future__ import annotations

import os
import re
from pathlib import Path

import pytest

from bridge import config, launcher, winutil

SETUP_KEY = {"InstallDir": r"C:\Users\Test\AppData\Local\Programs\NV-AI", "Version": "0.3.0",
             "DataDir": r"C:\Users\Test\AppData\Local\NV-AI", "Port": 8111}


def _registry(monkeypatch, values):
    monkeypatch.setattr(winutil, "registry_values",
                        lambda path, hive="HKCU": values if (path, hive) == (config.NVAI_REGISTRY_KEY, "HKCU") else None)


# ---------------------------------------------------------------- NV-AI

def test_nvai_install_from_setup_key(monkeypatch):
    _registry(monkeypatch, SETUP_KEY)
    install = config.nvai_install()
    assert install.install_dir == Path(SETUP_KEY["InstallDir"])
    assert install.start_script == Path(SETUP_KEY["InstallDir"]) / "nvai-start.cmd"
    assert (install.version, install.port) == ("0.3.0", 8111)
    assert install.data_dir == Path(SETUP_KEY["DataDir"])


@pytest.mark.parametrize("values", [None, {}, {"InstallDir": "  "}, {"Port": 8100}])
def test_no_setup_without_install_dir(monkeypatch, values):
    _registry(monkeypatch, values)
    assert config.nvai_install() is None


@pytest.mark.parametrize("port", [0, 70000, "8100", None])
def test_invalid_port_falls_back(monkeypatch, port):
    _registry(monkeypatch, {"InstallDir": r"C:\NV-AI", "Port": port, "DataDir": ""})
    install = config.nvai_install()
    assert install.port == 8100 and install.data_dir is None


def test_nvai_url_order(monkeypatch):
    install = config.NVAIInstall(Path(r"C:\NV-AI"), "0.3.0", None, 8111)
    monkeypatch.delenv("NVAI_URL", raising=False)
    monkeypatch.setattr(config, "_settings", {})
    assert config.resolve_nvai_url(None) == "http://127.0.0.1:8100"
    assert config.resolve_nvai_url(install) == "http://127.0.0.1:8111"
    monkeypatch.setattr(config, "_settings", {"nvai_url": "http://pc:8100/"})
    assert config.resolve_nvai_url(install) == "http://pc:8100"
    monkeypatch.setenv("NVAI_URL", "http://127.0.0.1:9000")
    assert config.resolve_nvai_url(install) == "http://127.0.0.1:9000"


def _dev_folder(tmp_path: Path) -> Path:
    dev = tmp_path / "dev"
    (dev / "scripts").mkdir(parents=True)
    (dev / "scripts" / "start.ps1").write_text("", encoding="ascii")
    return dev


@pytest.mark.parametrize("addon, dev, explicit, uses_setup", [
    (True, False, False, True),    # Tester-PC: Add-on des Setups
    (True, True, False, True),     # Add-on gehört zum Setup, auch wenn ein Entwicklungsordner da ist
    (False, True, False, False),   # Entwicklungsrechner: bleibt bei NV-AI aus dem Repository
    (False, False, False, True),   # aus dem Repository, aber nur das Setup vorhanden
    (True, True, True, False),     # NVAI_ROOT ausdrücklich gesetzt
])
def test_which_nvai_the_bridge_belongs_to(monkeypatch, tmp_path, addon, dev, explicit, uses_setup):
    _registry(monkeypatch, SETUP_KEY)
    monkeypatch.setattr(config, "ADDON", addon)
    monkeypatch.setattr(config, "NVAI_ROOT", _dev_folder(tmp_path) if dev else tmp_path / "kein-nvai")
    monkeypatch.setattr(config, "NVAI_ROOT_EXPLICIT", explicit)
    assert (config.nvai_setup() is not None) is uses_setup


@pytest.fixture
def local_nvai(monkeypatch, tmp_path):
    """NV-AI läuft nicht, liegt lokal; weder Setup noch Entwicklungsordner."""
    monkeypatch.setattr(config, "nvai_is_local", lambda: True)
    monkeypatch.setattr(launcher, "nvai_running", lambda: False)
    monkeypatch.setattr(launcher, "_nvai_started_at", None)
    monkeypatch.setattr(config, "NVAI_ROOT", tmp_path / "kein-nvai")
    monkeypatch.setattr(config, "nvai_setup", lambda: None)


def _setup(monkeypatch, folder: Path, script: str) -> Path:
    folder.mkdir(parents=True)
    (folder / "nvai-start.cmd").write_text(script, encoding="ascii")
    install = config.NVAIInstall(folder, "0.3.0", None, 8100)
    monkeypatch.setattr(config, "nvai_setup", lambda: install)
    return folder


def test_start_via_setup_script(local_nvai, monkeypatch, tmp_path):
    # Pfad mit Leerzeichen, & und Klammern: cmd muss ihn wörtlich nehmen.
    folder = _setup(monkeypatch, tmp_path / "NV AI & Co (Test)",
                    '@echo off\r\necho gestartet> "%~dp0started.txt"\r\n')
    assert launcher.nvai_starter() == ("setup", folder / "nvai-start.cmd")
    assert not launcher.nvai_start_pending()
    assert launcher.start_nvai() == "NV-AI is starting …"
    assert (folder / "started.txt").read_text().strip() == "gestartet"
    assert launcher.nvai_start_pending()


def test_setup_script_error_is_reported(local_nvai, monkeypatch, tmp_path):
    _setup(monkeypatch, tmp_path / "NV-AI", "@exit /b 3\r\n")
    with pytest.raises(launcher.LaunchError, match="code 3"):
        launcher.start_nvai()
    assert not launcher.nvai_start_pending()


def test_dev_start_without_setup(local_nvai, monkeypatch, tmp_path):
    dev = _dev_folder(tmp_path)
    monkeypatch.setattr(config, "NVAI_ROOT", dev)
    assert launcher.nvai_starter() == ("dev", dev / "scripts" / "start.ps1")
    _setup(monkeypatch, tmp_path / "NV-AI", "@exit /b 0\r\n")
    assert launcher.nvai_starter()[0] == "setup"


def test_nvai_not_installed(local_nvai):
    assert launcher.nvai_starter() is None
    with pytest.raises(launcher.LaunchError, match="not installed"):
        launcher.start_nvai()


# ------------------------------------------------------------ PhotoCraft

@pytest.fixture
def no_photocraft(monkeypatch, tmp_path):
    monkeypatch.delenv("PHOTOCRAFT_EXE", raising=False)
    monkeypatch.setattr(config, "_settings", {})
    monkeypatch.setattr(winutil, "app_path", lambda exe: None)
    monkeypatch.setenv("ProgramFiles", str(tmp_path / "Programme"))


def test_photocraft_from_app_paths(no_photocraft, monkeypatch, tmp_path):
    exe = tmp_path / "Woanders" / "photocraft.exe"
    exe.parent.mkdir()
    exe.write_bytes(b"")
    monkeypatch.setattr(winutil, "app_path", lambda name: exe if name == "photocraft.exe" else None)
    assert config.photocraft_exe() == exe


def test_photocraft_default_folder(no_photocraft, tmp_path):
    exe = tmp_path / "Programme" / "PhotoCraft" / "photocraft.exe"
    exe.parent.mkdir(parents=True)
    exe.write_bytes(b"")
    assert config.photocraft_exe() == exe


def test_photocraft_explicit_path(no_photocraft, monkeypatch, tmp_path):
    portable = tmp_path / "portable.exe"
    monkeypatch.setattr(config, "_settings", {"photocraft_exe": str(portable)})
    assert config.photocraft_exe() is None  # eingetragen, aber nicht da
    portable.write_bytes(b"")
    assert config.photocraft_exe() == portable


def test_missing_photocraft_names_download(no_photocraft, monkeypatch):
    monkeypatch.setattr(launcher, "port_open", lambda port, timeout=0.3: False)
    assert config.photocraft_exe() is None
    with pytest.raises(launcher.LaunchError, match=re.escape(config.PHOTOCRAFT_DOWNLOAD_URL)):
        launcher.start_photocraft()
    info = launcher.photocraft_install()
    assert info["installed"] is False and info["version"] is None and info["outdated"] is False
    assert info["download_url"] == config.PHOTOCRAFT_DOWNLOAD_URL


def test_outdated_photocraft(monkeypatch, tmp_path):
    monkeypatch.setattr(config, "photocraft_exe", lambda: tmp_path / "photocraft.exe")
    monkeypatch.setattr(winutil, "file_version", lambda path: "0.7.0")
    assert launcher.photocraft_install()["outdated"] is True
    monkeypatch.setattr(winutil, "file_version", lambda path: "0.10.0")
    assert launcher.photocraft_install()["outdated"] is False
    monkeypatch.setattr(winutil, "file_version", lambda path: None)  # ohne Versionsangabe kein Hinweis
    assert launcher.photocraft_install()["outdated"] is False


@pytest.mark.parametrize("version, reference, older", [
    ("0.7.0", "0.10.0", True), ("0.9", "0.10.0", True), ("0.10.0", "0.10.0", False),
    ("0.10.0.0", "0.10.0", False), ("0.10.1", "0.10.0", False), ("1.0", "0.10.0", False), ("unbekannt", "0.10.0", False),
])
def test_version_older(version, reference, older):
    assert config.version_older(version, reference) is older


# ------------------------------------------------------- echtes System

def test_registry_values_expands_paths():
    values = winutil.registry_values(r"Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders")
    assert values and "%" not in values["Desktop"]
    assert winutil.registry_values(r"Software\ArtCraft-LocalAI\gibt-es-nicht") is None


def test_installed_photocraft_has_version():
    exe = winutil.app_path("photocraft.exe")
    if not exe or not exe.is_file():
        pytest.skip("PhotoCraft ist hier nicht installiert")
    assert re.fullmatch(r"\d+\.\d+\.\d+(\.\d+)?", winutil.file_version(exe) or "")
    assert winutil.file_version(Path(os.environ["SystemRoot"]) / "win.ini") is None
