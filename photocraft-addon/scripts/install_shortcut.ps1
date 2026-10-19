<#
  Creates the shortcut "NV-AI for PhotoCraft" on the desktop and in the Start menu.
  It starts NV-AI (if needed), PhotoCraft with its control channel, and the NV-AI panel.

  -Remove   remove the shortcuts again
#>
param([switch]$Remove)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$pyw = Join-Path $root ".venv\Scripts\pythonw.exe"
$folders = @([Environment]::GetFolderPath("Desktop"), [Environment]::GetFolderPath("Programs"))
$name = "NV-AI for PhotoCraft.lnk"
# Earlier name of the same shortcut: replaced on install, removed with -Remove.
$legacy = "PhotoCraft + NV-AI.lnk"

foreach ($folder in $folders) {
    $old = Join-Path $folder $legacy
    if (Test-Path $old) { Remove-Item $old; Write-Host "removed: $old" }
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
    $lnk.Description = "Start PhotoCraft with local AI (NV-AI)"
    if (Test-Path $icon) { $lnk.IconLocation = "$icon,0" }
    $lnk.Save()
    Write-Host "created: $t"
}
