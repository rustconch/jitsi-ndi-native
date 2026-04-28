$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$backupsRoot = Join-Path $root ".jnn_patch_backups"
$latest = Get-ChildItem -Directory $backupsRoot -Filter "nick_display_v59_*" | Sort-Object Name -Descending | Select-Object -First 1
if (-not $latest) { throw "No v59 backup found." }

$gui = Join-Path $latest.FullName "JitsiNdiGui.ps1"
if (Test-Path $gui) { Copy-Item -Force $gui (Join-Path $root "JitsiNdiGui.ps1") }

$files = @("JitsiSignaling.cpp", "main.cpp")
foreach ($name in $files) {
    $src = Join-Path $latest.FullName ("src\" + $name)
    if (Test-Path $src) { Copy-Item -Force $src (Join-Path $root ("src\" + $name)) }
}

Write-Host "[v59] Restored backup: $($latest.FullName)"
Write-Host "[v59] Rebuild native exe if source files were restored."
