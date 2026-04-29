$ErrorActionPreference = "Stop"

$root = (Get-Location).Path
$srcDir = Join-Path $root "src"
$target = Join-Path $srcDir "NativeWebRTCAnswerer.cpp"

$backup = Get-ChildItem -Path $root -Directory -Filter "backup_v85_overload_guard_*" |
    Sort-Object Name -Descending |
    Select-Object -First 1

if ($null -eq $backup) {
    throw "No backup_v85_overload_guard_* directory found."
}

$backupFile = Join-Path $backup.FullName "NativeWebRTCAnswerer.cpp"
if (!(Test-Path $backupFile)) {
    throw "Backup file not found: $backupFile"
}

Copy-Item -Force $backupFile $target
Write-Host "Restored NativeWebRTCAnswerer.cpp from: $($backup.FullName)"
Write-Host "Now rebuild with: .\rebuild_with_dav1d_v21.ps1"
