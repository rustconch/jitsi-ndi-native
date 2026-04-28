$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dst = Join-Path $root 'JitsiNdiGui.ps1'
$backupDir = Join-Path $root 'backups_gui'
$latest = Get-ChildItem -Path $backupDir -Filter 'JitsiNdiGui_before_v64_*.ps1' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $latest) { throw 'No v64 GUI backup found.' }
Copy-Item -Force $latest.FullName $dst
Write-Host "[v64] Restored GUI backup: $($latest.Name)"
