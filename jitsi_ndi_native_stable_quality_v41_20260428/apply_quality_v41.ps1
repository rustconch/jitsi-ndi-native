$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$patchRoot = $PSScriptRoot
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backup = Join-Path $root ".jnn_patch_backups\quality_v41_$stamp"
New-Item -ItemType Directory -Force -Path (Join-Path $backup "src") | Out-Null

$files = @(
    "src\NativeWebRTCAnswerer.cpp",
    "src\NDISender.cpp"
)

foreach ($rel in $files) {
    $dst = Join-Path $root $rel
    $src = Join-Path $patchRoot $rel
    if (!(Test-Path $src)) { throw "Patch file missing: $src" }
    if (Test-Path $dst) {
        Copy-Item -Force $dst (Join-Path $backup $rel)
    }
    Copy-Item -Force $src $dst
}

Write-Host "Applied quality v41 stable patch. Backup: $backup"
Write-Host "Now rebuild: .\rebuild_with_dav1d_v21.ps1"
