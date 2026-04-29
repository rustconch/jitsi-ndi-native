$ErrorActionPreference = 'Stop'

$PatchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Resolve-Path (Join-Path $PatchDir '..')
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$BackupRoot = Join-Path $Root ".jnn_patch_backups\emergency_restore_baseline_v79_$Stamp"
$BackupSrc = Join-Path $BackupRoot 'src'

$Files = @(
    'main.cpp',
    'NativeWebRTCAnswerer.h',
    'NativeWebRTCAnswerer.cpp',
    'JitsiSignaling.h',
    'JitsiSignaling.cpp'
)

New-Item -ItemType Directory -Force -Path $BackupSrc | Out-Null

foreach ($File in $Files) {
    $TargetFile = Join-Path $Root "src\$File"
    $PatchFile = Join-Path $PatchDir "src\$File"

    if (-not (Test-Path $TargetFile)) {
        throw "Missing project file: $TargetFile"
    }

    if (-not (Test-Path $PatchFile)) {
        throw "Missing restore file: $PatchFile"
    }

    Copy-Item -Force $TargetFile (Join-Path $BackupSrc $File)
    Copy-Item -Force $PatchFile $TargetFile
}

$RestoreScript = Join-Path $PatchDir 'restore_latest_emergency_restore_baseline_v79_backup.ps1'
$RestoreContent = @'
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
'@
Set-Content -Encoding ASCII -Path $RestoreScript -Value $RestoreContent

Write-Host "Applied emergency baseline restore v79. Backup: $BackupRoot"
Write-Host "Rebuild with: .\rebuild_with_dav1d_v21.ps1"
