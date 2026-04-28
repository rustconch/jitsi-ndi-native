$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $PSScriptRoot "JitsiNdiGui.ps1"
$dst = Join-Path $root "JitsiNdiGui.ps1"
$backupDir = Join-Path $root "gui_backups"
if (-not (Test-Path $src)) { throw "Patch file not found: $src" }
if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
if (Test-Path $dst) {
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    Copy-Item -LiteralPath $dst -Destination (Join-Path $backupDir ("JitsiNdiGui_before_v53_" + $stamp + ".ps1")) -Force
}
Copy-Item -LiteralPath $src -Destination $dst -Force
Write-Host "GUI v53 applied. Run: powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1"
