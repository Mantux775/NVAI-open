<#
  Builds packaging\windows\build\NV-AI-Setup-<version>.exe.

    packaging\windows\build-setup.ps1 [-Addon <folder>]

  Assembles build\stage - only what belongs into the setup - and runs Inno Setup:
    app\server            NV-AI code (without venv), pyproject.toml, openapi.json
    app\frontend\dist     the built web interface (run "npm run build" in frontend first)
    app\external\comfyui  ComfyUI exactly at the tested tag (local git archive, otherwise
                          downloaded from GitHub)
    app\tools\uv.exe      fetches Python and the packages from app\locks during setup
    addon\                PhotoCraft add-on (bridge\, panel\, requirements.lock), optional
  The version comes from server\nvai\__init__.py.

  Requirements on the build machine: Inno Setup 6 (winget install JRSoftware.InnoSetup),
  uv on PATH, Python 3 for the notices generator.
  Add-on folder: -Addon, otherwise $env:NVAI_ADDON_DIR, otherwise photocraft-addon\dist\addon
  in this repository (built with photocraft-addon\tools\build_addon.py).
#>
param([string]$Addon = "")
$ErrorActionPreference = "Stop"

$here = $PSScriptRoot
$repo = (Resolve-Path (Join-Path $here "..\..")).Path
$build = Join-Path $here "build"
$stage = Join-Path $build "stage"
$app = Join-Path $stage "app"
$comfyTag = "v0.42.1"
if (-not $Addon) {
    $Addon = if ($env:NVAI_ADDON_DIR) { $env:NVAI_ADDON_DIR } else { Join-Path $repo "photocraft-addon\dist\addon" }
}

$version = (Select-String -Path "$repo\server\nvai\__init__.py" -Pattern '__version__ = "(.+)"').Matches[0].Groups[1].Value
$iscc = Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe"
if (-not (Test-Path $iscc)) { throw "Inno Setup missing: winget install JRSoftware.InnoSetup --scope user" }
$uvExe = (Get-Command uv -ErrorAction Stop).Source
$python = (Get-Command python -ErrorAction Stop).Source

function Copy-Tree($from, $to) {
    robocopy $from $to /E /XD __pycache__ .venv node_modules /XF *.pyc /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy ${from} -> ${to}: exit $LASTEXITCODE" }
}

Write-Host "NV-AI ${version}: staging in $stage" -ForegroundColor Cyan
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force $app | Out-Null

# Server (with the mesh workers: server\workers\triposg_worker.py)
Copy-Tree "$repo\server\nvai" "$app\server\nvai"
Copy-Tree "$repo\server\workers" "$app\server\workers"
Copy-Item "$repo\server\pyproject.toml", "$repo\server\openapi.json" "$app\server\"

# Web interface - must be built beforehand (npm run build); testers need no Node
if (-not (Test-Path "$repo\frontend\dist\index.html")) { throw "frontend\dist missing: run 'cd frontend; npm run build' first." }
Copy-Tree "$repo\frontend\dist" "$app\frontend\dist"

# ComfyUI from the tag, not from a working tree: no models, no venv, no outputs
$zip = Join-Path $build "comfyui-$comfyTag.zip"
$comfyDest = Join-Path $app "external\comfyui"
if (Test-Path "$repo\external\comfyui\.git") {
    git -C "$repo\external\comfyui" archive --format=zip -o $zip $comfyTag
    if ($LASTEXITCODE -ne 0) { throw "git archive $comfyTag failed" }
    Expand-Archive $zip $comfyDest
} else {
    Invoke-WebRequest "https://github.com/comfyanonymous/ComfyUI/archive/refs/tags/$comfyTag.zip" -OutFile $zip
    $tmp = Join-Path $build "comfyui-extract"
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    Expand-Archive $zip $tmp
    # The GitHub archive has one top folder (ComfyUI-0.42.1). Move-Item does not create the
    # parent folder (only Expand-Archive above does), so make app\external first.
    New-Item -ItemType Directory -Force (Split-Path $comfyDest) | Out-Null
    Move-Item (Get-ChildItem $tmp -Directory | Select-Object -First 1).FullName $comfyDest
    Remove-Item -Recurse -Force $tmp
}

# TripoSG (image to 3D, MIT) for the optional 3D component - same pinned commit as tested
$triposgCommit = "fc5c40990181e2a756c4e0b1c2f4d6b5202faf8c"
$triposgDest = Join-Path $stage "triposg"
$tzip = Join-Path $build "triposg.zip"
if (Test-Path "$repo\external\triposg\.git") {
    git -C "$repo\external\triposg" archive --format=zip -o $tzip $triposgCommit
    if ($LASTEXITCODE -ne 0) { throw "git archive TripoSG failed" }
    Expand-Archive $tzip $triposgDest
} else {
    Invoke-WebRequest "https://github.com/VAST-AI-Research/TripoSG/archive/$triposgCommit.zip" -OutFile $tzip
    $tmp = Join-Path $build "triposg-extract"
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    Expand-Archive $tzip $tmp
    Move-Item (Get-ChildItem $tmp -Directory | Select-Object -First 1).FullName $triposgDest
    Remove-Item -Recurse -Force $tmp
}

# uv, package lists, scripts, texts, licenses
New-Item -ItemType Directory -Force "$app\tools", "$app\locks", "$app\licenses" | Out-Null
Copy-Item $uvExe "$app\tools\uv.exe"
Copy-Item "$here\licenses\uv\*" "$app\tools\"
Copy-Item "$here\locks\*.lock" "$app\locks\"
Copy-Item "$here\install-runtime.ps1", "$here\stop-all.ps1", "$here\nvai-start.cmd", `
          "$here\GETTING_STARTED.txt", "$here\ERSTE_SCHRITTE.txt" $app
Copy-Item "$repo\LICENSE" "$app\LICENSE.txt"
Copy-Item "$repo\packaging\assets\nvai.ico" "$app\nvai.ico"

# Windows PowerShell 5.1 reads .ps1 without BOM as ANSI - the scripts are ASCII, checked here:
foreach ($ps1 in Get-ChildItem "$app\*.ps1") {
    if ([IO.File]::ReadAllBytes($ps1.FullName) | Where-Object { $_ -gt 127 }) { throw "$($ps1.Name) contains non-ASCII characters" }
}

# Add-on (optional)
$withAddon = 0
$addonNotices = $null
if (Test-Path (Join-Path $Addon "requirements.lock")) {
    Copy-Tree $Addon (Join-Path $stage "addon")
    $withAddon = 1
    # The build output (<add-on source>\dist\addon) carries no notices; they sit in the source root.
    foreach ($candidate in @((Join-Path $Addon "THIRD_PARTY_NOTICES.txt"), (Join-Path $Addon "THIRD_PARTY.md"),
                             (Join-Path $Addon "..\..\THIRD_PARTY.md"))) {
        if (Test-Path $candidate) { $addonNotices = (Resolve-Path $candidate).Path; break }
    }
    if (-not $addonNotices) { Write-Warning "No THIRD_PARTY.md found for the add-on - its notices are missing." }
    Write-Host "Add-on: $Addon" -ForegroundColor Cyan
} else {
    Write-Warning "No add-on in $Addon - building the setup without the PhotoCraft component."
}

# Third-party notices from what is actually shipped
$noticeArgs = @("$repo\packaging\tools\third_party_notices.py", "$app\THIRD_PARTY_NOTICES.txt")
if ($addonNotices) { $noticeArgs += @("--addon-licenses", $addonNotices) }
& $python @noticeArgs
if ($LASTEXITCODE -ne 0) { throw "third_party_notices.py failed" }

$size = (Get-ChildItem $stage -Recurse -File | Measure-Object Length -Sum).Sum / 1MB
Write-Host ("Staging: {0:N0} MB" -f $size)

& $iscc /Q "/DAppVersion=$version" "/DStageDir=$stage" "/DWithAddon=$withAddon" (Join-Path $here "nvai-setup.iss")
if ($LASTEXITCODE -ne 0) { throw "ISCC: exit $LASTEXITCODE" }
$exe = Join-Path $build "NV-AI-Setup-$version.exe"
Write-Host ("Done: {0} ({1:N0} MB)" -f $exe, ((Get-Item $exe).Length / 1MB)) -ForegroundColor Green
