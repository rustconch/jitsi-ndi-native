$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$backupDir = Join-Path $root "gui_backups"
if (-not (Test-Path $backupDir)) { throw "No gui_backups directory found." }
$latest = Get-ChildItem -LiteralPath $backupDir -Filter "JitsiNdiGui_before_v38_*.ps1" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $latest) { throw "No v38 backup found." }
Copy-Item -LiteralPath $latest.FullName -Destination (Join-Path $root "JitsiNdiGui.ps1") -Force
Write-Host "Restored: $($latest.FullName)"
