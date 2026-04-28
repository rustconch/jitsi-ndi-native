$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$backupsRoot = Join-Path $root ".jnn_patch_backups"
$latest = Get-ChildItem -Directory $backupsRoot -Filter "gui_minimal_nick_link_v55_*" | Sort-Object Name -Descending | Select-Object -First 1
if (-not $latest) { throw "No v55 backup found." }
$gui = Join-Path $latest.FullName "JitsiNdiGui.ps1"
if (Test-Path $gui) { Copy-Item -Force $gui (Join-Path $root "JitsiNdiGui.ps1") }
$signaling = Join-Path $latest.FullName "src\JitsiSignaling.cpp"
if (Test-Path $signaling) { Copy-Item -Force $signaling (Join-Path $root "src\JitsiSignaling.cpp") }
Write-Host "[v55] Restored backup: $($latest.FullName)"
Write-Host "[v55] Rebuild native exe if you restored src\JitsiSignaling.cpp."
