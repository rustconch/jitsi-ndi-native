$ErrorActionPreference = "Stop"
$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $patchDir
$src = Join-Path $patchDir "src\NativeWebRTCAnswerer.cpp"
$dst = Join-Path $repoRoot "src\NativeWebRTCAnswerer.cpp"
if (-not (Test-Path $src)) { throw "Patch file not found: $src" }
if (-not (Test-Path $dst)) { throw "Target file not found: $dst" }
$backupRoot = Join-Path $repoRoot ".jnn_patch_backups"
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupDir = Join-Path $backupRoot "quality_v42_stable_selected_$stamp\src"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
Copy-Item -Force $dst (Join-Path $backupDir "NativeWebRTCAnswerer.cpp")
Copy-Item -Force $src $dst
Write-Host "Applied quality v42 stable selected-only patch."
Write-Host "Backup saved to: $backupDir"
Write-Host "Now rebuild: .\rebuild_with_dav1d_v21.ps1"
