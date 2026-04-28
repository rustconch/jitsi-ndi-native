$ErrorActionPreference = "Stop"
$root = (Get-Location).Path
$backup = Get-ChildItem -Directory -Path $root -Filter "backup_rejoin_renegotiate_v49_*" | Sort-Object Name -Descending | Select-Object -First 1
if (-not $backup) { throw "No v49 backup folder found." }
Copy-Item -Force -Recurse (Join-Path $backup.FullName "src\*") (Join-Path $root "src")
Write-Host "Restored backup: $($backup.FullName)"
Write-Host "Now rebuild: .\rebuild_with_dav1d_v21.ps1"
