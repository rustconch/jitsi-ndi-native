$ErrorActionPreference = 'Stop'

$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $patchDir
$src = Join-Path $patchDir 'JitsiNdiGui.ps1'
$dst = Join-Path $repoRoot 'JitsiNdiGui.ps1'
$backupDir = Join-Path $repoRoot 'gui_backups'

if (-not (Test-Path $src)) { throw "Patch file not found: $src" }
if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }

if (Test-Path $dst) {
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backup = Join-Path $backupDir ("JitsiNdiGui.before_v51.$stamp.ps1")
    Copy-Item -LiteralPath $dst -Destination $backup -Force
    Write-Host "Backup created: $backup"
}

Copy-Item -LiteralPath $src -Destination $dst -Force
Write-Host "GUI v51 applied: $dst"
Write-Host "Run: powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1"
