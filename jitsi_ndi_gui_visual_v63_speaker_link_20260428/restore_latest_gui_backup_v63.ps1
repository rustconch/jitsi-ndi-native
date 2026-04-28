$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$backupDir = Join-Path $root 'backups_gui_v63'
$dst = Join-Path $root 'JitsiNdiGui.ps1'
if (-not (Test-Path $backupDir)) { throw "Backup folder not found: $backupDir" }
$latest = Get-ChildItem -Path $backupDir -Filter 'JitsiNdiGui_before_v63_*.ps1' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $latest) { throw 'No v63 backup found.' }
Copy-Item -Force $latest.FullName $dst
Write-Host "[v63] Restored: $($latest.FullName)"
