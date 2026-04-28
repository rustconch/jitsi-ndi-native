$ErrorActionPreference = "Stop"

$patchRoot = $PSScriptRoot
$repoRoot = Split-Path -Parent $patchRoot
$backupBase = Join-Path $repoRoot ".jnn_patch_backups"

if (-not (Test-Path $backupBase)) {
    throw "Backup folder not found: $backupBase"
}

$latest = Get-ChildItem -Path $backupBase -Directory -Filter "quality_v40_*" |
    Sort-Object Name -Descending |
    Select-Object -First 1

if ($null -eq $latest) {
    throw "No quality_v40 backup found"
}

$backupSrc = Join-Path $latest.FullName "src"
$repoSrc = Join-Path $repoRoot "src"

foreach ($file in @("NativeWebRTCAnswerer.cpp", "NDISender.cpp")) {
    $backupFile = Join-Path $backupSrc $file
    if (Test-Path $backupFile) {
        Copy-Item -Force $backupFile (Join-Path $repoSrc $file)
    }
}

Write-Host "Restored latest quality v40 backup: $($latest.FullName)"
Write-Host "Rebuild the native exe after restore."
