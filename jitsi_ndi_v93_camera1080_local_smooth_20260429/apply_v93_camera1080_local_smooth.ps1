$ErrorActionPreference = "Stop"

$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $patchDir "..")
$srcDir = Join-Path $repoRoot "src"

if (!(Test-Path $srcDir)) {
    throw "src directory not found. Extract this patch folder into the repo root and run the script from there."
}

$required = @(
    "NativeWebRTCAnswerer.cpp",
    "NativeWebRTCAnswerer.h",
    "main.cpp",
    "PerParticipantNdiRouter.cpp",
    "PerParticipantNdiRouter.h",
    "FfmpegMediaDecoder.cpp",
    "FfmpegMediaDecoder.h"
)

foreach ($file in $required) {
    $patchFile = Join-Path $patchDir $file
    if (!(Test-Path $patchFile)) {
        throw "Patch file missing: $file"
    }
}

$backupDir = Join-Path $repoRoot ("backup_v93_camera1080_local_smooth_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

foreach ($file in $required) {
    $target = Join-Path $srcDir $file
    if (Test-Path $target) {
        Copy-Item -Force $target (Join-Path $backupDir $file)
    }
    Copy-Item -Force (Join-Path $patchDir $file) $target
}

Write-Host "v93 applied. Backup:" $backupDir
Write-Host "Changes: camera constraints 1080p/30fps, screen-share remains 1080p/30fps, 6.7Mbps receive cap remains, global reconnect remains disabled, source-local AV1 decoder soft reset added."
Write-Host "Now rebuild with: .\rebuild_with_dav1d_v21.ps1"
