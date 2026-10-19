# Richtet den Orchestrator + MCP-Server ein (eigenes venv, ohne Torch).
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$server = Join-Path $repo "server"

Write-Host "== Server-venv (Python 3.12) ==" -ForegroundColor Cyan
uv venv --python 3.12 (Join-Path $server ".venv")
$py = Join-Path $server ".venv\Scripts\python.exe"
uv pip install --python $py -e $server

Write-Host "`nFertig. Start: scripts\start.ps1" -ForegroundColor Green
Write-Host "MCP registrieren:" -ForegroundColor Yellow
Write-Host "  claude mcp add nvai -- `"$py`" -m nvai.mcp_server"
