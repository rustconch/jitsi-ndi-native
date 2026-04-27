$ErrorActionPreference = 'Stop'

$root = (Get-Location).Path
$files = @(
  'src\PerParticipantNdiRouter.cpp',
  'src\JitsiSourceMap.h',
  'src\JitsiSourceMap.cpp'
)

foreach ($rel in $files) {
  $path = Join-Path $root $rel
  $backup = Get-ChildItem "$path.bak_v28_*" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($backup) {
    Copy-Item $backup.FullName $path -Force
    Write-Host "[v28 rollback] Restored $rel from $($backup.Name)"
  } else {
    Write-Host "[v28 rollback] No backup found for $rel" -ForegroundColor Yellow
  }
}

Write-Host "[v28 rollback] Building Release..."
cmake --build build --config Release
