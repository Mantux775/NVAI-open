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
  Radeon RX 5000 and RX 6500/6400 (since 0.5.38, $AmdExperimental): AMD's packages for them are new, so ROCm 10 is set
  up and checked the same way, but images and videos compute through Vulkan by default and ComfyUI with ROCm is a
  choice in the app (gpu_mode.json "rocm_optional"); if the check fails, they go straight to Vulkan (ROCm 7.2.1 has no
  kernels for them).
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
    # Intel (Arc and integrated graphics, since 0.5.35): no CUDA, no ROCm; images and videos through Vulkan
    if ($names -match "Intel") { return "intel" }
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
    # RX 6000 in laptops (since 0.5.38): the S models are Navi 23, the RX 6800M/6850M XT Navi 22
    @("RX\s*6[678]00S", "gfx1032"),
    @("RX\s*67[05]0|RX\s*68[05]0M", "gfx1031"),
    @("RX\s*69[05]0|RX\s*6800|W6800|V620", "gfx1030"),
    @("RX\s*66[05]0|RX\s*6600|W6600", "gfx1032"),
    # Since 0.5.38, experimental ($AmdExperimental): RX 6500/6400/6300 (Navi 24) and RX 5000 (Navi 10, 12, 14)
    @("RX\s*6[345][05]0|W6[34]00", "gfx1034"),
    @("Pro\s*5600M|V520", "gfx1011"),
    @("RX\s*5[67]00|W5700|Pro\s*5700", "gfx1010"),
    @("RX\s*5[345]\d0|W5[35]00|Pro\s*5[35]00", "gfx1012")
)
# Cards for which AMD has offered PyTorch packages for Windows only since autumn 2026 (the same version, PyTorch 2.13 with
# ROCm 10.0), the same list as AMD_EXPERIMENTAL in server\nvai\gpu.py. Unmeasured on a real card; for the RX 5000, users
# of other programs report weak performance. ROCm is set up and checked, but Vulkan stays the default.
$AmdExperimental = @("gfx1010", "gfx1011", "gfx1012", "gfx1034")
# Unknown Radeon: the kernels of the common current cards (RX 9000 and RX 7000).
$AmdFallbackTargets = @("gfx1201", "gfx1200", "gfx1100", "gfx1101", "gfx1102")
# Radeons that AMD's PyTorch for Windows (ROCm) does not support, the same list as AMD_UNSUPPORTED in
# server\nvai\gpu.py: Vega, Radeon VII, Polaris (RX 400/500) and older, plus RX 5000 names without an entry in
# $AmdTargets (until 0.5.37 every RX 5000). No ROCm build computes on them; on an RX 5700 XT PyTorch with the kernels of
# the RX 9000/7000 even crashed while checking the card (GitHub issue #3). NVAI-open then sets itself up for the
# processor. "R9 390" needs the space: the R9700 (Radeon AI PRO, RDNA4) is supported.
$AmdUnsupported = @("RX\s*5\d{3}", "\bW5\d{3}\b", "Vega", "Radeon\s*(Pro\s*)?VII", "RX\s*[45]\d0\b",
                    "\bR[579]\s+(\d{3}|Fury|Nano)", "\bHD\s*[5-8]\d{3}")

function Test-AmdUnsupported([string]$name) {
    # A card with a gfx target has ROCm kernels (since 0.5.38 also the RX 5000 and RX 6500/6400)
    if (Get-AmdTarget $name) { return $false }
    foreach ($p in $AmdUnsupported) { if ($name -match $p) { return $true } }
    return $false
}

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

# Lists every GPU PyTorch sees and runs a small bf16 matrix product on the largest one, then fp16 (since 0.5.38: ComfyUI
# computes in fp16 on the RX 5000 and RX 6000, bf16 only for upcast weights). Exit 0 = usable.
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
h = torch.randn(256, 256, device='cuda', dtype=torch.float16)
z = (h @ h).float().abs().mean().item()
torch.cuda.synchronize()
print('  NVAI-open computes on GPU', main, ':', devs[main].name, '- bf16 test ok' if y == y else '- bf16 test NaN',
      '- fp16 test ok' if z == z else '- fp16 test NaN')
sys.exit(0 if y == y and z == z else 2)
"@

function Test-Torch($py) {
    $probe = Join-Path $env:TEMP "nvai-torch-probe.py"
    Set-Content -Path $probe -Value $TorchProbe -Encoding ASCII
    & $py $probe | Out-Host
    $ok = $LASTEXITCODE -eq 0
    Remove-Item $probe -ErrorAction SilentlyContinue
    # Test switch, only together with NVAI_SIMULATE_AMD: pretend the check computed, to walk through the path of a card
    # that is not in this machine (RX 5000 with ROCm, since 0.5.38)
    if (-not $ok -and $env:NVAI_SIMULATE_AMD -and $env:NVAI_SIMULATE_ROCM_OK) {
        Write-Host "  (NVAI_SIMULATE_ROCM_OK: check counted as passed)"
        $ok = $true
    }
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

# Vulkan engine (since 0.5.34, images since 0.5.35): stable-diffusion.cpp for cards without CUDA/ROCm (older Radeons,
# Intel), from the project's GitHub release (MIT), checked against this SHA-256 and unpacked to external\sdcpp. Only a
# card of its own counts (uma: 0); integrated graphics stay on the processor. Returns the note for gpu_mode.json
# ("vulkan": {"ok", "device", "index"}); the index is the card's Vulkan number, which the engines use
# (GGML_VK_VISIBLE_DEVICES), so a machine with integrated graphics plus a Radeon computes on the Radeon.
$SdcppUrl = "https://github.com/leejet/stable-diffusion.cpp/releases/download/master-1106-532d2c1/sd-master-532d2c1-bin-win-vulkan-x64.zip"
$SdcppSha256 = "3E66222C87CA27074E1FD8CE79706EEF17A8AAF39949906AA1BEE7E060F22ECC"

# Device list of sd.cpp or audio.cpp as plain text. Both write it to stderr, and Windows PowerShell 5.1 turns every
# redirected stderr line into an error record: with $ErrorActionPreference = "Stop" the first one ended the call. So
# "ggml_vulkan: Found 1 Vulkan devices:" aborted the check on every card and the Vulkan engines were never set up
# (GitHub issue #3). Here the preference is "Continue" for this call only and every line becomes a string.
function Get-DeviceList([string]$exe) {
    $ErrorActionPreference = "Continue"
    $lines = @(& $exe --list-devices 2>&1 | ForEach-Object { "$_" })
    return ($lines -join "`n")
}

# -RocmReady: ROCm computes on this card too (RX 5000, RX 6500/6400), so without Vulkan ComfyUI takes over, not the processor.
function Install-VulkanEngine([switch]$RocmReady) {
    Step (L "Vulkan-Engine fuer Bilder und Video (stable-diffusion.cpp, experimentell)" "Vulkan engine for images and video (stable-diffusion.cpp, experimental)")
    $dest = Join-Path $App "external\sdcpp"
    $zip = Join-Path $env:TEMP "nvai-sdcpp-$PID.zip"
    try {
        $old = $ProgressPreference
        $ProgressPreference = "SilentlyContinue"   # the progress bar slows Invoke-WebRequest down a lot
        try { Invoke-WebRequest -Uri $SdcppUrl -OutFile $zip -UseBasicParsing } finally { $ProgressPreference = $old }
        $hash = (Get-FileHash $zip -Algorithm SHA256).Hash
        if ($hash -ne $SdcppSha256) { throw "SHA-256 $hash" }
        if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
        Expand-Archive -Path $zip -DestinationPath $dest -Force
        $out = Get-DeviceList (Join-Path $dest "sd-cli.exe")
        $dev = [regex]::Match($out, "(?m)^ggml_vulkan: (\d+) = (.+?) \| uma: 0 ")
        if ($dev.Success) {
            $name = $dev.Groups[2].Value.Trim()
            Write-Host (L "Vulkan sieht die Karte ($name); Bilder und Videos rechnen darueber." `
                          "Vulkan sees the card ($name); images and videos compute through it.")
            return [ordered]@{ ok = $true; device = $name; index = [int]$dev.Groups[1].Value }
        }
        if ($out -match "(?m)^ggml_vulkan: \d+ = .*\| uma: 1 ") { throw "only integrated graphics" }
        throw "no Vulkan device"
    } catch {
        if ($RocmReady) {
            Write-Warning (L "Vulkan-Engine nicht eingerichtet ($($_.Exception.Message)). NVAI-open versucht es beim Start erneut; sieht Vulkan die Karte nicht, rechnet ComfyUI ueber ROCm (experimentell)." `
                             "Vulkan engine not set up ($($_.Exception.Message)). NVAI-open tries again at startup; if Vulkan does not see the card, ComfyUI computes through ROCm (experimental).")
        } else {
            Write-Warning (L "Vulkan-Engine nicht eingerichtet ($($_.Exception.Message)); Bilder und Videos rechnen dann auf dem Prozessor." `
                             "Vulkan engine not set up ($($_.Exception.Message)); images and videos then compute on the processor.")
        }
        Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue
        return [ordered]@{ ok = $false; error = "$($_.Exception.Message)" }
    } finally {
        Remove-Item $zip -ErrorAction SilentlyContinue
    }
}

# Sound and voice through Vulkan (since 0.5.35): audio.cpp (Apache-2.0, ShugoAI LLC) from the project's GitHub release,
# checked against this SHA-256 and unpacked to external\audiocpp. Stable Audio 3 (GGUF) and Qwen3-TTS then compute on the
# card instead of the processor; the server uses it when it exists (nvai\audiocpp.py).
$AudiocppUrl = "https://github.com/0xShug0/audio.cpp/releases/download/v0.9.6/audio-v0.9.6-bin-windows-x64-vulkan.zip"
$AudiocppSha256 = "94C6E1DF6D98176EB5F0E3AD6C16E419F548BCE3C65CCD8DA97ABF4C3966A7AA"

function Install-AudioEngine {
    Step (L "audio.cpp fuer Ton und Sprache ueber Vulkan (experimentell)" "audio.cpp for sound and voice through Vulkan (experimental)")
    $dest = Join-Path $App "external\audiocpp"
    $zip = Join-Path $env:TEMP "nvai-audiocpp-$PID.zip"
    try {
        $old = $ProgressPreference
        $ProgressPreference = "SilentlyContinue"
        try { Invoke-WebRequest -Uri $AudiocppUrl -OutFile $zip -UseBasicParsing } finally { $ProgressPreference = $old }
        $hash = (Get-FileHash $zip -Algorithm SHA256).Hash
        if ($hash -ne $AudiocppSha256) { throw "SHA-256 $hash" }
        if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
        Expand-Archive -Path $zip -DestinationPath $dest -Force
        $out = Get-DeviceList (Join-Path $dest "audiocpp_cli.exe")
        if ($out -match "(?m)^Vulkan:\d") {
            Write-Host (L "audio.cpp sieht die Karte; Ton und Sprecherstimme rechnen darueber." `
                          "audio.cpp sees the card; sound and the narrator voice compute through it.")
            return $true
        }
        throw "no Vulkan device"
    } catch {
        Write-Warning (L "audio.cpp nicht eingerichtet ($($_.Exception.Message)); Ton rechnet dann auf dem Prozessor." `
                         "audio.cpp not set up ($($_.Exception.Message)); sound then computes on the processor.")
        Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue
        return $false
    } finally {
        Remove-Item $zip -ErrorAction SilentlyContinue
    }
}

# Cards without CUDA and ROCm (older Radeons, Intel; GitHub issue #3): ComfyUI with PyTorch for the processor (sound,
# prompt expansion), images and videos through the Vulkan engine if it finds a card of its own. DirectML (0.5.33 and
# 0.5.34) is gone since 0.5.35: about 6 minutes per SDXL image on an RX 5700 XT, no video, PyTorch 2.4.1 and patches
# inside ComfyUI. Writes gpu_mode.json, which the server reads (gpu.cpu_mode); returns the ComfyUI python.
function Install-NoCudaRocm([string]$reason, [string[]]$cards, [string]$locks) {
    Step (L "ComfyUI mit PyTorch 2.14 fuer den Prozessor (ohne Grafikkarte)" `
            "ComfyUI with PyTorch 2.14 for the processor (without graphics card)")
    # pip sync with the base list removes the ROCm packages first; PyTorch from PyPI is a CPU build on Windows.
    $py = New-Venv (Join-Path $App "external\comfyui\.venv") (Join-Path $locks "comfyui-amd-base.lock")
    Uv pip install --python $py --require-hashes --no-deps -r (Join-Path $locks "comfyui-cpu.lock")
    $vulkan = Install-VulkanEngine
    $audio = if ($vulkan.ok) { Install-AudioEngine } else { $false }
    $note = [ordered]@{ mode = "cpu"; reason = $reason; cards = @($cards); vulkan = $vulkan; audio = $audio } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($gpuModeFile, $note, (New-Object System.Text.UTF8Encoding $false))
    if ($vulkan.ok -and $audio) {
        Write-Host (L "NVAI-open rechnet Bilder und Videos ueber Vulkan auf der Karte (experimentell), Ton und Sprecherstimme ueber audio.cpp; oben im Fenster steht ein Hinweis, was das bedeutet." `
                      "NVAI-open computes images and videos through Vulkan on the card (experimental), sound and the narrator voice through audio.cpp; a note at the top of the window explains what this means.")
    } elseif ($vulkan.ok) {
        Write-Host (L "NVAI-open rechnet Bilder und Videos ueber Vulkan auf der Karte (experimentell), Ton auf dem Prozessor; oben im Fenster steht ein Hinweis, was das bedeutet." `
                      "NVAI-open computes images and videos through Vulkan on the card (experimental), sound on the processor; a note at the top of the window explains what this means.")
    } else {
        Write-Host (L "NVAI-open rechnet auf dem Prozessor; oben im Fenster steht ein Hinweis, was das bedeutet." `
                      "NVAI-open computes on the processor; a note at the top of the window explains what this means.")
    }
    return $py
}

# Radeon RX 5000 and RX 6500/6400 on which the ROCm check computed (since 0.5.38): PyTorch with ROCm stays in ComfyUI's
# venv, and the Vulkan engines are set up as for cards without ROCm, because Vulkan stays the default until ROCm is
# measured on these cards. gpu_mode.json "rocm_optional" tells the server (gpu.rocm_optional): Auto = Vulkan with ComfyUI
# on the processor, "ComfyUI (ROCm, experimental)" under Models -> Your hardware computes everything on the card.
function Install-RocmOptional([string[]]$cards, [string[]]$targets) {
    $vulkan = Install-VulkanEngine -RocmReady
    $audio = if ($vulkan.ok) { Install-AudioEngine } else { $false }
    $note = [ordered]@{ mode = "rocm_optional"; cards = @($cards); targets = @($targets); vulkan = $vulkan; audio = $audio } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($gpuModeFile, $note, (New-Object System.Text.UTF8Encoding $false))
    if ($vulkan.ok) {
        Write-Host (L "ROCm rechnet auf dieser Karte. Weil AMDs Pakete fuer sie neu sind, rechnet NVAI-open Bilder und Videos zunaechst ueber Vulkan; ComfyUI mit ROCm fuer alle Modelle laesst sich unter Modelle -> Deine Hardware waehlen (experimentell)." `
                      "ROCm computes on this card. Because AMD's packages for it are new, NVAI-open computes images and videos through Vulkan for now; ComfyUI with ROCm for all models can be chosen under Models -> Your hardware (experimental).")
    } else {
        Write-Host (L "ROCm rechnet auf dieser Karte (experimentell); ohne Vulkan-Engine rechnet ComfyUI darueber." `
                      "ROCm computes on this card (experimental); without the Vulkan engine, ComfyUI computes through it.")
    }
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
    # Without a usable card NVAI-open computes on the processor; the server reads this note (gpu.cpu_mode), starts
    # ComfyUI with --cpu and warns at the top of the window. Determined anew on every setup and repair.
    $gpuModeFile = Join-Path $DataDir "gpu_mode.json"
    Remove-Item $gpuModeFile -ErrorAction SilentlyContinue
    $cpuOnly = $null
    # DirectML (0.5.33, 0.5.34) is gone: its second venv with PyTorch 2.4.1 is not needed any more
    Remove-Item (Join-Path $App "external\comfyui\.venv-directml") -Recurse -Force -ErrorAction SilentlyContinue
    if ($vendor -eq "intel") {
        $cards = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -match "Intel" } | ForEach-Object { $_.Name })
        Write-Warning (L "Intel-Grafik erkannt: $($cards -join ', '). PyTorch rechnet unter Windows nur mit CUDA (NVIDIA) oder ROCm (Radeon); NVAI-open rechnet Bilder und Videos deshalb ueber Vulkan, wenn Vulkan eine eigene Intel-Karte sieht, sonst auf dem Prozessor." `
                         "Intel graphics detected: $($cards -join ', '). On Windows, PyTorch computes only with CUDA (NVIDIA) or ROCm (Radeon); NVAI-open therefore computes images and videos through Vulkan if Vulkan sees an Intel card of its own, otherwise on the processor.")
        $comfyPy = Install-NoCudaRocm "no_cuda_rocm" $cards (Join-Path $App "locks")
        $torchChecked = $true
    } elseif ($vendor -eq "amd") {
        $cards = @(Get-AmdCards)
        $targets = @($cards | ForEach-Object { Get-AmdTarget $_ } | Where-Object { $_ } | Select-Object -Unique)
        Write-Host (L "AMD-Grafikkarte erkannt: $($cards -join ', '). Noetig ist ein aktueller AMD-Treiber (Adrenalin)." `
                      "AMD graphics card detected: $($cards -join ', '). Requires a current AMD driver (Adrenalin).")
        $unsupported = @($cards | Where-Object { Test-AmdUnsupported $_ })
        if ($cards.Count -gt 0 -and $unsupported.Count -eq $cards.Count) {
            Write-Warning (L "Diese Radeon ($($cards -join ', ')) unterstuetzt AMDs PyTorch fuer Windows (ROCm) nicht; unterstuetzt sind die Radeon RX 7000 und 9000, die RX 5000 und RX 6000 experimentell. NVAI-open richtet sich ohne ROCm ein: Bilder und Videos rechnen ueber Vulkan, wenn Vulkan die Karte sieht, sonst auf dem Prozessor." `
                             "This Radeon ($($cards -join ', ')) is not supported by AMD's PyTorch for Windows (ROCm); supported are the Radeon RX 7000 and 9000, the RX 5000 and RX 6000 experimental. NVAI-open sets itself up without ROCm: images and videos compute through Vulkan if Vulkan sees the card, otherwise on the processor.")
            $cpuOnly = "amd_unsupported"
        }
        # RX 5000 and RX 6500/6400 (since 0.5.38): every detected target is one of the new ones
        $experimental = $targets.Count -gt 0 -and @($targets | Where-Object { $AmdExperimental -notcontains $_ }).Count -eq 0
        $rocmOptional = $false
        if ($cpuOnly) {
            # nothing from ROCm: the card cannot compute (below, PyTorch for the processor)
        } elseif ($targets.Count -eq 0) {
            $targets = $AmdFallbackTargets
            Write-Host (L "Kartenfamilie unbekannt - es kommen die Kernel der Radeon RX 9000 und RX 7000." `
                          "Card family unknown - installing the kernels of the Radeon RX 9000 and RX 7000.")
        }
        $comfyLocks = Join-Path $App "locks"
        $useRocm72 = $Rocm -eq "7.2"
        if (-not $useRocm72 -and -not $cpuOnly) {
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
                if ($experimental -and $Rocm -eq "auto") {
                    # ROCm 7.2.1 has no kernels for the RX 5000 and RX 6500/6400: straight to Vulkan, as up to 0.5.37
                    Write-Warning (L "ROCm rechnet auf dieser Karte oder mit diesem Treiber nicht (fuer RX 5000 und RX 6500/6400 ist es neu). NVAI-open richtet sich ohne ROCm ein: Bilder und Videos rechnen ueber Vulkan." `
                                     "ROCm does not compute on this card or with this driver (it is new for the RX 5000 and RX 6500/6400). NVAI-open sets itself up without ROCm: images and videos compute through Vulkan.")
                    $cpuOnly = "no_gpu_compute"
                } elseif ($Rocm -eq "auto") {
                    Write-Warning (L "ROCm 10.0 rechnet auf dieser Karte oder mit diesem Treiber nicht. Es kommt ROCm 7.2.1 (die Fassung aus AMDs Windows-Liste)." `
                                     "ROCm 10.0 does not compute on this card or with this driver. Switching to ROCm 7.2.1 (the version in AMD's Windows support list).")
                    $useRocm72 = $true
                } else {
                    Write-Warning (L "PyTorch rechnet nicht auf der Grafikkarte. Aktuellen AMD-Treiber installieren und 'NVAI-open reparieren' starten." `
                                     "PyTorch does not compute on the graphics card. Install the current AMD driver and run 'Repair NVAI-open'.")
                }
            } elseif ($experimental) {
                $rocmOptional = $true
            }
        }
        if ($useRocm72 -and -not $cpuOnly) {
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
                # Option B (GitHub issue #3): NVAI-open still starts, on the processor, instead of failing at every job
                if ($Rocm -eq "auto") { $cpuOnly = "no_gpu_compute" }
            }
        }
        if ($cpuOnly) {
            $comfyPy = Install-NoCudaRocm $cpuOnly $cards $comfyLocks
            $torchChecked = $true
        } elseif ($rocmOptional) {
            Install-RocmOptional $cards $targets
        }
        # NVAI-open asks ROCm again at startup which card to use (gpu.hip_devices); drop the old answer.
        Remove-Item (Join-Path $DataDir "hip_devices.json") -ErrorAction SilentlyContinue
    } else {
        Step (L "ComfyUI mit PyTorch (CUDA 13) - der grosse Teil" "ComfyUI with PyTorch (CUDA 13) - the big part")
        $comfyPy = New-Venv (Join-Path $App "external\comfyui\.venv") (Join-Path $App "locks\comfyui.lock") `
            @("--index-strategy", "unsafe-best-match")
    }

    # Narrator voice (Qwen3-TTS, since 0.5.21): its own venv without PyTorch (qwen-tts pins its own transformers);
    # the worker takes PyTorch from ComfyUI's venv at runtime, so the same CUDA or ROCm build. Small, so always.
    Step (L "Sprecherstimme (Qwen3-TTS)" "Narrator voice (Qwen3-TTS)")
    New-Venv (Join-Path $App "external\qwen3tts\.venv") (Join-Path $App "locks\qwen3tts.lock") | Out-Null

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
