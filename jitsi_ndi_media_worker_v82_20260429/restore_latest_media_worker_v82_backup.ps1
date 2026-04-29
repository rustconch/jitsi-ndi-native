$ErrorActionPreference = "Stop"

$PatchDir = $PSScriptRoot
$Root = Split-Path -Parent $PatchDir
$BackupRoot = Join-Path $Root ".jnn_patch_backups"

if (!(Test-Path $BackupRoot)) {
    throw "Backup root not found: $BackupRoot"
}

$Latest = Get-ChildItem -Path $BackupRoot -Directory -Filter "media_worker_v82_*" |
    Sort-Object Name -Descending |
    Select-Object -First 1

if ($null -eq $Latest) {
    throw "No media_worker_v82 backup found."
}

$BackupFile = Join-Path $Latest.FullName "NativeWebRTCAnswerer.cpp"
$Target = Join-Path $Root "src\NativeWebRTCAnswerer.cpp"

if (!(Test-Path $BackupFile)) {
    throw "Backup file not found: $BackupFile"
}

Copy-Item -Force $BackupFile $Target

Write-Host "Restored media worker v82 backup:"
Write-Host $Latest.FullName
Write-Host "Rebuild with: .\rebuild_with_dav1d_v21.ps1"
