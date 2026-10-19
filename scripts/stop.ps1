# Beendet NV-AI und ComfyUI -- gezielt ueber die Prozesse, die auf den Ports
# lauschen, und nur wenn die Kommandozeile wirklich zu NV-AI gehoert.
# Kein pauschales "alle python.exe beenden".
$ErrorActionPreference = "Stop"

$targets = @(
    @{ Port = 8100; Match = "nvai.main:app"; Name = "NV-AI-Orchestrator" },
    @{ Port = 8188; Match = "main.py";       Name = "ComfyUI" }
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
