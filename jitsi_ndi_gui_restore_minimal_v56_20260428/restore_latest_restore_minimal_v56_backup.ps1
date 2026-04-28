$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$backupsRoot = Join-Path $root ".jnn_patch_backups"
$latest = Get-ChildItem -Directory $backupsRoot -Filter "restore_minimal_v56_*" | Sort-Object Name -Descending | Select-Object -First 1
if (-not $latest) { throw "No v56 backup found." }
$gui = Join-Path $latest.FullName "JitsiNdiGui.ps1"
if (Test-Path $gui) { Copy-Item -Force $gui (Join-Path $root "JitsiNdiGui.ps1") }
$signaling = Join-Path $latest.FullName "src\JitsiSignaling.cpp"
if (Test-Path $signaling) { Copy-Item -Force $signaling (Join-Path $root "src\JitsiSignaling.cpp") }
Write-Host "[v56] Restored backup: $($latest.FullName)"
Write-Host "[v56] Rebuild native exe if src\JitsiSignaling.cpp was restored."
