# GUI-only safe patch for jitsi-ndi-native.
# Run from repository root: D:\MEDIA\Desktop\jitsi-ndi-native

$ErrorActionPreference = "Stop"

$repo = Get-Location
$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$src = Join-Path $patchDir "JitsiNdiGui.ps1"
$dst = Join-Path $repo "JitsiNdiGui.ps1"

if (-not (Test-Path $src)) {
    throw "Patch file not found: $src"
}

$backupDir = Join-Path $repo (".jnn_gui_backups\gui_v32_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

if (Test-Path $dst) {
    Copy-Item -Force $dst (Join-Path $backupDir "JitsiNdiGui.ps1.bak")
}

Copy-Item -Force $src $dst

Write-Host "GUI-only patch applied." -ForegroundColor Green
Write-Host "Native/WebRTC/NDI files were not changed." -ForegroundColor Yellow
Write-Host "Backup: $backupDir"
Write-Host "Run: powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1"
