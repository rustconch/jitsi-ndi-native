$ErrorActionPreference = "Stop"

$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir = Split-Path -Parent $patchDir
$srcDir = Join-Path $patchDir "src"
$backupRoot = Join-Path $repoDir ".jnn_patch_backups"
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupDir = Join-Path $backupRoot ("rejoin_fix_v45_" + $stamp)

$files = @(
    "src\JitsiSignaling.cpp",
    "src\JitsiSourceMap.cpp",
    "src\PerParticipantNdiRouter.cpp"
)

foreach ($rel in $files) {
    $patchFile = Join-Path $patchDir $rel
    if (-not (Test-Path $patchFile)) {
        throw "Patch file missing: $patchFile"
    }
}

New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

foreach ($rel in $files) {
    $target = Join-Path $repoDir $rel
    $backup = Join-Path $backupDir $rel
    $backupParent = Split-Path -Parent $backup
    New-Item -ItemType Directory -Force -Path $backupParent | Out-Null
    if (Test-Path $target) {
        Copy-Item -Force $target $backup
    }
}

foreach ($rel in $files) {
    $target = Join-Path $repoDir $rel
    $patchFile = Join-Path $patchDir $rel
    Copy-Item -Force $patchFile $target
}

Write-Host "Applied v45 rejoin fix. Backup: $backupDir"
Write-Host "Now rebuild: .\rebuild_with_dav1d_v21.ps1"
