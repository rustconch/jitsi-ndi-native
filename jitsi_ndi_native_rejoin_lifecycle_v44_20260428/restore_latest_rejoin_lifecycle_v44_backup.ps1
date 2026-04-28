$ErrorActionPreference = "Stop"
$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir = Split-Path -Parent $patchDir
$backup = Get-ChildItem -Path $repoDir -Directory -Filter "backup_rejoin_lifecycle_v44_*" | Sort-Object Name -Descending | Select-Object -First 1
if (-not $backup) { throw "No v44 backup folder found." }

$files = @(
  "src\JitsiSourceMap.cpp",
  "src\JitsiSourceMap.h",
  "src\PerParticipantNdiRouter.cpp",
  "src\PerParticipantNdiRouter.h",
  "src\NativeWebRTCAnswerer.cpp",
  "src\NativeWebRTCAnswerer.h",
  "src\JitsiSignaling.cpp"
)

foreach ($rel in $files) {
  $src = Join-Path $backup.FullName $rel
  $dst = Join-Path $repoDir $rel
  if (Test-Path $src) { Copy-Item -Force $src $dst }
}

Write-Host "Restored backup: $($backup.FullName)"
Write-Host "Now rebuild: .\rebuild_with_dav1d_v21.ps1"
