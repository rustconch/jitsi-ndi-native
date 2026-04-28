$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
.\rebuild_with_dav1d_v21.ps1
