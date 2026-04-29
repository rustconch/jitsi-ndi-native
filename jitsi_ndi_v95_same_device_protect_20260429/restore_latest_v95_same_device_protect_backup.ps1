$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "..")
$srcDir = Join-Path $repoRoot "src"
$backup = Get-ChildItem -Directory $repoRoot -Filter "backup_v95_same_device_protect_*" | Sort-Object Name -Descending | Select-Object -First 1
if (!$backup) { throw "No backup_v95_same_device_protect_* directory found." }
Get-ChildItem $backup.FullName -File | ForEach-Object {
    Copy-Item -Force $_.FullName (Join-Path $srcDir $_.Name)
}
Write-Host "Restored from" $backup.FullName
