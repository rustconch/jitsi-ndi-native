$ErrorActionPreference = 'Stop'

$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir = Resolve-Path (Join-Path $patchDir '..')
$backupDir = Join-Path $repoDir ("backup_rejoin_cleanup_v48_" + (Get-Date -Format "yyyyMMdd_HHmmss"))

$files = @(
  'src\JitsiSignaling.cpp',
  'src\JitsiSourceMap.cpp',
  'src\JitsiSourceMap.h',
  'src\NativeWebRTCAnswerer.cpp',
  'src\NativeWebRTCAnswerer.h',
  'src\PerParticipantNdiRouter.cpp',
  'src\PerParticipantNdiRouter.h'
)

New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $backupDir 'src') | Out-Null

foreach ($rel in $files) {
  $src = Join-Path $patchDir $rel
  $dst = Join-Path $repoDir $rel
  if (-not (Test-Path $src)) { throw "Patch file missing: $src" }
  if (Test-Path $dst) {
    Copy-Item -Force $dst (Join-Path $backupDir $rel)
  }
  Copy-Item -Force $src $dst
}

Write-Host "v48 rejoin cleanup patch applied. Backup: $backupDir"
Write-Host "Now rebuild: .\rebuild_with_dav1d_v21.ps1"
