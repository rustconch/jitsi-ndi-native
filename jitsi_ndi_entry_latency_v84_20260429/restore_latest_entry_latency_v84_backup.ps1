$ErrorActionPreference = "Stop"

$PatchDir = $PSScriptRoot
$Root = Split-Path -Parent $PatchDir
$BackupRoot = Join-Path $Root ".jnn_patch_backups"
$SrcDir = Join-Path $Root "src"
$Target = Join-Path $SrcDir "NativeWebRTCAnswerer.cpp"

if (!(Test-Path $BackupRoot)) {
    throw "Backup root not found: $BackupRoot"
}

$Latest = Get-ChildItem -Directory $BackupRoot -Filter "entry_latency_v84_*" | Sort-Object Name -Descending | Select-Object -First 1
if ($null -eq $Latest) {
    throw "No entry_latency_v84 backup found."
}

$BackupFile = Join-Path $Latest.FullName "NativeWebRTCAnswerer.cpp"
if (!(Test-Path $BackupFile)) {
    throw "Backup file not found: $BackupFile"
}

Copy-Item -Force $BackupFile $Target
Write-Host "Restored NativeWebRTCAnswerer.cpp from: $($Latest.FullName)"
Write-Host "Rebuild with: .\rebuild_with_dav1d_v21.ps1"
