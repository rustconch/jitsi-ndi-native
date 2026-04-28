$ErrorActionPreference = 'Stop'

$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $patchDir
$backupDir = Join-Path $repoRoot 'gui_backups'
$dst = Join-Path $repoRoot 'JitsiNdiGui.ps1'

if (-not (Test-Path $backupDir)) { throw "Backup directory not found: $backupDir" }
$latest = Get-ChildItem -LiteralPath $backupDir -Filter 'JitsiNdiGui.before_v51.*.ps1' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $latest) { throw "No v51 GUI backup found." }

Copy-Item -LiteralPath $latest.FullName -Destination $dst -Force
Write-Host "Restored: $($latest.FullName) -> $dst"
