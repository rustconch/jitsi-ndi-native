$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backup = Join-Path $root (".jnn_patch_backups\nick_display_v59_" + $stamp)
New-Item -ItemType Directory -Path $backup -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $backup "src") -Force | Out-Null

$guiDst = Join-Path $root "JitsiNdiGui.ps1"
if (Test-Path $guiDst) { Copy-Item -Force $guiDst (Join-Path $backup "JitsiNdiGui.ps1") }
Copy-Item -Force (Join-Path $PSScriptRoot "JitsiNdiGui.ps1") $guiDst

$files = @("JitsiSignaling.cpp", "main.cpp")
foreach ($name in $files) {
    $dst = Join-Path $root ("src\" + $name)
    if (Test-Path $dst) { Copy-Item -Force $dst (Join-Path $backup ("src\" + $name)) }
    Copy-Item -Force (Join-Path $PSScriptRoot ("src\" + $name)) $dst
}

Write-Host "[v59] Installed nickname display patch."
Write-Host "[v59] Backup: $backup"
Write-Host "[v59] Rebuild native exe: .\rebuild_with_dav1d_v21.ps1"
