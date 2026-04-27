$ErrorActionPreference = 'Stop'

$root = Get-Location
$dst = Join-Path $root 'build\Release'
if (-not (Test-Path $dst)) { throw "Build output not found: $dst" }

$candidateBins = @()
if ($env:VCPKG_ROOT) { $candidateBins += (Join-Path $env:VCPKG_ROOT 'installed\x64-windows\bin') }
$candidateBins += 'D:\MEDIA\Desktop\vcpkg\installed\x64-windows\bin'
$candidateBins += 'D:\vcpkg\installed\x64-windows\bin'
$candidateBins += 'C:\vcpkg\installed\x64-windows\bin'

foreach ($bin in $candidateBins) {
  if ($bin -and (Test-Path $bin)) {
    Write-Host "Copying vcpkg DLLs from $bin"
    Copy-Item (Join-Path $bin '*.dll') $dst -Force -ErrorAction SilentlyContinue
  }
}

$dc = Join-Path $root 'build\_deps\libdatachannel-build\Release\datachannel.dll'
if (Test-Path $dc) { Copy-Item $dc $dst -Force }

$ndiDll = Get-ChildItem 'C:\Program Files', 'C:\Program Files (x86)' -Recurse -Filter 'Processing.NDI.Lib.x64.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($ndiDll) { Copy-Item $ndiDll.FullName $dst -Force }

Get-ChildItem $dst -Filter *.dll | Select-Object Name, Length
Write-Host 'Runtime DLL copy done.'
