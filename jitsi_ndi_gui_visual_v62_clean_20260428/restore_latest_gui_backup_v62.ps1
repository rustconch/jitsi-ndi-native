$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$backupDir = Join-Path $root 'backups'
$dst = Join-Path $root 'JitsiNdiGui.ps1'
if (-not (Test-Path $backupDir)) { throw "Backup folder not found: $backupDir" }
$backup = Get-ChildItem -Path $backupDir -Filter 'JitsiNdiGui_before_v62_*.ps1' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $backup) { throw 'No v62 GUI backup found.' }
Copy-Item -Force $backup.FullName $dst
Write-Host "[v62] Restored: $($backup.FullName)"
