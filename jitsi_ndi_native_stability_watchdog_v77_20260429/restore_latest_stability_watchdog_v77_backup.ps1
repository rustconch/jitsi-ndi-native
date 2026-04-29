$ErrorActionPreference = 'Stop'

$Root = (Get-Location).Path
$BackupRoot = Join-Path $Root '.jnn_patch_backups'
if (-not (Test-Path $BackupRoot)) {
    throw 'No .jnn_patch_backups directory found.'
}

$Latest = Get-ChildItem $BackupRoot -Directory -Filter 'stability_watchdog_v77_*' |
    Sort-Object Name -Descending |
    Select-Object -First 1

if (-not $Latest) {
    throw 'No stability_watchdog_v77 backup found.'
}

$BackupMain = Join-Path $Latest.FullName 'main.cpp'
$Main = Join-Path $Root 'src\main.cpp'

if (-not (Test-Path $BackupMain)) {
    throw "Backup main.cpp not found in $($Latest.FullName)."
}

Copy-Item $BackupMain $Main -Force
Write-Host "Restored src\main.cpp from $($Latest.FullName)"
