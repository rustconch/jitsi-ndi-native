$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
Set-Location $projectRoot

if (Test-Path ".\rebuild_with_dav1d_v21.ps1") {
    Write-Host "[v34] Running rebuild_with_dav1d_v21.ps1"
    & ".\rebuild_with_dav1d_v21.ps1"
    exit $LASTEXITCODE
}

if (Test-Path ".\scripts\build.ps1") {
    Write-Host "[v34] Running scripts\build.ps1"
    & ".\scripts\build.ps1"
    exit $LASTEXITCODE
}

throw "No known build script found. Rebuild manually with your existing CMake command."
