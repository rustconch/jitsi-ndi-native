# Restore latest GUI backup made by v39. ASCII-only script.
$ErrorActionPreference = "Stop"
$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $patchDir
$backupDir = Join-Path $repoRoot "gui_backups"
$dst = Join-Path $repoRoot "JitsiNdiGui.ps1"
if (-not (Test-Path $backupDir)) { throw "Backup directory not found: $backupDir" }
$backup = Get-ChildItem -LiteralPath $backupDir -Filter "JitsiNdiGui_before_v39_*.ps1" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $backup) { throw "No v39 GUI backup found." }
Copy-Item -LiteralPath $backup.FullName -Destination $dst -Force
Write-Host "Restored: $($backup.FullName)"
