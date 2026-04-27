$ErrorActionPreference = 'Stop'

$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $patchDir
$src = Join-Path $patchDir 'JitsiNdiGui.ps1'
$dst = Join-Path $repoRoot 'JitsiNdiGui.ps1'
$backupDir = Join-Path $repoRoot '.jnn_patch_backups'
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backup = Join-Path $backupDir ("JitsiNdiGui_before_gui_v33_{0}.ps1" -f $stamp)

if (-not (Test-Path $src)) {
    throw "Не найден файл патча: $src"
}

if (-not (Test-Path $backupDir)) {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
}

if (Test-Path $dst) {
    Copy-Item -LiteralPath $dst -Destination $backup -Force
    Write-Host "Backup GUI сохранён: $backup"
}

Copy-Item -LiteralPath $src -Destination $dst -Force
Write-Host "Готово: заменён только JitsiNdiGui.ps1"
Write-Host "Native/C++/WebRTC/NDI/CMake/build не изменялись."
Write-Host "Запуск: powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1"
