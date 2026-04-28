$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $PSScriptRoot 'JitsiNdiGui.ps1'
$dst = Join-Path $root 'JitsiNdiGui.ps1'
$backupDir = Join-Path $root 'backups_gui_v63'
if (-not (Test-Path $src)) { throw "Patch file not found: $src" }
if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Force -Path $backupDir | Out-Null }
if (Test-Path $dst) {
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    Copy-Item -Force $dst (Join-Path $backupDir "JitsiNdiGui_before_v63_$stamp.ps1")
}
Copy-Item -Force $src $dst
Write-Host '[v63] Applied GUI speaker link generator patch. Native/WebRTC/NDI not changed.'
Write-Host '[v63] Run: powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1'
