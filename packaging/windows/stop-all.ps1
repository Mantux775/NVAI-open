<#
  Stops everything that runs from this program folder: NVAI-open, ComfyUI, mesh workers and the
  PhotoCraft bridge. Called by the setup before an update and by the uninstaller.

    stop-all.ps1 -App <install folder>

  First cleanly via the launcher (POST /api/shutdown, only if the NVAI-open on the port belongs
  to this installation), then only processes whose executable lives in <App> - never by name.
  A venv python.exe on Windows starts the base interpreter as a child process; that one lives
  in <App>\python and is caught as well.
#>
param([Parameter(Mandatory)] [string]$App)
$ErrorActionPreference = "SilentlyContinue"

$app = (Resolve-Path $App).Path.TrimEnd('\') + '\'
$launcher = Join-Path $App "server\.venv\Scripts\python.exe"
if (Test-Path $launcher) {
    # --quiet: no dialog - it would wait invisibly for a click and stall the uninstaller.
    & $launcher -m nvai.launcher --stop --quiet 2>&1 | Out-Null
}

$left = Get-CimInstance Win32_Process |
    Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($app, [StringComparison]::OrdinalIgnoreCase) }
foreach ($p in $left) {
    Write-Host "Stopping $($p.Name) (PID $($p.ProcessId))"
    Stop-Process -Id $p.ProcessId -Force
}
exit 0
