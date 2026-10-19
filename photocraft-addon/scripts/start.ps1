<#
  Starts NV-AI (if needed), PhotoCraft with its control channel, and the panel -
  the same as the shortcut "NV-AI for PhotoCraft".

  -Server   start only the bridge (panel at http://127.0.0.1:8120 in the browser)
#>
param([switch]$Server)
$root = Split-Path -Parent $PSScriptRoot
$py = Join-Path $root ".venv\Scripts\python.exe"
if (-not (Test-Path $py)) { throw "The venv is missing. Run scripts\setup.ps1 first." }

Push-Location $root
try {
    if ($Server) { & $py -m bridge --server } else { & $py -m bridge --launch }
} finally {
    Pop-Location
}
