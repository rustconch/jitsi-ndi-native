$ErrorActionPreference = "Stop"

$patchRoot = $PSScriptRoot
$repoRoot = Split-Path -Parent $patchRoot
$srcRoot = Join-Path $repoRoot "src"
$backupRoot = Join-Path $repoRoot ".jnn_patch_backups\quality_v40_$(Get-Date -Format yyyyMMdd_HHmmss)"
$backupSrc = Join-Path $backupRoot "src"

$files = @(
    "NativeWebRTCAnswerer.cpp",
    "NDISender.cpp"
)

if (-not (Test-Path $srcRoot)) {
    throw "Repo src folder not found: $srcRoot"
}

New-Item -ItemType Directory -Force -Path $backupSrc | Out-Null

foreach ($file in $files) {
    $sourceFile = Join-Path $srcRoot $file
    $patchFile = Join-Path (Join-Path $patchRoot "src") $file

    if (-not (Test-Path $patchFile)) {
        throw "Patch file missing: $patchFile"
    }

    if (Test-Path $sourceFile) {
        Copy-Item -Force $sourceFile (Join-Path $backupSrc $file)
    }

    Copy-Item -Force $patchFile $sourceFile
}

Write-Host "Applied quality v40 patch. Backup: $backupRoot"
Write-Host "Now rebuild the native exe, for example: .\rebuild_with_dav1d_v21.ps1"
