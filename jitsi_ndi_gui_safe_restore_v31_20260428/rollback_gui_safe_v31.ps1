# Restore the latest JitsiNdiGui.ps1 backup created by safe GUI patch
$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
$backupDir = Join-Path $repoRoot ".jnn_patch_backups"
$target = Join-Path $repoRoot "JitsiNdiGui.ps1"
if (-not (Test-Path -LiteralPath $backupDir)) { throw "Backup dir not found: $backupDir" }
$latest = Get-ChildItem -LiteralPath $backupDir -Filter "JitsiNdiGui_before_safe_v31_*.ps1" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $latest) { throw "No safe v31 backup found in $backupDir" }
Copy-Item -LiteralPath $latest.FullName -Destination $target -Force
Write-Host "Restored:" $latest.FullName
