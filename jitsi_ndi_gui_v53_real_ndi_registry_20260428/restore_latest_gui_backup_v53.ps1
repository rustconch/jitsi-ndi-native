$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$backupDir = Join-Path $root "gui_backups"
$dst = Join-Path $root "JitsiNdiGui.ps1"
if (-not (Test-Path $backupDir)) { throw "Backup dir not found: $backupDir" }
$latest = Get-ChildItem -LiteralPath $backupDir -Filter "JitsiNdiGui_before_v53_*.ps1" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $latest) { throw "No v53 backup found." }
Copy-Item -LiteralPath $latest.FullName -Destination $dst -Force
Write-Host "Restored: $($latest.FullName)"
