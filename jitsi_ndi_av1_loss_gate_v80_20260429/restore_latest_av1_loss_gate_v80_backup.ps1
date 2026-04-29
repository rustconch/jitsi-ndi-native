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
