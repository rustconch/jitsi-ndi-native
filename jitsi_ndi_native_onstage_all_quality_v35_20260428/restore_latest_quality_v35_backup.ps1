$ErrorActionPreference = "Stop"

$root = (Get-Location).Path
$backups = Get-ChildItem -Path $root -Directory -Filter "backup_quality_v35_*" | Sort-Object Name -Descending

if (-not $backups -or $backups.Count -eq 0) {
    throw "No backup_quality_v35_* directory found."
}

$backupFile = Join-Path $backups[0].FullName "NativeWebRTCAnswerer.cpp"
$dst = Join-Path $root "src\NativeWebRTCAnswerer.cpp"

if (-not (Test-Path $backupFile)) {
    throw "Backup file not found: $backupFile"
}

Copy-Item -Force $backupFile $dst
Write-Host "Restored NativeWebRTCAnswerer.cpp from: $($backups[0].FullName)"
