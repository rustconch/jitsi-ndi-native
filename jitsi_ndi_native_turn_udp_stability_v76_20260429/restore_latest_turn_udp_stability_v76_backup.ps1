$ErrorActionPreference = "Stop"
$root = (Get-Location).Path
$backups = Get-ChildItem -LiteralPath $root -Directory -Filter "backup_turn_udp_stability_v76_*" | Sort-Object Name -Descending
if (-not $backups -or $backups.Count -eq 0) {
    throw "No backup_turn_udp_stability_v76_* folder found."
}
$backup = $backups[0].FullName
Copy-Item -Force (Join-Path $backup "JitsiSignaling.cpp") (Join-Path $root "src\JitsiSignaling.cpp")
Copy-Item -Force (Join-Path $backup "NativeWebRTCAnswerer.cpp") (Join-Path $root "src\NativeWebRTCAnswerer.cpp")
Write-Host "[v76] Restored backup: $backup"
Write-Host "[v76] Now rebuild: .\rebuild_with_dav1d_v21.ps1"
