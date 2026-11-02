# Beendet NVAI-open und ComfyUI -- gezielt ueber die Prozesse, die auf den Ports
# lauschen, und nur wenn die Kommandozeile wirklich zu NVAI-open gehoert.
# Kein pauschales "alle python.exe beenden".
$ErrorActionPreference = "Stop"

$targets = @(
    @{ Port = 8100; Match = "nvai.main:app"; Name = "NVAI-open-Orchestrator" },
    @{ Port = 8188; Match = "main.py";       Name = "ComfyUI" },
    # Zweites ComfyUI fuer Sprachmodelle (mehrere Grafikkarten, experimentell seit 0.5)
    @{ Port = 8189; Match = "main.py";       Name = "ComfyUI (Text)" },
    # 3D-Worker: nach einem harten Ende des Servers gehoeren sie keinem Prozess mehr und behielten den VRAM
    @{ Port = 8200; Match = "triposg_worker";  Name = "TripoSG-Worker" },
    @{ Port = 8201; Match = "trellis2_worker"; Name = "TRELLIS.2-Worker" }
)

foreach ($t in $targets) {
    $conns = Get-NetTCPConnection -LocalPort $t.Port -State Listen -ErrorAction SilentlyContinue
    if (-not $conns) {
        Write-Host "Port $($t.Port): nichts aktiv ($($t.Name))" -ForegroundColor DarkGray
        continue
    }
    foreach ($c in $conns) {
        $procId = $c.OwningProcess
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $procId" -ErrorAction SilentlyContinue
        if (-not $proc) { continue }

        if ($proc.CommandLine -notmatch [regex]::Escape($t.Match)) {
            Write-Host "Port $($t.Port): PID $procId gehoert NICHT zu $($t.Name) -- bleibt unangetastet." -ForegroundColor Yellow
            Write-Host "  $($proc.CommandLine)"
            continue
        }

        Write-Host "Beende $($t.Name) (PID $procId)" -ForegroundColor Cyan
        Stop-Process -Id $procId -Force
    }
}

Write-Host "Fertig." -ForegroundColor Green
