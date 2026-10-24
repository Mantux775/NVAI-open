<#
  Sets up the Python environments of the installed NVAI-open.
  Called by the setup after copying the files; also runs on its own as "Repair NVAI-open".

    install-runtime.ps1 -App <install folder> -DataDir <data folder> [-With3D] [-WithAddon] [-Gpu auto|nvidia|amd]

  Everything comes from the pinned package lists in locks\ (with sha256 hashes): the same
  versions that were tested. NVIDIA: PyTorch with CUDA 13 (comfyui.lock). AMD Radeon
  (experimental since 0.5): PyTorch with ROCm 7.2.1 from AMD (comfyui-amd-base.lock plus
  comfyui-rocm.lock); 3D is skipped there because TripoSG needs CUDA. uv fetches Python itself as a standalone build into <App>\python,
  nothing has to be preinstalled. Log: <DataDir>\install.log
  Messages follow the Windows display language (German or English). ASCII only: Windows
  PowerShell 5.1 reads scripts without BOM as ANSI.
#>
param(
    [Parameter(Mandatory)] [string]$App,
    [Parameter(Mandatory)] [string]$DataDir,
    [switch]$WithAddon,
    [switch]$With3D,
    [ValidateSet("auto", "nvidia", "amd")] [string]$Gpu = "auto"
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

# Which PyTorch build: NVIDIA wins if both are present (an integrated Radeon next to a GeForce
# must not switch the whole installation to ROCm).
function Get-GpuVendor {
    $names = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    if (($names -match "NVIDIA") -or (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) { return "nvidia" }
    if ($names -match "Radeon|AMD") { return "amd" }
    return "nvidia"
}

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
    Write-Host (L "NVAI-open wird eingerichtet. Beim ersten Mal laedt das rund 3 GB (vor allem PyTorch)." `
                  "Setting up NVAI-open. The first time this downloads about 3 GB (mostly PyTorch).")
    Write-Host (L "Je nach Leitung dauert das 5 bis 20 Minuten. Dieses Fenster schliesst sich am Ende selbst." `
                  "Depending on your connection this takes 5 to 20 minutes. This window closes by itself.")

    Step "Python $PythonVersion"
    # --no-bin/--no-registry: otherwise uv puts a python3.12.exe into ~\.local\bin and adds a
    # registry entry - traces outside the program folder (measured).
    Uv python install --no-bin --no-registry $PythonVersion

    Step (L "NVAI-open-Server" "NVAI-open server")
    $serverPy = New-Venv (Join-Path $App "server\.venv") (Join-Path $App "locks\server.lock")
    # Editable install: config.ROOT then points to the program folder, where frontend\dist
    # and external\comfyui are found.
    Uv pip install --python $serverPy --no-deps -e (Join-Path $App "server")

    $vendor = if ($Gpu -eq "auto") { Get-GpuVendor } else { $Gpu }
    if ($vendor -eq "amd") {
        Step (L "ComfyUI mit PyTorch fuer AMD Radeon (ROCm 7.2.1, experimentell) - der grosse Teil" `
                "ComfyUI with PyTorch for AMD Radeon (ROCm 7.2.1, experimental) - the big part")
        Write-Host (L "AMD-Grafikkarte erkannt. Noetig ist der AMD-Treiber 26.2.2 oder neuer. Rund 2,5 GB." `
                      "AMD graphics card detected. Requires AMD driver 26.2.2 or newer. About 2.5 GB.")
        $comfyPy = New-Venv (Join-Path $App "external\comfyui\.venv") (Join-Path $App "locks\comfyui-amd-base.lock")
        # PyTorch and the ROCm SDK from AMD: --no-deps, because torch names the rocm meta
        # package as a dependency, which this list brings along explicitly (with hashes).
        Uv pip install --python $comfyPy --require-hashes --no-deps -r (Join-Path $App "locks\comfyui-rocm.lock")
    } else {
        Step (L "ComfyUI mit PyTorch (CUDA 13) - der grosse Teil" "ComfyUI with PyTorch (CUDA 13) - the big part")
        $comfyPy = New-Venv (Join-Path $App "external\comfyui\.venv") (Join-Path $App "locks\comfyui.lock") `
            @("--index-strategy", "unsafe-best-match")
    }

    if ($With3D -and $vendor -eq "amd") {
        Step (L "3D (TripoSG)" "3D (TripoSG)")
        Write-Host (L "Uebersprungen: 3D braucht derzeit eine NVIDIA-Karte (CUDA-Erweiterungen)." `
                      "Skipped: 3D currently needs an NVIDIA card (CUDA extensions).")
    } elseif ($With3D) {
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
    # On ROCm, PyTorch reports the Radeon through torch.cuda as well (HIP).
    & $comfyPy -c "import torch; ok = torch.cuda.is_available(); print('GPU backend:', 'ROCm ' + torch.version.hip if torch.version.hip else 'CUDA', ok); print('GPU:', torch.cuda.get_device_name(0) if ok else '-')"
    if ($vendor -eq "amd") {
        Write-Host (L "Zeigt die Zeile oben 'False': AMD-Treiber 26.2.2 oder neuer installieren und 'NVAI-open reparieren' starten." `
                      "If the line above says 'False': install AMD driver 26.2.2 or newer and run 'Repair NVAI-open'.")
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning (L "PyTorch-Test fehlgeschlagen. NVAI-open startet trotzdem; Details im Protokoll." `
                         "PyTorch check failed. NVAI-open starts anyway; details in the log.")
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
    Write-Host (L "Das Setup laesst sich spaeter ueber 'NVAI-open reparieren' im Startmenue wiederholen." `
                  "You can repeat the setup later via 'Repair NVAI-open' in the Start menu.")
    Stop-Transcript | Out-Null
    Start-Sleep -Seconds 15
    exit 1
}
