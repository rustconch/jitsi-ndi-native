$ErrorActionPreference = "Stop"

$root = (Get-Location).Path
$srcDir = Join-Path $root "src"
$target = Join-Path $srcDir "NativeWebRTCAnswerer.cpp"
$patchFile = Join-Path $PSScriptRoot "NativeWebRTCAnswerer.cpp"

if (!(Test-Path $target)) {
    throw "Target file not found: $target. Run this script from the jitsi-ndi-native repo root."
}
if (!(Test-Path $patchFile)) {
    throw "Patch file not found: $patchFile"
}

$backupDir = Join-Path $root ("backup_v85_overload_guard_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
Copy-Item -Force $target (Join-Path $backupDir "NativeWebRTCAnswerer.cpp")
Copy-Item -Force $patchFile $target

Write-Host "Applied v85 overload guard patch. Backup: $backupDir"
Write-Host "Now rebuild with: .\rebuild_with_dav1d_v21.ps1"
