$ErrorActionPreference = 'Stop'

$PatchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Resolve-Path (Join-Path $PatchDir '..')
$BackupParent = Join-Path $Root '.jnn_patch_backups'

$Latest = Get-ChildItem -Directory $BackupParent -Filter 'emergency_restore_baseline_v79_*' |
    Sort-Object Name -Descending |
    Select-Object -First 1

if (-not $Latest) {
    throw 'No emergency_restore_baseline_v79 backup found.'
}

$Files = @(
    'main.cpp',
    'NativeWebRTCAnswerer.h',
    'NativeWebRTCAnswerer.cpp',
    'JitsiSignaling.h',
    'JitsiSignaling.cpp'
)

foreach ($File in $Files) {
    $BackupFile = Join-Path $Latest.FullName "src\$File"
    $TargetFile = Join-Path $Root "src\$File"

    if (-not (Test-Path $BackupFile)) {
        throw "Missing backup file: $BackupFile"
    }

    Copy-Item -Force $BackupFile $TargetFile
}

Write-Host "Restored backup: $($Latest.FullName)"
