$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "..")
$srcDir = Join-Path $repoRoot "src"
$backup = Get-ChildItem -Directory -Path $repoRoot -Filter "backup_v97_same_device_cold_av1_recovery_*" | Sort-Object Name -Descending | Select-Object -First 1
if (!$backup) { throw "No v97 backup directory found." }
Copy-Item -Force (Join-Path $backup.FullName "*") $srcDir
Write-Host "Restored backup:" $backup.FullName
