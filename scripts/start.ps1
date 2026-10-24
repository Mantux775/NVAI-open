<#
  Startet den NVAI-open-Orchestrator. ComfyUI wird bei Bedarf automatisch nachgestartet.

  -Lan   laesst den Server zusaetzlich im Netz lauschen, damit andere Geraete
         ihn erreichen (Mac-App, PhotoCraft-Bruecke, iOS-App; ueber Tailscale
         auch von unterwegs). Die brauchen dann den Token im Header X-NVAI-Token,
         dieser Rechner nicht. Token-Quelle: $env:NVAI_TOKEN, sonst data\api_token.
         Fehlt beides, legt -Lan data\api_token mit 32 Zufallsbytes an.
#>
param([switch]$Lan)
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$py = Join-Path $repo "server\.venv\Scripts\python.exe"

if (-not (Test-Path $py)) { throw "Server-venv fehlt. Erst scripts\setup_server.ps1 ausfuehren." }

$port = if ($env:NVAI_PORT) { $env:NVAI_PORT } else { "8100" }

# Laeuft schon einer? Dann nicht blind danebenstarten, sondern sagen welcher.
$existing = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
if ($existing) {
    $pid_ = $existing[0].OwningProcess
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $pid_" -ErrorAction SilentlyContinue
    Write-Host "Auf Port $port laeuft bereits ein Prozess:" -ForegroundColor Yellow
    Write-Host "  PID $pid_  seit $($proc.CreationDate)"
    Write-Host "  $($proc.CommandLine)"
    if ($proc.CommandLine -match "nvai.main:app") {
        Write-Host "`nDas ist NVAI-open -- einfach http://127.0.0.1:$port oeffnen." -ForegroundColor Green
        Write-Host "Zum Neustart vorher: scripts\stop.ps1"
    } else {
        Write-Host "`nDas ist NICHT NVAI-open. Anderen Port waehlen:" -ForegroundColor Yellow
        Write-Host '  $env:NVAI_PORT = "8101"; scripts\start.ps1'
    }
    exit 1
}

$bind = "127.0.0.1"

if ($Lan) {
    # Ohne Token bedient der Server fremde Geraete gar nicht (main.py, Zugriffsschutz).
    # Deshalb hier einen anlegen statt abzubrechen -- und zwar einen zufaelligen,
    # kein "geheim" von Hand.
    $dataDir = if ($env:NVAI_DATA_DIR) { $env:NVAI_DATA_DIR } else { Join-Path $repo "data" }
    $tokenFile = if ($env:NVAI_TOKEN_FILE) { $env:NVAI_TOKEN_FILE } else { Join-Path $dataDir "api_token" }
    if ($env:NVAI_TOKEN) {
        $tokenFrom = 'der Umgebungsvariable NVAI_TOKEN'
        if ($env:NVAI_TOKEN.Length -lt 32) {
            Write-Host "Warnung: NVAI_TOKEN hat nur $($env:NVAI_TOKEN.Length) Zeichen. Sicherer ist der" -ForegroundColor Yellow
            Write-Host "  erzeugte aus $tokenFile -- dafuer NVAI_TOKEN leeren und neu starten." -ForegroundColor Yellow
        }
    } else {
        if (-not (Test-Path $tokenFile)) {
            $bytes = New-Object byte[] 32
            [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
            New-Item -ItemType Directory -Force (Split-Path $tokenFile) | Out-Null
            # Ohne BOM und Zeilenumbruch: die Datei wird so in andere Apps kopiert.
            [IO.File]::WriteAllText($tokenFile, (($bytes | ForEach-Object { $_.ToString("x2") }) -join ""))
            Write-Host "Neuen Token angelegt: $tokenFile" -ForegroundColor Green
        }
        $tokenFrom = $tokenFile
    }
    $bind = "0.0.0.0"
    $ip = (Get-NetIPAddress -AddressFamily IPv4 |
           Where-Object { $_.IPAddress -notlike "127.*" -and $_.PrefixOrigin -ne "WellKnown" } |
           Select-Object -First 1).IPAddress
    Write-Host "NVAI-open lauscht im Netz auf http://${ip}:$port" -ForegroundColor Cyan
    Write-Host "  Adresse und Token aus $tokenFrom in Mac-App, PhotoCraft-Bruecke" -ForegroundColor DarkGray
    Write-Host "  oder iOS-App eintragen. Pruefen: GET /api/version zeigt authorized." -ForegroundColor DarkGray
    Write-Host "  Beim ersten Mal fragt die Windows-Firewall -- 'Privates Netz' zulassen." -ForegroundColor DarkGray
} else {
    Write-Host "NVAI-open startet auf http://127.0.0.1:$port" -ForegroundColor Cyan
}

Push-Location (Join-Path $repo "server")
try {
    # Frist beim Beenden: eine offene Weboberflaeche haelt ihren WebSocket sonst ewig (siehe serve.py)
    & $py -m uvicorn nvai.main:app --host $bind --port $port --timeout-graceful-shutdown 5
} finally {
    Pop-Location
}
