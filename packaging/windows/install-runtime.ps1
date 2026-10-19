<#
  Sets up the Python environments of the installed NV-AI.
  Called by the setup after copying the files; also runs on its own as "Repair NV-AI".

    install-runtime.ps1 -App <install folder> -DataDir <data folder> [-With3D] [-WithAddon]

  Everything comes from the pinned package lists in locks\ (with sha256 hashes): the same
  versions that were tested. uv fetches Python itself as a standalone build into <App>\python,
  nothing has to be preinstalled. Log: <DataDir>\install.log
  Messages follow the Windows display language (German or English). ASCII only: Windows
  PowerShell 5.1 reads scripts without BOM as ANSI.
#>
param(
    [Parameter(Mandatory)] [string]$App,
    [Parameter(Mandatory)] [string]$DataDir,
    [switch]$WithAddon,
    [switch]$With3D
)
$ErrorActionPreference = "Stop"
$PythonVersion = "3.12.13"
$German = (Get-UICulture).TwoLetterISOLanguageName -eq "de"
function L($de, $en) { if ($German) { $de } else { $en } }

New-Item -ItemType Directory -Force $DataDir | Out-Null
Start-Transcript -Path (Join-Path $DataDir "install.log") -Append | Out-Null

$uv = Join-Path $App "tools\uv.exe"
# Python and the package cache stay in the program folder: uninstalling removes them, and
# nothing ends up scattered across the user profile.
$env:UV_PYTHON_INSTALL_DIR = Join-Path $App "python"
# NVAI_UV_CACHE: only for test installs on a development machine - the 3 GB then come from
# the existing cache, and that cache is NOT cleaned at the end.
$ownCache = -not $env:NVAI_UV_CACHE
$env:UV_CACHE_DIR = if ($ownCache) { Join-Path $App ".uv-cache" } else { $env:NVAI_UV_CACHE }
$env:UV_NO_CONFIG = "1"
# Only ever use the Python in <App>\python, never one the user installed.
$env:UV_PYTHON_PREFERENCE = "only-managed"
$env:UV_LINK_MODE = "copy"

function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }

function Uv {
    # Out-Host: otherwise uv's stdout ends up in the return value of New-Venv.
    & $uv @args | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "uv $($args[0]) $($args[1]) failed (exit $LASTEXITCODE)." }
}

function New-Venv($dir, $lock, [string[]]$extra = @()) {
    $py = Join-Path $dir "Scripts\python.exe"
    if (-not (Test-Path $py)) { Uv venv --python $PythonVersion $dir }
    Uv pip sync --python $py --require-hashes @extra $lock
    return $py
}

try {
    Write-Host (L "NV-AI wird eingerichtet. Beim ersten Mal laedt das rund 3 GB (vor allem PyTorch)." `
                  "Setting up NV-AI. The first time this downloads about 3 GB (mostly PyTorch).")
    Write-Host (L "Je nach Leitung dauert das 5 bis 20 Minuten. Dieses Fenster schliesst sich am Ende selbst." `
                  "Depending on your connection this takes 5 to 20 minutes. This window closes by itself.")

    Step "Python $PythonVersion"
    # --no-bin/--no-registry: otherwise uv puts a python3.12.exe into ~\.local\bin and adds a
    # registry entry - traces outside the program folder (measured).
    Uv python install --no-bin --no-registry $PythonVersion

    Step (L "NV-AI-Server" "NV-AI server")
    $serverPy = New-Venv (Join-Path $App "server\.venv") (Join-Path $App "locks\server.lock")
    # Editable install: config.ROOT then points to the program folder, where frontend\dist
    # and external\comfyui are found.
    Uv pip install --python $serverPy --no-deps -e (Join-Path $App "server")

    Step (L "ComfyUI mit PyTorch (CUDA 13) - der grosse Teil" "ComfyUI with PyTorch (CUDA 13) - the big part")
    $comfyPy = New-Venv (Join-Path $App "external\comfyui\.venv") (Join-Path $App "locks\comfyui.lock") `
        @("--index-strategy", "unsafe-best-match")

    if ($With3D) {
        # Same PyTorch build as ComfyUI (2.11 + CUDA 13): comes from the cache, no second download.
        Step (L "3D (TripoSG)" "3D (TripoSG)")
        New-Venv (Join-Path $App "external\triposg\.venv") (Join-Path $App "locks\triposg.lock") `
            @("--index-strategy", "unsafe-best-match") | Out-Null
    }

    if ($WithAddon) {
        Step (L "PhotoCraft-Add-on" "PhotoCraft add-on")
        New-Venv (Join-Path $App "addon\.venv") (Join-Path $App "addon\requirements.lock") | Out-Null
    }

    Step (L "Grafikkarte pruefen" "Checking the graphics card")
    & $comfyPy -c "import torch; ok = torch.cuda.is_available(); print('CUDA:', ok); print('GPU:', torch.cuda.get_device_name(0) if ok else '-')"
    if ($LASTEXITCODE -ne 0) {
        Write-Warning (L "PyTorch-Test fehlgeschlagen. NV-AI startet trotzdem; Details im Protokoll." `
                         "PyTorch check failed. NV-AI starts anyway; details in the log.")
    }

    if ($ownCache) {
        Step (L "Aufraeumen" "Cleaning up")
        & $uv cache clean | Out-Null
    }

    Write-Host "`n$(L 'Fertig.' 'Done.')" -ForegroundColor Green
    Stop-Transcript | Out-Null
    exit 0
} catch {
    Write-Host "`n$(L 'FEHLER' 'ERROR'): $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "$(L 'Protokoll' 'Log'): $(Join-Path $DataDir 'install.log')"
    Write-Host (L "Das Setup laesst sich spaeter ueber 'NV-AI reparieren' im Startmenue wiederholen." `
                  "You can repeat the setup later via 'Repair NV-AI' in the Start menu.")
    Stop-Transcript | Out-Null
    Start-Sleep -Seconds 15
    exit 1
}
