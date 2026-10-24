<#
  Creates the shortcut "NVAI-open for PhotoCraft" on the desktop and in the Start menu.
  It starts NVAI-open (if needed), PhotoCraft with its control channel, and the NVAI-open panel.

  -Remove   remove the shortcuts again
#>
param([switch]$Remove)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$pyw = Join-Path $root ".venv\Scripts\pythonw.exe"
$folders = @([Environment]::GetFolderPath("Desktop"), [Environment]::GetFolderPath("Programs"))
$name = "NVAI-open for PhotoCraft.lnk"
# Earlier names of the same shortcut (the app was called NV-AI up to 0.5.7): replaced on install,
# removed with -Remove.
$legacy = @("PhotoCraft + NV-AI.lnk", "NV-AI for PhotoCraft.lnk")

foreach ($folder in $folders) {
    foreach ($l in $legacy) {
        $old = Join-Path $folder $l
        if (Test-Path $old) { Remove-Item $old; Write-Host "removed: $old" }
    }
}
if ($Remove) {
    foreach ($folder in $folders) {
        $t = Join-Path $folder $name
        if (Test-Path $t) { Remove-Item $t; Write-Host "removed: $t" }
    }
    return
}
if (-not (Test-Path $pyw)) { throw "The venv is missing. Run scripts\setup.ps1 first." }

$icon = Join-Path $root "panel\icon.ico"
$shell = New-Object -ComObject WScript.Shell
foreach ($folder in $folders) {
    $t = Join-Path $folder $name
    $lnk = $shell.CreateShortcut($t)
    $lnk.TargetPath = $pyw
    $lnk.Arguments = "-m bridge --launch"
    $lnk.WorkingDirectory = $root
    $lnk.Description = "Start PhotoCraft with local AI (NVAI-open)"
    if (Test-Path $icon) { $lnk.IconLocation = "$icon,0" }
    $lnk.Save()
    Write-Host "created: $t"
}
