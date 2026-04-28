$ErrorActionPreference = "Stop"
$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $patchDir
$backupRoot = Join-Path $repoRoot ".jnn_patch_backups"
$latest = Get-ChildItem -Path $backupRoot -Directory -Filter "quality_v42_stable_selected_*" | Sort-Object Name -Descending | Select-Object -First 1
if (-not $latest) { throw "No quality_v42_stable_selected backup found" }
$src = Join-Path $latest.FullName "src\NativeWebRTCAnswerer.cpp"
$dst = Join-Path $repoRoot "src\NativeWebRTCAnswerer.cpp"
if (-not (Test-Path $src)) { throw "Backup file not found: $src" }
Copy-Item -Force $src $dst
Write-Host "Restored latest v42 backup: $($latest.FullName)"
Write-Host "Now rebuild: .\rebuild_with_dav1d_v21.ps1"
