$ErrorActionPreference = "Stop"
$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir = Split-Path -Parent $patchDir
$backupRoot = Join-Path $repoDir ".jnn_patch_backups"
$latest = Get-ChildItem -Path $backupRoot -Directory -Filter "rejoin_fix_v45_*" | Sort-Object Name -Descending | Select-Object -First 1
if (-not $latest) {
    throw "No v45 backup found."
}
$files = @(
    "src\JitsiSignaling.cpp",
    "src\JitsiSourceMap.cpp",
    "src\PerParticipantNdiRouter.cpp"
)
foreach ($rel in $files) {
    $backup = Join-Path $latest.FullName $rel
    $target = Join-Path $repoDir $rel
    if (Test-Path $backup) {
        Copy-Item -Force $backup $target
    }
}
Write-Host "Restored v45 backup: $($latest.FullName)"
Write-Host "Now rebuild: .\rebuild_with_dav1d_v21.ps1"
