$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $PSScriptRoot "JitsiNdiGui.ps1"
$dst = Join-Path $root "JitsiNdiGui.ps1"
$backupDir = Join-Path $root "backups"
if (-not (Test-Path $src)) { throw "Patch file not found: $src" }
if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
if (Test-Path $dst) {
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    Copy-Item -LiteralPath $dst -Destination (Join-Path $backupDir "JitsiNdiGui_before_v50_$stamp.ps1") -Force
}
Copy-Item -LiteralPath $src -Destination $dst -Force
Write-Host "[v50] GUI patch applied. Only JitsiNdiGui.ps1 was replaced."
Write-Host "[v50] Run: powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1"
