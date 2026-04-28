$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$backupsRoot = Join-Path $root ".jnn_patch_backups"
$latest = Get-ChildItem -Directory $backupsRoot -Filter "restore_minimal_v57_*" | Sort-Object Name -Descending | Select-Object -First 1
if (-not $latest) { throw "No v57 backup found." }
$gui = Join-Path $latest.FullName "JitsiNdiGui.ps1"
if (Test-Path $gui) { Copy-Item -Force $gui (Join-Path $root "JitsiNdiGui.ps1") }
Write-Host "[v57] Restored GUI backup: $($latest.FullName)"
