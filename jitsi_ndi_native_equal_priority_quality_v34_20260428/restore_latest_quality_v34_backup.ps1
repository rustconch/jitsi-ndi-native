$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
$backupDir = Join-Path $projectRoot "backups"
$dst = Join-Path $projectRoot "src\NativeWebRTCAnswerer.cpp"

if (-not (Test-Path $backupDir)) {
    throw "Backup directory not found: $backupDir"
}

$latest = Get-ChildItem $backupDir -Filter "NativeWebRTCAnswerer.cpp.backup_quality_v34_*" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if (-not $latest) {
    throw "No v34 quality backup found in: $backupDir"
}

Copy-Item -Force $latest.FullName $dst

Write-Host "[v34] Restored: $($latest.FullName)"
