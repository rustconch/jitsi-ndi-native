$ErrorActionPreference = "Stop"
$root = (Get-Location).Path
$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupDir = Join-Path $root ("backup_rejoin_renegotiate_v49_" + $stamp)
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

$files = @(
  "src\JitsiSignaling.cpp",
  "src\JitsiSourceMap.cpp",
  "src\JitsiSourceMap.h",
  "src\NativeWebRTCAnswerer.cpp",
  "src\NativeWebRTCAnswerer.h",
  "src\PerParticipantNdiRouter.cpp",
  "src\PerParticipantNdiRouter.h"
)

foreach ($rel in $files) {
  $src = Join-Path $patchDir $rel
  $dst = Join-Path $root $rel
  if (-not (Test-Path $src)) { throw "Patch file missing: $src" }
  if (Test-Path $dst) {
    $backupPath = Join-Path $backupDir $rel
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backupPath) | Out-Null
    Copy-Item -Force $dst $backupPath
  }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
  Copy-Item -Force $src $dst
}

Write-Host "Applied rejoin renegotiate v49. Backup: $backupDir"
Write-Host "Now rebuild: .\rebuild_with_dav1d_v21.ps1"
