# Baut die CUDA-Extensions fuer TRELLIS.2 selbst.
#
# Warum ueberhaupt: Die vorgebauten Wheels sind gegen einen anderen torch-Build
# gelinkt (37-45 fehlende C++-Symbole je Extension). Selbst gebaut passt die ABI
# garantiert zum venv.
#
# Aufruf:  .\build_trellis2_ext.ps1 o_voxel cumesh flex_gemm
#          .\build_trellis2_ext.ps1 flash_attn      (dauert 1-3 Stunden)
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Targets = @("o_voxel", "cumesh", "flex_gemm")
)

$ErrorActionPreference = "Continue"
$repo = Split-Path -Parent $PSScriptRoot
$t2 = Join-Path $repo "external\trellis2"
$py = Join-Path $t2 ".venv\Scripts\python.exe"
$build = Join-Path $t2 "_build"
# Visual Studio 2022 (17.x) bevorzugen: CUDA 12.8/13 sind gegen dessen Toolset
# (MSVC 14.4x) getestet. Mit VS 18 stuerzt nvccs Frontend ab bzw. scheitert am
# Parsen der torch-Header.
$vsw = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
$vsRoot = $null
if (Test-Path $vsw) {
    # -all ist noetig: BuildTools-Installationen blendet vswhere sonst aus.
    $vsRoot = & $vsw -products * -all -version "[17.0,18.0)" `
        -latest -format value -property installationPath
    if ($vsRoot -and -not (Test-Path (Join-Path $vsRoot "VC\Auxiliary\Build\vcvars64.bat"))) {
        $vsRoot = $null   # ohne C++-Toolset nutzlos
    }
}
if (-not $vsRoot) {
    Write-Host "VS 2022 nicht gefunden -- weiche auf VS 18 aus (bekannt problematisch)." -ForegroundColor Yellow
    $vsRoot = "C:\Program Files\Microsoft Visual Studio\18\Community"
}
$vcvars = Join-Path $vsRoot "VC\Auxiliary\Build\vcvars64.bat"
Write-Host "Toolset: $vsRoot" -ForegroundColor DarkGray

if (-not (Test-Path $py)) { throw "venv fehlt: $py" }
if (-not (Test-Path $vcvars)) { throw "vcvars64.bat fehlt: $vcvars" }
New-Item -ItemType Directory -Force $build | Out-Null

# vcvars64.bat ruft vswhere.exe ohne vollen Pfad auf -- der Installer-Ordner
# steht aber nicht im PATH.
$vsInstaller = "C:\Program Files (x86)\Microsoft Visual Studio\Installer"
if (Test-Path $vsInstaller) { $env:PATH = "$vsInstaller;$env:PATH" }

# uv-venvs bringen kein pip mit; die Build-Backends der Extensions erwarten es.
& $py -c "import pip" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "pip fehlt im venv -- wird nachinstalliert" -ForegroundColor Yellow
    uv pip install --python $py pip setuptools wheel
}

# CUDA 12.8 zusammen mit VS 2022: das ist der Stack, auf dem ComfyUI und TripoSG
# hier laufen (torch cu128, sm_120). Mit NVAI_CUDA_PATH ueberschreibbar.
$cuda = $env:NVAI_CUDA_PATH
if (-not $cuda) { $cuda = "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.8" }
if (-not (Test-Path $cuda)) { throw "CUDA nicht gefunden: $cuda" }
Write-Host "CUDA: $cuda" -ForegroundColor DarkGray

# sm_120 = Blackwell. Ohne das baut nvcc Kernel fuer die falsche Architektur.
$env:TORCH_CUDA_ARCH_LIST = "12.0"
$env:CUDA_HOME = $cuda
$env:CUDA_PATH = $cuda
$env:DISTUTILS_USE_SDK = "1"   # Pflicht, damit setuptools MSVC statt mingw nimmt
$env:MAX_JOBS = "4"            # begrenzt Parallelitaet; flash-attn frisst sonst den RAM

function Build-Ext($name, $source) {
    Write-Host "`n===== $name =====" -ForegroundColor Cyan
    Write-Host "Quelle: $source"
    $started = Get-Date

    # Kaputtes vorgebautes Wheel entfernen, sonst bleibt es liegen.
    & $py -m pip uninstall -y $name 2>&1 | Out-Null

    # cmd-Fallstrick: 'set VAR=wert && next' nimmt das Leerzeichen vor && in den
    # Wert auf. Deshalb konsequent set "VAR=wert" ohne Leerzeichen davor.
    # venv\Scripts muss in den PATH, sonst findet der Build ninja nicht und faellt
    # auf den sehr langsamen distutils-Backend zurueck.
    $venvScripts = Split-Path $py -Parent
    $cmd = "set `"PATH=$vsInstaller;$venvScripts;%PATH%`"&& " +
           "call `"$vcvars`" >nul&& " +
           "set `"CUDA_HOME=$cuda`"&& set `"CUDA_PATH=$cuda`"&& " +
           "set `"TORCH_CUDA_ARCH_LIST=12.0`"&& set `"DISTUTILS_USE_SDK=1`"&& " +
           "set `"MAX_JOBS=4`"&& " +
           # CCCL_IGNORE_...: verhindert, dass CUDA 13 auf /Zc:preprocessor besteht.
           # Mit dem Flag wuerde stattdessen C2872 in torch-Headern auftreten.
           "set `"NVCC_PREPEND_FLAGS=-DCCCL_IGNORE_MSVC_TRADITIONAL_PREPROCESSOR_WARNING -allow-unsupported-compiler`"&& " +
           "set `"CFLAGS=-DCCCL_IGNORE_MSVC_TRADITIONAL_PREPROCESSOR_WARNING`"&& " +
           "set `"CXXFLAGS=-DCCCL_IGNORE_MSVC_TRADITIONAL_PREPROCESSOR_WARNING`"&& " +
           # /std:c++17 ist noetig, weil o-voxel nur das GCC-Pendant -std=c++17
           # setzt; MSVC ignoriert das und faellt auf C++14 zurueck, woran dann
           # die torch-Header scheitern ("data member initializer is not allowed").
           # KEIN /Zc:preprocessor: das brauchte nur CUDA 13s CCCL und macht in
           # torch-Headern "std" mehrdeutig (C2872).
           "set `"CL=/std:c++17`"&& " +
           "`"$py`" -m pip install `"$source`" --no-build-isolation --no-deps"
    cmd /c $cmd
    $code = $LASTEXITCODE
    $dauer = [math]::Round(((Get-Date) - $started).TotalMinutes, 1)

    if ($code -eq 0) {
        Write-Host "OK: $name gebaut ($dauer min)" -ForegroundColor Green
    } else {
        Write-Host "FEHLGESCHLAGEN: $name (Exit $code, $dauer min)" -ForegroundColor Red
    }
    return $code
}

$results = @{}
foreach ($t in $Targets) {
    switch ($t) {
        "o_voxel" {
            # Liegt bereits im Repo, kein Klonen noetig.
            $results[$t] = Build-Ext "o_voxel" (Join-Path $t2 "o-voxel")
        }
        "cumesh" {
            $src = Join-Path $build "CuMesh"
            if (-not (Test-Path $src)) {
                git clone --recursive https://github.com/JeffreyXiang/CuMesh.git $src
            }
            $results[$t] = Build-Ext "cumesh" $src
        }
        "flex_gemm" {
            $src = Join-Path $build "FlexGEMM"
            if (-not (Test-Path $src)) {
                git clone --recursive https://github.com/JeffreyXiang/FlexGEMM.git $src
            }
            $results[$t] = Build-Ext "flex_gemm" $src
        }
        "nvdiffrast" {
            $src = Join-Path $build "nvdiffrast"
            if (-not (Test-Path $src)) {
                git clone -b v0.4.0 https://github.com/NVlabs/nvdiffrast.git $src
            }
            $results[$t] = Build-Ext "nvdiffrast" $src
        }
        "nvdiffrec" {
            $src = Join-Path $build "nvdiffrec"
            if (-not (Test-Path $src)) {
                git clone -b renderutils https://github.com/JeffreyXiang/nvdiffrec.git $src
            }
            $results[$t] = Build-Ext "nvdiffrec" $src
        }
        "flash_attn" {
            $src = Join-Path $build "flash-attention"
            if (-not (Test-Path $src)) {
                git clone --recursive -b v2.7.3 https://github.com/Dao-AILab/flash-attention.git $src
            }
            $results[$t] = Build-Ext "flash_attn" $src
        }
        default { Write-Host "Unbekanntes Ziel: $t" -ForegroundColor Yellow }
    }
}

Write-Host "`n===== Ergebnis =====" -ForegroundColor Cyan
foreach ($k in $results.Keys) {
    $status = if ($results[$k] -eq 0) { "OK" } else { "FEHLER" }
    Write-Host ("  {0,-12} {1}" -f $k, $status)
}

