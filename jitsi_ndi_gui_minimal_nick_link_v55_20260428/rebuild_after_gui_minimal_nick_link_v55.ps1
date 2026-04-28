$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root "rebuild_with_dav1d_v21.ps1"
if (-not (Test-Path $script)) { throw "rebuild_with_dav1d_v21.ps1 not found in project root." }
& $script
exit $LASTEXITCODE
