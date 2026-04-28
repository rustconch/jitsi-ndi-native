$ErrorActionPreference = 'Stop'
$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $patchDir
$backups = Get-ChildItem -LiteralPath $root -Filter 'JitsiNdiGui.backup_v61_*.ps1' | Sort-Object LastWriteTime -Descending
if (-not $backups -or $backups.Count -eq 0) { throw 'No v61 GUI backup found.' }
Copy-Item -LiteralPath $backups[0].FullName -Destination (Join-Path $root 'JitsiNdiGui.ps1') -Force
Write-Host "[v61] Restored: $($backups[0].Name)"
