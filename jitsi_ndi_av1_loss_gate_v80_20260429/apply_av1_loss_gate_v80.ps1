$ErrorActionPreference = "Stop"

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backup = Join-Path $root ".jnn_patch_backups\av1_loss_gate_v80_$stamp"
New-Item -ItemType Directory -Force -Path $backup | Out-Null

$files = @(
    "src\Av1RtpFrameAssembler.cpp",
    "src\Av1RtpFrameAssembler.h"
)

foreach ($rel in $files) {
    $src = Join-Path $root $rel
    if (!(Test-Path $src)) {
        throw "Missing target file: $rel"
    }
    $dst = Join-Path $backup $rel
    New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
    Copy-Item -Force $src $dst
}

foreach ($rel in $files) {
    $from = Join-Path $PSScriptRoot (Join-Path "files" $rel)
    $to = Join-Path $root $rel
    Copy-Item -Force $from $to
}

$restore = Join-Path $PSScriptRoot "restore_latest_av1_loss_gate_v80_backup.ps1"
@'
$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$backupRoot = Join-Path $root ".jnn_patch_backups"
$latest = Get-ChildItem -Directory $backupRoot -Filter "av1_loss_gate_v80_*" | Sort-Object Name -Descending | Select-Object -First 1
if (!$latest) { throw "No av1_loss_gate_v80 backup found" }
$files = @(
    "src\Av1RtpFrameAssembler.cpp",
    "src\Av1RtpFrameAssembler.h"
)
foreach ($rel in $files) {
    $from = Join-Path $latest.FullName $rel
    $to = Join-Path $root $rel
    if (!(Test-Path $from)) { throw "Missing backup file: $rel" }
    Copy-Item -Force $from $to
}
Write-Host "Restored backup from $($latest.FullName)"
'@ | Set-Content -Encoding ASCII $restore

Write-Host "Applied v80 AV1 loss gate patch. Backup: $backup"
