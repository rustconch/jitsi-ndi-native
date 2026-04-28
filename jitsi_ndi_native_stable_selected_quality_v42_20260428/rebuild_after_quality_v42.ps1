$ErrorActionPreference = "Stop"
$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $patchDir
Set-Location $repoRoot
if (Test-Path ".\rebuild_with_dav1d_v21.ps1") {
    & ".\rebuild_with_dav1d_v21.ps1"
} else {
    throw "rebuild_with_dav1d_v21.ps1 not found in repo root"
}
