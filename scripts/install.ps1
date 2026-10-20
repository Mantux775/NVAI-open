<#
  Einmalige Einrichtung auf einem neuen Rechner.

  Holt ComfyUI, legt zwei getrennte venvs an (Server und Backend), prueft die
  Grafikkarte und sagt am Ende, welche Modelle auf diese Karte passen.

  Voraussetzungen, die NICHT automatisch installiert werden:
    - NVIDIA-Grafikkarte mit aktuellem Treiber
    - git            https://git-scm.com/download/win
    - uv             https://docs.astral.sh/uv/    (winget install astral-sh.uv)
#>
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot

function Step($text) { Write-Host "`n== $text ==" -ForegroundColor Cyan }
function Ok($text)   { Write-Host "   $text" -ForegroundColor Green }
function Warn($text) { Write-Host "   $text" -ForegroundColor Yellow }

# ---------------------------------------------------------- Voraussetzungen

Step "Voraussetzungen"
foreach ($tool in @("git", "uv")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "'$tool' fehlt. Bitte zuerst installieren (siehe Kopf dieser Datei)."
    }
    Ok "$tool gefunden"
}

$smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if (-not $smi) {
    Warn "nvidia-smi nicht gefunden - ohne NVIDIA-Karte laeuft die Generierung nicht."
    $vramGb = 0
} else {
    $line = (& nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits) -split "`n" | Select-Object -First 1
    $parts = $line -split ","
    $gpuName = $parts[0].Trim()
    $vramGb = [math]::Round([int]$parts[1].Trim() / 1024, 1)
    Ok "$gpuName mit $vramGb GB VRAM"
}

# --------------------------------------------------------------- ComfyUI

Step "ComfyUI"
$comfy = Join-Path $repo "external\comfyui"
# Auf die Version festgenagelt, gegen die alle Graph-Builder geprueft wurden.
# 0.41.3: erste Fassung mit FLUX 3 Image Klein (CLIPLoader-Typ flux3, TextGenerate).
# 0.42.1: Qwen3.5-Chat-Template im Upsampler repariert (PR 17121), Textgenerierung raeumt auf.
$comfyTag = "v0.42.1"
if (Test-Path (Join-Path $comfy ".git")) {
    $have = (git -C $comfy describe --tags 2>$null)
    if ($have -eq $comfyTag) {
        Ok "liegt bereits vor ($comfyTag) - uebersprungen"
    } else {
        # Aeltere Klone auf die gepruefte Fassung heben; setup_comfyui.ps1 zieht danach die Pakete nach.
        git -C $comfy fetch --depth 1 origin tag $comfyTag
        git -C $comfy checkout -q $comfyTag
        if ($LASTEXITCODE -ne 0) { throw "ComfyUI liess sich nicht auf $comfyTag umstellen (lokale Aenderungen?)" }
        Ok "ComfyUI von $have auf $comfyTag gehoben"
    }
} else {
    New-Item -ItemType Directory -Force (Join-Path $repo "external") | Out-Null
    # Ein neuerer Stand kann Node-Signaturen aendern und Workflows brechen.
    git clone --depth 1 --branch $comfyTag https://github.com/comfyanonymous/ComfyUI.git $comfy
    Ok "ComfyUI $comfyTag geholt"
}

Step "ComfyUI-Umgebung (Torch, dauert einige Minuten)"
& (Join-Path $PSScriptRoot "setup_comfyui.ps1")

# ---------------------------------------------------------------- Server

Step "Server-Umgebung"
& (Join-Path $PSScriptRoot "setup_server.ps1")

# -------------------------------------------------------------- Frontend

Step "Frontend"
$dist = Join-Path $repo "frontend\dist\index.html"
if (Test-Path $dist) {
    Ok "fertig gebaut im Archiv enthalten"
} elseif (Get-Command npm -ErrorAction SilentlyContinue) {
    Push-Location (Join-Path $repo "frontend")
    npm install; npm run build
    Pop-Location
    Ok "neu gebaut"
} else {
    Warn "Kein dist/ und kein npm - die Weboberflaeche fehlt. Die MCP-Tools laufen trotzdem."
}

# ------------------------------------------------ Empfehlung nach VRAM

Step "Passende Modelle fuer diese Karte"
if ($vramGb -eq 0) {
    Warn "Keine Karte erkannt - keine Empfehlung moeglich."
} else {
    # Budget: Windows und die Aktivierungen brauchen selbst rund 1,5 GB.
    $budget = [math]::Round($vramGb - 1.5, 1)
    Write-Host "   Nutzbar fuer ein Modell: ca. $budget GB`n"

    if ($budget -ge 13) {
        Write-Host "   Bild   : chroma1-hd-fp8   (bester Malstil, negativer Prompt wirkt)"
        Write-Host "   Bild   : longcat-image    (trifft Handlungen am zuverlaessigsten)"
        Write-Host "   Video  : wan22-ti2v-5b    (Text- und Bild-zu-Video)"
        Write-Host "   3D     : trellis2-4b      (Mesh mit PBR-Texturen)"
    } elseif ($budget -ge 10) {
        Write-Host "   Bild   : z-image          (starke Prompt-Treue, 6 B Parameter)"
        Write-Host "   Bild   : chroma1-hd-fp8   (knapp - vorher VRAM leeren)"
        Write-Host "   Video  : wan21-t2v-1.3b   (laeuft entspannt)"
        Write-Host "   3D     : triposg          (Geometrie ohne Textur)"
    } elseif ($budget -ge 6.5) {
        Write-Host "   Bild   : z-image-int8     (dasselbe Modell quantisiert, ~7 GB)"
        Write-Host "   Bild   : sdxl-base        (schnell und genuegsam)"
        Write-Host "   Video  : ltxv-2b-095      (schnellstes Videomodell)"
        Write-Host "   3D     : triposg          (knapp)"
    } else {
        Warn "Unter 8 GB VRAM wird es eng. sdxl-base und ltxv-2b-095 sind einen Versuch wert."
    }
    Write-Host "`n   Die Weboberflaeche markiert zu grosse Modelle automatisch." -ForegroundColor DarkGray
}

# ------------------------------------------------------------------ Ende

$py = Join-Path $repo "server\.venv\Scripts\python.exe"
Write-Host "`n============================================================" -ForegroundColor Green
Write-Host " Fertig." -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "`n Starten:        scripts\start.ps1   ->  http://127.0.0.1:8100"
Write-Host " Beenden:        scripts\stop.ps1"
Write-Host "`n Fuer Claude Code registrieren:" -ForegroundColor Yellow
Write-Host "   claude mcp add nvai -- `"$py`" -m nvai.mcp_server"
Write-Host "`n Modelle sind NICHT im Archiv - sie werden in der Weboberflaeche"
Write-Host " unter 'Modelle' geladen (mehrere GB pro Modell)."
