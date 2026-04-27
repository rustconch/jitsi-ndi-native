$ErrorActionPreference = 'Stop'
$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $patchDir
$backupDir = Join-Path $repoRoot '.jnn_patch_backups'
$dst = Join-Path $repoRoot 'JitsiNdiGui.ps1'

$latest = Get-ChildItem -Path $backupDir -Filter 'JitsiNdiGui_before_gui_v33_*.ps1' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if (-not $latest) {
    throw "Backup для v33 не найден в $backupDir"
}

Copy-Item -LiteralPath $latest.FullName -Destination $dst -Force
Write-Host "Восстановлен GUI из backup: $($latest.FullName)"
