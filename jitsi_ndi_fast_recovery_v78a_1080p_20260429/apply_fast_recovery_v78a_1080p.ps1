$ErrorActionPreference = 'Stop'

$PatchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Resolve-Path (Join-Path $PatchDir '..')
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$BackupRoot = Join-Path $Root ".jnn_patch_backups\fast_recovery_v78a_1080p_$Stamp"
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
    $SrcFile = Join-Path $Root "src\$File"
    $PatchFile = Join-Path $PatchDir "src\$File"

    if (-not (Test-Path $SrcFile)) {
        throw "Missing project file: $SrcFile"
    }

    if (-not (Test-Path $PatchFile)) {
        throw "Missing patch file: $PatchFile"
    }

    Copy-Item -Force $SrcFile (Join-Path $BackupSrc $File)
    Copy-Item -Force $PatchFile $SrcFile
}

$RestoreScript = Join-Path $PatchDir 'restore_latest_fast_recovery_v78a_1080p_backup.ps1'
$RestoreContent = @'
$ErrorActionPreference = 'Stop'

$PatchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Resolve-Path (Join-Path $PatchDir '..')
$BackupParent = Join-Path $Root '.jnn_patch_backups'

$Latest = Get-ChildItem -Directory $BackupParent -Filter 'fast_recovery_v78a_1080p_*' |
    Sort-Object Name -Descending |
    Select-Object -First 1

if (-not $Latest) {
    throw 'No fast_recovery_v78a_1080p backup found.'
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

Write-Host "Applied fast recovery v78a 1080p patch. Backup: $BackupRoot"
Write-Host "Rebuild with: .\rebuild_with_dav1d_v21.ps1"
