$ErrorActionPreference = 'Stop'

$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir = Resolve-Path (Join-Path $patchDir '..')
$backup = Get-ChildItem -Path $repoDir -Directory -Filter 'backup_rejoin_cleanup_v48_*' | Sort-Object Name -Descending | Select-Object -First 1
if (-not $backup) { throw 'No backup_rejoin_cleanup_v48_* directory found.' }

$files = @(
  'src\JitsiSignaling.cpp',
  'src\JitsiSourceMap.cpp',
  'src\JitsiSourceMap.h',
  'src\NativeWebRTCAnswerer.cpp',
  'src\NativeWebRTCAnswerer.h',
  'src\PerParticipantNdiRouter.cpp',
  'src\PerParticipantNdiRouter.h'
)

foreach ($rel in $files) {
  $src = Join-Path $backup.FullName $rel
  $dst = Join-Path $repoDir $rel
  if (Test-Path $src) { Copy-Item -Force $src $dst }
}

Write-Host "Restored backup: $($backup.FullName)"
Write-Host "Now rebuild: .\rebuild_with_dav1d_v21.ps1"
