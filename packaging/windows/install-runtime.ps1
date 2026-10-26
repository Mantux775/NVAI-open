<#
  Sets up the Python environments of the installed NVAI-open.
  Called by the setup after copying the files; also runs on its own as "Repair NVAI-open".

    install-runtime.ps1 -App <install folder> -DataDir <data folder> [-With3D] [-WithAddon] [-Gpu auto|nvidia|amd]
                       [-Rocm auto|10.0|7.2] [-Lang de|en]

  Everything comes from the pinned package lists in locks\ (with sha256 hashes): the same
  versions that were tested. NVIDIA: PyTorch with CUDA 13 (comfyui.lock). AMD Radeon
  (experimental since 0.5): comfyui-amd-base.lock plus PyTorch 2.13 with ROCm 10.0 from AMD's
  multi-architecture packages as in ComfyUI's README (comfyui-rocm.lock and the kernels of the
  detected card, comfyui-rocm-<gfx>.lock). If a small bf16 computation on the card fails with it
  (driver too old, say), -Rocm auto falls back to PyTorch 2.9.1 with ROCm 7.2.1, the version in
  AMD's Windows support matrix and in ComfyUI's own AMD package (comfyui-rocm72.lock).
  3D is skipped on AMD because TripoSG needs CUDA. uv fetches Python itself as a standalone build into <App>\python,
  nothing has to be preinstalled. Log: <DataDir>\install.log
  Messages are German or English: the language chosen in the setup (-Lang; the setup and the "Repair" shortcut
  pass it), otherwise the Windows display language. ASCII only: Windows PowerShell 5.1 reads scripts without BOM
  as ANSI.
#>
param(
    [Parameter(Mandatory)] [string]$App,
    [Parameter(Mandatory)] [string]$DataDir,
    [switch]$WithAddon,
    [switch]$With3D,
    [ValidateSet("auto", "nvidia", "amd")] [string]$Gpu = "auto",
    [ValidateSet("auto", "10.0", "7.2")] [string]$Rocm = "auto",
    [ValidateSet("", "de", "en")] [string]$Lang = ""
)
$ErrorActionPreference = "Stop"
$PythonVersion = "3.12.13"
$German = if ($Lang) { $Lang -eq "de" } else { (Get-UICulture).TwoLetterISOLanguageName -eq "de" }
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

# AMD: gfx target from the card name, the same table as AMD_TARGETS in server\nvai\gpu.py. The first match wins.
$AmdTargets = @(
    @("RX\s*9070|R9700|AI\s*PRO\s*R9", "gfx1201"),
    @("RX\s*9060", "gfx1200"),
    @("RX\s*7900|W7900|W7800", "gfx1100"),
    @("RX\s*7800|RX\s*7700|W7700", "gfx1101"),
    @("RX\s*76[05]0|W7600|W7500", "gfx1102"),
    @("8060S|8050S|8040S|AI\s*Max", "gfx1151"),
    @("890M|880M", "gfx1150"),
    @("780M|760M|740M", "gfx1103"),
    @("RX\s*69[05]0|RX\s*6800", "gfx1030"),
    @("RX\s*67[05]0", "gfx1031"),
    @("RX\s*66[05]0|RX\s*6600", "gfx1032")
)
# Unknown Radeon: the kernels of the common current cards (RX 9000 and RX 7000).
$AmdFallbackTargets = @("gfx1201", "gfx1200", "gfx1100", "gfx1101", "gfx1102")

# The Radeons that count: a card of its own wins over the Radeon inside a Ryzen processor.
function Get-AmdCards {
    # Test switch as in the server: NVAI_SIMULATE_AMD="AMD Radeon RX 9070 XT:16" pretends this card.
    if ($env:NVAI_SIMULATE_AMD) { return @(($env:NVAI_SIMULATE_AMD -split ':')[0]) }
    $names = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Name } | Where-Object { $_ -match "Radeon|AMD" })
    $discrete = @($names | Where-Object { $_ -match "\bRX\b|PRO\s*W|AI\s*PRO|R9700" })
    if ($discrete.Count -gt 0) { return $discrete }
    return $names
}

function Get-AmdTarget([string]$name) {
    foreach ($t in $AmdTargets) { if ($name -match $t[0]) { return $t[1] } }
    return $null
}

# Lists every GPU PyTorch sees and runs a small bf16 matrix product on the largest one. Exit 0 = usable.
$TorchProbe = @"
import sys, torch
ok = torch.cuda.is_available()
backend = ('ROCm ' + str(torch.version.hip)) if torch.version.hip else ('CUDA ' + str(torch.version.cuda))
print('PyTorch', torch.__version__, '-', backend, '- GPU available:', ok)
if not ok:
    sys.exit(1)
devs = [torch.cuda.get_device_properties(i) for i in range(torch.cuda.device_count())]
for i, p in enumerate(devs):
    # gcnArchName (gfx1201 ...) only on ROCm; PyTorch 2.14 also fills it with the name on NVIDIA.
    arch = getattr(p, 'gcnArchName', '') if torch.version.hip else ''
    print('  GPU', i, ':', p.name, arch, round(p.total_memory / 2**30, 1), 'GB')
main = max(range(len(devs)), key=lambda i: devs[i].total_memory)
torch.cuda.set_device(main)
x = torch.randn(256, 256, device='cuda', dtype=torch.bfloat16)
y = (x @ x).float().abs().mean().item()
torch.cuda.synchronize()
print('  NVAI-open computes on GPU', main, ':', devs[main].name, '- bf16 test ok' if y == y else '- bf16 test NaN')
sys.exit(0 if y == y else 2)
"@

function Test-Torch($py) {
    $probe = Join-Path $env:TEMP "nvai-torch-probe.py"
    Set-Content -Path $probe -Value $TorchProbe -Encoding ASCII
    & $py $probe | Out-Host
    $ok = $LASTEXITCODE -eq 0
    Remove-Item $probe -ErrorAction SilentlyContinue
    return $ok
}

function Uv {
    # Out-Host: otherwise uv's stdout ends up in the return value of New-Venv.
    & $uv @args | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw (L "uv $($args[0]) $($args[1]) ist fehlgeschlagen (Exit $LASTEXITCODE)." "uv $($args[0]) $($args[1]) failed (exit $LASTEXITCODE).")
    }
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
    $torchChecked = $false
    if ($vendor -eq "amd") {
        $cards = @(Get-AmdCards)
        $targets = @($cards | ForEach-Object { Get-AmdTarget $_ } | Where-Object { $_ } | Select-Object -Unique)
        Write-Host (L "AMD-Grafikkarte erkannt: $($cards -join ', '). Noetig ist ein aktueller AMD-Treiber (Adrenalin)." `
                      "AMD graphics card detected: $($cards -join ', '). Requires a current AMD driver (Adrenalin).")
        if ($targets.Count -eq 0) {
            $targets = $AmdFallbackTargets
            Write-Host (L "Kartenfamilie unbekannt - es kommen die Kernel der Radeon RX 9000 und RX 7000." `
                          "Card family unknown - installing the kernels of the Radeon RX 9000 and RX 7000.")
        }
        $comfyLocks = Join-Path $App "locks"
        $useRocm72 = $Rocm -eq "7.2"
        if (-not $useRocm72) {
            Step (L "ComfyUI mit PyTorch 2.13 fuer AMD Radeon (ROCm 10.0, $($targets -join ', '), experimentell) - der grosse Teil" `
                    "ComfyUI with PyTorch 2.13 for AMD Radeon (ROCm 10.0, $($targets -join ', '), experimental) - the big part")
            $comfyPy = New-Venv (Join-Path $App "external\comfyui\.venv") (Join-Path $comfyLocks "comfyui-amd-base.lock")
            # PyTorch, the ROCm runtime and the kernels of this card from AMD: --no-deps, because torch names
            # the rocm meta package as a dependency, which these lists bring along explicitly (with hashes).
            $req = @("-r", (Join-Path $comfyLocks "comfyui-rocm.lock"))
            foreach ($t in $targets) { $req += @("-r", (Join-Path $comfyLocks "comfyui-rocm-$t.lock")) }
            Uv pip install --python $comfyPy --require-hashes --no-deps @req
            Step (L "Grafikkarte pruefen" "Checking the graphics card")
            $torchChecked = $true
            if (-not (Test-Torch $comfyPy)) {
                if ($Rocm -eq "auto") {
                    Write-Warning (L "ROCm 10.0 rechnet auf dieser Karte oder mit diesem Treiber nicht. Es kommt ROCm 7.2.1 (die Fassung aus AMDs Windows-Liste)." `
                                     "ROCm 10.0 does not compute on this card or with this driver. Switching to ROCm 7.2.1 (the version in AMD's Windows support list).")
                    $useRocm72 = $true
                } else {
                    Write-Warning (L "PyTorch rechnet nicht auf der Grafikkarte. Aktuellen AMD-Treiber installieren und 'NVAI-open reparieren' starten." `
                                     "PyTorch does not compute on the graphics card. Install the current AMD driver and run 'Repair NVAI-open'.")
                }
            }
        }
        if ($useRocm72) {
            Step (L "ComfyUI mit PyTorch 2.9.1 fuer AMD Radeon (ROCm 7.2.1, experimentell)" `
                    "ComfyUI with PyTorch 2.9.1 for AMD Radeon (ROCm 7.2.1, experimental)")
            # pip sync with the base list removes the ROCm 10 packages first.
            $comfyPy = New-Venv (Join-Path $App "external\comfyui\.venv") (Join-Path $comfyLocks "comfyui-amd-base.lock")
            Uv pip install --python $comfyPy --require-hashes --no-deps -r (Join-Path $comfyLocks "comfyui-rocm72.lock")
            Step (L "Grafikkarte pruefen" "Checking the graphics card")
            $torchChecked = $true
            if (-not (Test-Torch $comfyPy)) {
                Write-Warning (L "PyTorch rechnet nicht auf der Grafikkarte. Aktuellen AMD-Treiber (Adrenalin 26.2.2 oder neuer) installieren und 'NVAI-open reparieren' starten." `
                                 "PyTorch does not compute on the graphics card. Install the current AMD driver (Adrenalin 26.2.2 or newer) and run 'Repair NVAI-open'.")
            }
        }
        # NVAI-open asks ROCm again at startup which card to use (gpu.hip_devices); drop the old answer.
        Remove-Item (Join-Path $DataDir "hip_devices.json") -ErrorAction SilentlyContinue
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

    if (-not $torchChecked) {
        Step (L "Grafikkarte pruefen" "Checking the graphics card")
        if (-not (Test-Torch $comfyPy)) {
            Write-Warning (L "PyTorch-Test fehlgeschlagen. NVAI-open startet trotzdem; Details im Protokoll." `
                             "PyTorch check failed. NVAI-open starts anyway; details in the log.")
        }
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
