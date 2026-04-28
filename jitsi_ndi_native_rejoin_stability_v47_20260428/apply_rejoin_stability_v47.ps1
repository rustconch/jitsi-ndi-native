$ErrorActionPreference = "Stop"

$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $patchDir "..")
$srcDir = Join-Path $repoRoot "src"
$backupRoot = Join-Path $repoRoot "backups\v47_rejoin_stability"
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupDir = Join-Path $backupRoot $stamp

if (-not (Test-Path $srcDir)) {
    throw "src directory not found: $srcDir"
}

New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

$files = @(
    "JitsiSourceMap.cpp",
    "PerParticipantNdiRouter.cpp",
    "NativeWebRTCAnswerer.cpp"
)

foreach ($file in $files) {
    $src = Join-Path $patchDir ("src\" + $file)
    $dst = Join-Path $srcDir $file
    if (-not (Test-Path $src)) {
        throw "patch file not found: $src"
    }
    if (Test-Path $dst) {
        Copy-Item -Force $dst (Join-Path $backupDir $file)
    }
    Copy-Item -Force $src $dst
}

Write-Host "v47 rejoin stability patch applied. Backup: $backupDir"
Write-Host "Now rebuild: .\rebuild_with_dav1d_v21.ps1"
