$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $root
if (Test-Path ".\rebuild_with_dav1d_v21.ps1") {
    & ".\rebuild_with_dav1d_v21.ps1"
} else {
    throw "rebuild_with_dav1d_v21.ps1 not found in repo root"
}
