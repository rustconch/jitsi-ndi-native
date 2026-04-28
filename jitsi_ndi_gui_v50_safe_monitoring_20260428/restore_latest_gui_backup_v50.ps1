$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$backupDir = Join-Path $root "backups"
$dst = Join-Path $root "JitsiNdiGui.ps1"
if (-not (Test-Path $backupDir)) { throw "Backup folder not found: $backupDir" }
$latest = Get-ChildItem -LiteralPath $backupDir -Filter "JitsiNdiGui_before_v50_*.ps1" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $latest) { throw "No v50 GUI backup found." }
Copy-Item -LiteralPath $latest.FullName -Destination $dst -Force
Write-Host "[v50] Restored: $($latest.FullName)"
