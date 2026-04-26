$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$ndi = "C:\Program Files\NDI\NDI 6 SDK"
if (-not (Test-Path $ndi)) {
    $ndi = "C:\Program Files\NDI\NDI 5 SDK"
}

cmake -S . -B build-ndi -G "Visual Studio 17 2022" -A x64 -DJNN_NDI_SDK_DIR="$ndi"
cmake --build build-ndi --config Release
