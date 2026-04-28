$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
if (!(Test-Path ".\rebuild_with_dav1d_v21.ps1")) {
    throw "rebuild_with_dav1d_v21.ps1 not found in repo root"
}
.\rebuild_with_dav1d_v21.ps1
