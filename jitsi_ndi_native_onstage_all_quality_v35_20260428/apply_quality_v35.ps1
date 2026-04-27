$ErrorActionPreference = "Stop"

$root = (Get-Location).Path
$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$src = Join-Path $patchDir "src\NativeWebRTCAnswerer.cpp"
$dst = Join-Path $root "src\NativeWebRTCAnswerer.cpp"

if (-not (Test-Path $src)) {
    throw "Patch source file not found: $src"
}

if (-not (Test-Path $dst)) {
    throw "Target file not found. Run this script from the repository root: $dst"
}

$backupDir = Join-Path $root ("backup_quality_v35_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
Copy-Item -Force $dst (Join-Path $backupDir "NativeWebRTCAnswerer.cpp")

Copy-Item -Force $src $dst

Write-Host "Applied quality v35 all-on-stage patch."
Write-Host "Backup saved to: $backupDir"
Write-Host "Now rebuild the native exe, for example:"
Write-Host "  .\rebuild_with_dav1d_v21.ps1"
