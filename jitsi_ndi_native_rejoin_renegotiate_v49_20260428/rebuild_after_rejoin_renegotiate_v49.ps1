$ErrorActionPreference = "Stop"
$root = (Get-Location).Path
$script = Join-Path $root "rebuild_with_dav1d_v21.ps1"
if (-not (Test-Path $script)) { throw "Missing rebuild script: $script" }
& $script
