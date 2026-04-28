$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$backupRoot = Join-Path $root ".jnn_patch_backups"
if (!(Test-Path $backupRoot)) { throw "Backup directory not found" }
$latest = Get-ChildItem $backupRoot -Directory -Filter "quality_v41_*" | Sort-Object Name -Descending | Select-Object -First 1
if ($null -eq $latest) { throw "No quality_v41 backup found" }
$files = @(
    "src\NativeWebRTCAnswerer.cpp",
    "src\NDISender.cpp"
)
foreach ($rel in $files) {
    $src = Join-Path $latest.FullName $rel
    $dst = Join-Path $root $rel
    if (Test-Path $src) {
        Copy-Item -Force $src $dst
        Write-Host "Restored $rel"
    }
}
Write-Host "Restored latest quality v41 backup: $($latest.FullName)"
Write-Host "Now rebuild: .\rebuild_with_dav1d_v21.ps1"
