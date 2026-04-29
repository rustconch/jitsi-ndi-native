$ErrorActionPreference = "Stop"

$PatchDir = $PSScriptRoot
$Root = Split-Path -Parent $PatchDir
$SrcDir = Join-Path $Root "src"
$Target = Join-Path $SrcDir "NativeWebRTCAnswerer.cpp"

if (!(Test-Path $Target)) {
    throw "Target file not found: $Target"
}

$Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$BackupDir = Join-Path $Root ".jnn_patch_backups\low_latency_media_queue_v83_$Stamp"
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

Copy-Item -Force $Target (Join-Path $BackupDir "NativeWebRTCAnswerer.cpp")
Copy-Item -Force (Join-Path $PatchDir "NativeWebRTCAnswerer.cpp") $Target

Write-Host "Applied low-latency media queue v83."
Write-Host "Backup: $BackupDir"
Write-Host "Rebuild with: .\rebuild_with_dav1d_v21.ps1"
