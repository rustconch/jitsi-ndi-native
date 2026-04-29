$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptDir "..")
$srcDir = Join-Path $repoRoot "src"

$latest = Get-ChildItem -Path $repoRoot -Directory -Filter "backup_v93_camera1080_local_smooth_*" |
    Sort-Object Name -Descending |
    Select-Object -First 1

if ($null -eq $latest) {
    throw "No backup_v93_camera1080_local_smooth_* directory found."
}

Get-ChildItem -Path $latest.FullName -File | ForEach-Object {
    Copy-Item -Force $_.FullName (Join-Path $srcDir $_.Name)
}

Write-Host "Restored from:" $latest.FullName
Write-Host "Now rebuild with: .\rebuild_with_dav1d_v21.ps1"
