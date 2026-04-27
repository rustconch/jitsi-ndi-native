# Applies JitsiNdiGui.ps1 v30 over the current GUI launcher.
# Run from repository root after extracting the archive:
# .\jitsi_ndi_gui_v30_nick_log_quality_fix_20260428\apply_gui_v30.ps1

$ErrorActionPreference = "Stop"
$patchDir = $PSScriptRoot
$repo = Split-Path $patchDir -Parent
$src = Join-Path $patchDir "JitsiNdiGui.ps1"
$dest = Join-Path $repo "JitsiNdiGui.ps1"
$backupDir = Join-Path $repo (".gui_patch_backups\gui_v30_" + (Get-Date -Format "yyyyMMdd_HHmmss"))

if (-not (Test-Path $src)) {
    throw "Patch file not found: $src"
}

New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

if (Test-Path $dest) {
    Copy-Item -LiteralPath $dest -Destination (Join-Path $backupDir "JitsiNdiGui.ps1.bak") -Force
}

Copy-Item -LiteralPath $src -Destination $dest -Force

Write-Host "GUI v30 applied." -ForegroundColor Green
Write-Host "Backup folder: $backupDir" -ForegroundColor DarkGray
Write-Host "Run:" -ForegroundColor Cyan
Write-Host "powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1" -ForegroundColor Cyan
