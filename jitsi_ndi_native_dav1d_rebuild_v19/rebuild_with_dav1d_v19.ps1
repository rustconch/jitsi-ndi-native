$ErrorActionPreference = 'Stop'

function Info($m) { Write-Host "[v19] $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "[v19][WARN] $m" -ForegroundColor Yellow }
function Die($m) { Write-Host "[v19][ERROR] $m" -ForegroundColor Red; exit 1 }

$ProjectRoot = (Get-Location).Path
if (-not (Test-Path (Join-Path $ProjectRoot 'CMakeLists.txt'))) {
  Die "Run this from the repository root, for example: D:\MEDIA\Desktop\jitsi-ndi-native"
}

function Find-VcpkgRoot {
  $candidates = @()
  if ($env:VCPKG_ROOT) { $candidates += $env:VCPKG_ROOT }
  $candidates += @(
    'D:\MEDIA\Desktop\vcpkg',
    'D:\vcpkg',
    'C:\vcpkg'
  )
  foreach ($c in $candidates) {
    if ($c -and (Test-Path (Join-Path $c 'vcpkg.exe')) -and (Test-Path (Join-Path $c 'scripts\buildsystems\vcpkg.cmake'))) {
      return (Resolve-Path $c).Path
    }
  }
  return $null
}

$vcpkgRoot = Find-VcpkgRoot
if (-not $vcpkgRoot) {
  Die "vcpkg not found. Set VCPKG_ROOT or place it at D:\MEDIA\Desktop\vcpkg, D:\vcpkg, or C:\vcpkg."
}
$vcpkgExe = Join-Path $vcpkgRoot 'vcpkg.exe'
$toolchain = Join-Path $vcpkgRoot 'scripts\buildsystems\vcpkg.cmake'
$triplet = 'x64-windows'

Info "Using vcpkg: $vcpkgRoot"
Info "Installing FFmpeg with libdav1d support. This is the important step."

# Important: plain ffmpeg:x64-windows is not enough. It can decode Opus/VP8 but not AV1 via dav1d.
& $vcpkgExe install "dav1d:$triplet" "ffmpeg[avcodec,avformat,dav1d,opus,swresample,swscale,vpx]:$triplet" "openssl:$triplet"
if ($LASTEXITCODE -ne 0) { Die "vcpkg install failed" }

$vcpkgBin = Join-Path $vcpkgRoot "installed\$triplet\bin"
$dav1dDll = Get-ChildItem $vcpkgBin -Filter '*dav1d*.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $dav1dDll) {
  Die "dav1d DLL was not found in $vcpkgBin after install. FFmpeg was not rebuilt with dav1d."
}
Info "Found dav1d runtime: $($dav1dDll.Name)"

# Make CMake re-detect and relink against the updated vcpkg FFmpeg. Incremental build is not enough here.
$buildDir = Join-Path $ProjectRoot 'build'
if (Test-Path $buildDir) {
  Info "Removing old build directory so CMake cannot keep stale FFmpeg link info: $buildDir"
  Remove-Item -Recurse -Force $buildDir
}

$cmakeArgs = @(
  '-S', '.',
  '-B', 'build',
  '-G', 'Visual Studio 17 2022',
  '-A', 'x64',
  "-DCMAKE_TOOLCHAIN_FILE=$toolchain",
  "-DVCPKG_TARGET_TRIPLET=$triplet"
)

$ndiSdkCandidates = @(
  'C:\Program Files\NDI\NDI 6 SDK',
  'C:\Program Files\NDI\NDI 5 SDK',
  'C:\Program Files\NDI\NDI SDK',
  'C:\Program Files (x86)\NDI\NDI 6 SDK'
) | Where-Object { Test-Path $_ }
if ($ndiSdkCandidates.Count -gt 0) {
  $cmakeArgs += "-DJNN_NDI_SDK_DIR=$($ndiSdkCandidates[0])"
  Info "Using NDI SDK: $($ndiSdkCandidates[0])"
} else {
  Warn "NDI SDK dir was not found in standard paths. If configure fails, add -DJNN_NDI_SDK_DIR manually."
}

Info "Configuring clean build"
& cmake @cmakeArgs
if ($LASTEXITCODE -ne 0) { Die "cmake configure failed" }

Info "Building Release"
& cmake --build build --config Release
if ($LASTEXITCODE -ne 0) { Die "cmake build failed" }

Info "Copying runtime DLLs"
powershell -ExecutionPolicy Bypass -File .\copy_runtime_dlls_v19.ps1
if ($LASTEXITCODE -ne 0) { Die "runtime DLL copy failed" }

Info "Checking that Release avcodec depends on dav1d"
powershell -ExecutionPolicy Bypass -File .\check_dav1d_runtime_v19.ps1
if ($LASTEXITCODE -ne 0) { Die "dav1d runtime check failed" }

Info "Done. Run: .\build\Release\jitsi-ndi-native.exe --room 6767676766767penxyi"
