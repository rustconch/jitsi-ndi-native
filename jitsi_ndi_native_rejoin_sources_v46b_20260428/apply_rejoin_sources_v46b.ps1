$ErrorActionPreference = "Stop"

$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $patchDir "..")
$srcDir = Join-Path $repoRoot "src"
$backupRoot = Join-Path $repoRoot "backups\v46b_rejoin_sources"
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupDir = Join-Path $backupRoot $stamp

if (-not (Test-Path $srcDir)) {
    throw "src directory not found: $srcDir"
}

New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

$files = @(
    "JitsiSignaling.cpp",
    "NativeWebRTCAnswerer.cpp",
    "NativeWebRTCAnswerer.h",
    "JitsiSourceMap.cpp",
    "JitsiSourceMap.h",
    "PerParticipantNdiRouter.cpp",
    "PerParticipantNdiRouter.h"
)

foreach ($file in $files) {
    $from = Join-Path $srcDir $file
    $to = Join-Path $backupDir $file
    if (Test-Path $from) {
        Copy-Item -Force $from $to
    }
}

foreach ($file in $files) {
    $from = Join-Path (Join-Path $patchDir "src") $file
    $to = Join-Path $srcDir $file
    if (-not (Test-Path $from)) {
        throw "patch file not found: $from"
    }
    Copy-Item -Force $from $to
}

Write-Host "Applied v46b rejoin source recovery patch."
Write-Host "Backup: $backupDir"
Write-Host "Now rebuild with: .\rebuild_with_dav1d_v21.ps1"
