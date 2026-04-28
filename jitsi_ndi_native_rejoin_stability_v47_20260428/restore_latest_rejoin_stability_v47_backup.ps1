$ErrorActionPreference = "Stop"

$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $patchDir "..")
$srcDir = Join-Path $repoRoot "src"
$backupRoot = Join-Path $repoRoot "backups\v47_rejoin_stability"

if (-not (Test-Path $backupRoot)) {
    throw "backup directory not found: $backupRoot"
}

$latest = Get-ChildItem -Directory $backupRoot | Sort-Object Name -Descending | Select-Object -First 1
if ($null -eq $latest) {
    throw "no v47 backup found"
}

$files = @(
    "JitsiSourceMap.cpp",
    "PerParticipantNdiRouter.cpp",
    "NativeWebRTCAnswerer.cpp"
)

foreach ($file in $files) {
    $backup = Join-Path $latest.FullName $file
    $dst = Join-Path $srcDir $file
    if (Test-Path $backup) {
        Copy-Item -Force $backup $dst
    }
}

Write-Host "Restored latest v47 backup: $($latest.FullName)"
Write-Host "Now rebuild: .\rebuild_with_dav1d_v21.ps1"
