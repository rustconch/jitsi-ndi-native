$ErrorActionPreference = 'Stop'

$candidates = @()
if ($env:VCPKG_ROOT) { $candidates += (Join-Path $env:VCPKG_ROOT 'vcpkg.exe') }
$candidates += 'D:\MEDIA\Desktop\vcpkg\vcpkg.exe'
$candidates += 'D:\vcpkg\vcpkg.exe'
$candidates += 'C:\vcpkg\vcpkg.exe'

$vcpkg = $null
foreach ($c in $candidates) {
  if ($c -and (Test-Path $c)) { $vcpkg = $c; break }
}
if (-not $vcpkg) { throw 'vcpkg.exe not found. Set VCPKG_ROOT or edit this script.' }

Write-Host "Using vcpkg: $vcpkg"
& $vcpkg install "ffmpeg[avcodec,swresample,swscale,dav1d]:x64-windows" "openssl:x64-windows" --recurse
if ($LASTEXITCODE -ne 0) { throw "vcpkg install failed with exit code $LASTEXITCODE" }

Write-Host 'Done. Now rerun CMake configure if needed, then build:'
Write-Host 'cmake --build build --config Release'
