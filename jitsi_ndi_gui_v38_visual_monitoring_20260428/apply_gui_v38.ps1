$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $PSScriptRoot "JitsiNdiGui.ps1"
$dst = Join-Path $root "JitsiNdiGui.ps1"
if (-not (Test-Path $src)) { throw "Patch file not found: $src" }
if (-not (Test-Path $root)) { throw "Repository root not found: $root" }
$backupDir = Join-Path $root "gui_backups"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
if (Test-Path $dst) {
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    Copy-Item -LiteralPath $dst -Destination (Join-Path $backupDir ("JitsiNdiGui_before_v38_$stamp.ps1")) -Force
}
Copy-Item -LiteralPath $src -Destination $dst -Force
Write-Host "GUI v38 applied. Only JitsiNdiGui.ps1 was replaced."
Write-Host "Run: powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1"
