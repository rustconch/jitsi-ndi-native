$ErrorActionPreference = "Stop"

$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir = Split-Path -Parent $patchDir
$backupDir = Join-Path $repoDir ("backup_rejoin_lifecycle_v44_" + (Get-Date -Format "yyyyMMdd_HHmmss"))

$files = @(
  "src\JitsiSourceMap.cpp",
  "src\JitsiSourceMap.h",
  "src\PerParticipantNdiRouter.cpp",
  "src\PerParticipantNdiRouter.h",
  "src\NativeWebRTCAnswerer.cpp",
  "src\NativeWebRTCAnswerer.h",
  "src\JitsiSignaling.cpp"
)

New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

foreach ($rel in $files) {
  $src = Join-Path $patchDir $rel
  $dst = Join-Path $repoDir $rel
  if (-not (Test-Path $src)) { throw "Patch file not found: $src" }
  if (-not (Test-Path $dst)) { throw "Repo file not found: $dst" }

  $backupPath = Join-Path $backupDir $rel
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backupPath) | Out-Null
  Copy-Item -Force $dst $backupPath
  Copy-Item -Force $src $dst
}

Write-Host "Applied v44 rejoin lifecycle patch."
Write-Host "Backup: $backupDir"
Write-Host "Now rebuild: .\rebuild_with_dav1d_v21.ps1"
