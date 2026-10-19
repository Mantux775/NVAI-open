<#
  Sets up the bridge for development: venv with Python 3.12 and dependencies, then runs the tests.
  Uses uv if available (fast), otherwise venv + pip.
#>
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if (Get-Command uv -ErrorAction SilentlyContinue) {
    uv venv --python 3.12 .venv
    uv pip install --python .venv\Scripts\python.exe -r pyproject.toml --extra dev
} else {
    py -3.12 -m venv .venv
    .venv\Scripts\python.exe -m pip install --upgrade pip
    .venv\Scripts\python.exe -m pip install fastapi uvicorn httpx pillow pywebview pytest
}

.venv\Scripts\python.exe -m pytest -q
Write-Host "`nDone. Create the shortcut with: scripts\install_shortcut.ps1" -ForegroundColor Green
