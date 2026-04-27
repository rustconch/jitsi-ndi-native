$ErrorActionPreference = "Stop"
$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $patchDir
$backupRoot = Join-Path $repoRoot ".jnn_patch_backups"
if (-not (Test-Path $backupRoot)) { throw ("Backup root not found: " + $backupRoot) }
$backup = Get-ChildItem -Path $backupRoot -Directory -Filter "gui_restore_v37_*" | Sort-Object Name -Descending | Select-Object -First 1
if (-not $backup) { throw "No gui_restore_v37 backup found." }
$guiBackup = Join-Path $backup.FullName "JitsiNdiGui.ps1"
if (Test-Path $guiBackup) { Copy-Item -Force $guiBackup (Join-Path $repoRoot "JitsiNdiGui.ps1") }
$settingsBackup = Join-Path $backup.FullName "JitsiNdiGui.settings.json"
if (Test-Path $settingsBackup) { Copy-Item -Force $settingsBackup (Join-Path $repoRoot "JitsiNdiGui.settings.json") }
Write-Host ("Restored from: " + $backup.FullName)
