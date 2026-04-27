$ErrorActionPreference = 'Stop'

$root = (Get-Location).Path
$router = Join-Path $root 'src\PerParticipantNdiRouter.cpp'
$backup = Get-ChildItem "$router.bak_v27_*" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (!$backup) {
  Write-Host "[v27 rollback][ERROR] No v27 backup found for $router" -ForegroundColor Red
  exit 1
}
Copy-Item $backup.FullName $router -Force
Write-Host "[v27 rollback] Restored $($backup.FullName) -> $router"
cmake --build build --config Release
