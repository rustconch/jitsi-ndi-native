$ErrorActionPreference = 'Stop'

$PatchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Resolve-Path (Join-Path $PatchDir '..')
$BackupParent = Join-Path $Root '.jnn_patch_backups'

$Latest = Get-ChildItem -Directory $BackupParent -Filter 'fast_recovery_v78b_safe_*' |
    Sort-Object Name -Descending |
    Select-Object -First 1

if (-not $Latest) {
    throw 'No fast_recovery_v78b_safe backup found.'
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
