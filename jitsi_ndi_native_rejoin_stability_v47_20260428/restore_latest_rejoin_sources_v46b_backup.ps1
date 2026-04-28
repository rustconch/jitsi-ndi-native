$ErrorActionPreference = "Stop"

$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $patchDir "..")
$srcDir = Join-Path $repoRoot "src"
$backupRoot = Join-Path $repoRoot "backups\v46b_rejoin_sources"

if (-not (Test-Path $backupRoot)) {
    throw "backup directory not found: $backupRoot"
}

$latest = Get-ChildItem -Directory $backupRoot | Sort-Object Name -Descending | Select-Object -First 1
if ($null -eq $latest) {
    throw "no v46b backup found"
}

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
    $from = Join-Path $latest.FullName $file
    $to = Join-Path $srcDir $file
    if (Test-Path $from) {
        Copy-Item -Force $from $to
    }
}

Write-Host "Restored latest v46b backup: $($latest.FullName)"
Write-Host "Now rebuild with: .\rebuild_with_dav1d_v21.ps1"
