$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir

$src = Join-Path $scriptDir "src\NativeWebRTCAnswerer.cpp"
$dst = Join-Path $projectRoot "src\NativeWebRTCAnswerer.cpp"
$backupDir = Join-Path $projectRoot "backups"

if (-not (Test-Path $src)) {
    throw "Patch source not found: $src"
}

if (-not (Test-Path $dst)) {
    throw "Target file not found: $dst"
}

if (-not (Test-Path $backupDir)) {
    New-Item -ItemType Directory -Path $backupDir | Out-Null
}

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backup = Join-Path $backupDir ("NativeWebRTCAnswerer.cpp.backup_quality_v34_" + $stamp)

Copy-Item -Force $dst $backup
Copy-Item -Force $src $dst

Write-Host "[v34] Applied equal-priority quality patch."
Write-Host "[v34] Backup saved to: $backup"
Write-Host "[v34] Changed only: src\NativeWebRTCAnswerer.cpp"
Write-Host "[v34] Now rebuild the native exe, for example:"
Write-Host "      .\rebuild_with_dav1d_v21.ps1"
Write-Host "   or .\scripts\build.ps1"
