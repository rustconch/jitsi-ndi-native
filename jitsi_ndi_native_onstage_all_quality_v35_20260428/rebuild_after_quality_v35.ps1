$ErrorActionPreference = "Stop"

$root = (Get-Location).Path
$script = Join-Path $root "rebuild_with_dav1d_v21.ps1"

if (Test-Path $script) {
    & $script
    exit $LASTEXITCODE
}

$script2 = Join-Path $root "rebuild_with_dav1d_v20.ps1"
if (Test-Path $script2) {
    & $script2
    exit $LASTEXITCODE
}

throw "No rebuild_with_dav1d_v21.ps1 or rebuild_with_dav1d_v20.ps1 found in repository root."
