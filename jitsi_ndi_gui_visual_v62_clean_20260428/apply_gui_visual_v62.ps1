$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $PSScriptRoot 'JitsiNdiGui.ps1'
$dst = Join-Path $root 'JitsiNdiGui.ps1'
$backupDir = Join-Path $root 'backups'
if (-not (Test-Path $src)) { throw "Patch file not found: $src" }
if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Force -Path $backupDir | Out-Null }
if (Test-Path $dst) {
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    Copy-Item -Force $dst (Join-Path $backupDir "JitsiNdiGui_before_v62_$stamp.ps1")
}
Copy-Item -Force $src $dst
Write-Host '[v62] GUI visual cleanup applied. Native code was not changed.'
Write-Host '[v62] Removed Exe and Copy command buttons; removed extra explanatory UI/log text.'
