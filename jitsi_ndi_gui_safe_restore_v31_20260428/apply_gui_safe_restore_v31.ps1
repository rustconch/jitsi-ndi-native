# Apply safe GUI v31 for jitsi-ndi-native
$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
$target = Join-Path $repoRoot "JitsiNdiGui.ps1"
$source = Join-Path $scriptDir "JitsiNdiGui.ps1"
$backupDir = Join-Path $repoRoot ".jnn_patch_backups"

if (-not (Test-Path -LiteralPath $source)) {
    throw "Patch file not found: $source"
}
if (-not (Test-Path -LiteralPath $backupDir)) {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
}
if (Test-Path -LiteralPath $target) {
    $backup = Join-Path $backupDir ("JitsiNdiGui_before_safe_v31_" + (Get-Date).ToString("yyyyMMdd_HHmmss") + ".ps1")
    Copy-Item -LiteralPath $target -Destination $backup -Force
    Write-Host "Backup saved:" $backup
}
Copy-Item -LiteralPath $source -Destination $target -Force
Write-Host "Installed safe GUI:" $target
Write-Host ""
Write-Host "Run:"
Write-Host "  powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1"
Write-Host ""
Write-Host "Safe GUI v31 changes only JitsiNdiGui.ps1. It does not touch src, build-ndi, DLLs, CMake or native exe."
