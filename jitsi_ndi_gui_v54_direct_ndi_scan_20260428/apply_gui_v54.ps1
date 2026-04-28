# apply_gui_v54.ps1
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $PSScriptRoot "JitsiNdiGui.ps1"
$dst = Join-Path $root "JitsiNdiGui.ps1"

if (-not (Test-Path -LiteralPath $src)) {
    throw "Patch file not found: $src"
}

$backupDir = Join-Path $root "gui_backups"
if (-not (Test-Path -LiteralPath $backupDir)) {
    New-Item -ItemType Directory -Path $backupDir | Out-Null
}

if (Test-Path -LiteralPath $dst) {
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    Copy-Item -LiteralPath $dst -Destination (Join-Path $backupDir "JitsiNdiGui_before_v54_$stamp.ps1") -Force
}

Copy-Item -LiteralPath $src -Destination $dst -Force
Write-Host "[v54] GUI patched: $dst"
Write-Host "[v54] Native/WebRTC/NDI files were not changed."
Write-Host "[v54] Run: powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1"
