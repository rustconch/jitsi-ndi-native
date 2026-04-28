$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $PSScriptRoot 'JitsiNdiGui.ps1'
$dst = Join-Path $root 'JitsiNdiGui.ps1'
$backupDir = Join-Path $root 'backups_gui'
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
if (-not (Test-Path $src)) { throw "Patch file not found: $src" }
if (Test-Path $dst) {
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    Copy-Item -Force $dst (Join-Path $backupDir "JitsiNdiGui_before_v64_$stamp.ps1")
}
Copy-Item -Force $src $dst
Write-Host "[v64] GUI visual speaker quality patch applied. Native code was not changed."
