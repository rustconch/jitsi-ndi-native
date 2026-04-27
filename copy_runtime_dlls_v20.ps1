$ErrorActionPreference = 'Stop'
function Info($m) { Write-Host "[v20-copy] $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "[v20-copy][WARN] $m" -ForegroundColor Yellow }

$ProjectRoot = (Get-Location).Path
$dst = Join-Path $ProjectRoot 'build\Release'
if (-not (Test-Path $dst)) { throw "Release directory not found: $dst" }

$datachannel = Join-Path $ProjectRoot 'build\_deps\libdatachannel-build\Release\datachannel.dll'
if (Test-Path $datachannel) {
  Copy-Item $datachannel $dst -Force
  Info "Copied datachannel.dll"
} else {
  Warn "datachannel.dll not found at expected path: $datachannel"
}

function Find-VcpkgRoot {
  $candidates = @()
  if ($env:VCPKG_ROOT) { $candidates += $env:VCPKG_ROOT }
  $candidates += @('D:\MEDIA\Desktop\vcpkg','D:\vcpkg','C:\vcpkg')
  foreach ($c in $candidates) {
    if ($c -and (Test-Path (Join-Path $c 'vcpkg.exe'))) { return (Resolve-Path $c).Path }
  }
  return $null
}

$vcpkgRoot = Find-VcpkgRoot
if ($vcpkgRoot) {
  $bin = Join-Path $vcpkgRoot 'installed\x64-windows\bin'
  if (Test-Path $bin) {
    Info "Copying DLLs from $bin"
    Copy-Item (Join-Path $bin '*.dll') $dst -Force -ErrorAction SilentlyContinue
  }
} else {
  Warn "vcpkg not found, cannot copy FFmpeg/OpenSSL/dav1d DLLs"
}

$ndiDll = Get-ChildItem 'C:\Program Files', 'C:\Program Files (x86)' -Recurse -Filter 'Processing.NDI.Lib.x64.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($ndiDll) {
  Copy-Item $ndiDll.FullName $dst -Force
  Info "Copied NDI runtime: $($ndiDll.FullName)"
} else {
  Warn "Processing.NDI.Lib.x64.dll not found"
}

$vsRoots = @(
  "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022",
  "${env:ProgramFiles}\Microsoft Visual Studio\2022"
) | Where-Object { $_ -and (Test-Path $_) }
$crt = $null
if ($vsRoots.Count -gt 0) {
  $crt = Get-ChildItem $vsRoots -Recurse -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\VC\\Redist\\MSVC\\.*\\x64\\Microsoft\.VC143\.CRT$' } |
    Sort-Object FullName -Descending |
    Select-Object -First 1
}
if ($crt) {
  Copy-Item (Join-Path $crt.FullName '*.dll') $dst -Force
  Info "Copied MSVC runtime from $($crt.FullName)"
}

Info "DLLs in Release:"
Get-ChildItem $dst -Filter *.dll | Select-Object Name, Length | Format-Table -AutoSize
