$ErrorActionPreference = 'Stop'
$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $patchDir
$latest = Get-ChildItem -LiteralPath $repoRoot -Filter 'JitsiNdiGui.backup_v58_*.ps1' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $latest) { throw 'No v58 backup found.' }
Copy-Item -LiteralPath $latest.FullName -Destination (Join-Path $repoRoot 'JitsiNdiGui.ps1') -Force
Write-Host "[v58] Restored: $($latest.Name)"
