$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "..")
$srcDir = Join-Path $repoRoot "src"
$backup = Get-ChildItem -Path $repoRoot -Directory -Filter "backup_v96_rollback_stable_v94_*" | Sort-Object Name -Descending | Select-Object -First 1
if (!$backup) { throw "No backup_v96_rollback_stable_v94_* folder found." }
Get-ChildItem -Path $backup.FullName -File | ForEach-Object {
    Copy-Item -Force $_.FullName (Join-Path $srcDir $_.Name)
}
Write-Host "Restored from:" $backup.FullName
