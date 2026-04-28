$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backup = Join-Path $root (".jnn_patch_backups\restore_minimal_v57_" + $stamp)
New-Item -ItemType Directory -Path $backup -Force | Out-Null

$guiSrc = Join-Path $PSScriptRoot "JitsiNdiGui.ps1"
$guiDst = Join-Path $root "JitsiNdiGui.ps1"
if (-not (Test-Path $guiSrc)) { throw "Patch file not found: $guiSrc" }
if (Test-Path $guiDst) { Copy-Item -Force $guiDst (Join-Path $backup "JitsiNdiGui.ps1") }
Copy-Item -Force $guiSrc $guiDst
Write-Host "[v57] Installed minimal safe GUI fix."
Write-Host "[v57] GUI-only: no native files changed, rebuild is not required."
Write-Host "[v57] Launch args remain: --room only."
Write-Host "[v57] Backup: $backup"
