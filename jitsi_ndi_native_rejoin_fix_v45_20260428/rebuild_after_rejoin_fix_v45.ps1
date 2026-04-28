$ErrorActionPreference = "Stop"
$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir = Split-Path -Parent $patchDir
Set-Location $repoDir
if (Test-Path ".\rebuild_with_dav1d_v21.ps1") {
    & ".\rebuild_with_dav1d_v21.ps1"
} elseif (Test-Path ".\build_with_dav1d.ps1") {
    & ".\build_with_dav1d.ps1"
} else {
    throw "No known rebuild script found. Run your normal CMake build manually."
}
