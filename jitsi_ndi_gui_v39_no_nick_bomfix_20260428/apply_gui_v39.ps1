# Apply GUI v39 patch. ASCII-only script.
$ErrorActionPreference = "Stop"
$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $patchDir
$src = Join-Path $patchDir "JitsiNdiGui.ps1"
$dst = Join-Path $repoRoot "JitsiNdiGui.ps1"
if (-not (Test-Path $src)) { throw "Patch file not found: $src" }
$backupDir = Join-Path $repoRoot "gui_backups"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
if (Test-Path $dst) {
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    Copy-Item -LiteralPath $dst -Destination (Join-Path $backupDir ("JitsiNdiGui_before_v39_" + $stamp + ".ps1")) -Force
}
Copy-Item -LiteralPath $src -Destination $dst -Force
Write-Host "GUI v39 applied. Only JitsiNdiGui.ps1 was replaced."
Write-Host "Run: powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1"
