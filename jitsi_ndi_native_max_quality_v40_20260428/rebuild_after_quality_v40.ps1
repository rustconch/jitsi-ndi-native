$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

if (Test-Path ".\rebuild_with_dav1d_v21.ps1") {
    & ".\rebuild_with_dav1d_v21.ps1"
    exit $LASTEXITCODE
}

if (Test-Path ".\build-ndi") {
    cmake --build .\build-ndi --config Release
    exit $LASTEXITCODE
}

throw "No known rebuild script/build folder found. Rebuild manually."
