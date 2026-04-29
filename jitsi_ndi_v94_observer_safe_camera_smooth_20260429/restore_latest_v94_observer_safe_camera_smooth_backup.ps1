$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "..")
$srcDir = Join-Path $repoRoot "src"
$backup = Get-ChildItem -Directory $repoRoot -Filter "backup_v94_observer_safe_camera_smooth_*" | Sort-Object Name -Descending | Select-Object -First 1
if (!$backup) { throw "No backup_v94_observer_safe_camera_smooth_* directory found." }
Get-ChildItem $backup.FullName -File | ForEach-Object {
    Copy-Item -Force $_.FullName (Join-Path $srcDir $_.Name)
}
Write-Host "Restored from" $backup.FullName
