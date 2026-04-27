$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path
$native = Join-Path $root 'src\NativeWebRTCAnswerer.cpp'
if (!(Test-Path $native)) {
  Write-Host "[v26 rollback][ERROR] src\NativeWebRTCAnswerer.cpp not found. Run from repository root." -ForegroundColor Red
  exit 1
}
$dir = Split-Path -Parent $native
$leaf = Split-Path -Leaf $native
$bak = Get-ChildItem -Path $dir -Filter "$leaf.bak_v26_*" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (!$bak) {
  Write-Host "[v26 rollback][ERROR] No .bak_v26_* backup found for NativeWebRTCAnswerer.cpp" -ForegroundColor Red
  exit 1
}
Copy-Item $bak.FullName $native -Force
Write-Host "[v26 rollback] Restored $($bak.Name) -> src\NativeWebRTCAnswerer.cpp" -ForegroundColor Green
Write-Host "[v26 rollback] Rebuild if needed: cmake --build build --config Release"
