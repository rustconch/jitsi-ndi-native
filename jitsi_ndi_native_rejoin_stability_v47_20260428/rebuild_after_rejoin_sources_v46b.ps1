$ErrorActionPreference = "Stop"

$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $patchDir "..")
Set-Location $repoRoot

if (Test-Path ".\rebuild_with_dav1d_v21.ps1") {
    & ".\rebuild_with_dav1d_v21.ps1"
} elseif (Test-Path ".\scripts\build-release.ps1") {
    & ".\scripts\build-release.ps1"
} else {
    throw "No known rebuild script found. Run your normal CMake rebuild manually."
}
