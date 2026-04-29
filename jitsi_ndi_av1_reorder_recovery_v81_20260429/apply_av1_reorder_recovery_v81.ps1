$ErrorActionPreference = 'Stop'

$PatchName = 'av1_reorder_recovery_v81'
$Root = (Get-Location).Path
$BackupRoot = Join-Path $Root '.jnn_patch_backups'
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$BackupDir = Join-Path $BackupRoot ($PatchName + '_' + $Stamp)
$PatchDir = Split-Path -Parent $MyInvocation.MyCommand.Path

New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

$Files = @(
  'src\Av1RtpFrameAssembler.cpp',
  'src\Av1RtpFrameAssembler.h'
)

foreach ($rel in $Files) {
  $target = Join-Path $Root $rel
  if (!(Test-Path $target)) { throw ('Missing target file: ' + $rel) }
  $backup = Join-Path $BackupDir $rel
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup) | Out-Null
  Copy-Item -Force $target $backup
}

Copy-Item -Force (Join-Path $PatchDir 'Av1RtpFrameAssembler.cpp') (Join-Path $Root 'src\Av1RtpFrameAssembler.cpp')
Copy-Item -Force (Join-Path $PatchDir 'Av1RtpFrameAssembler.h') (Join-Path $Root 'src\Av1RtpFrameAssembler.h')

$Restore = Join-Path $PatchDir 'restore_latest_av1_reorder_recovery_v81_backup.ps1'
@'
$ErrorActionPreference = 'Stop'
$Root = (Get-Location).Path
$BackupRoot = Join-Path $Root '.jnn_patch_backups'
$Latest = Get-ChildItem -Path $BackupRoot -Directory -Filter 'av1_reorder_recovery_v81_*' | Sort-Object Name -Descending | Select-Object -First 1
if ($null -eq $Latest) { throw 'No av1_reorder_recovery_v81 backup found.' }
$Files = @(
  'src\Av1RtpFrameAssembler.cpp',
  'src\Av1RtpFrameAssembler.h'
)
foreach ($rel in $Files) {
  $src = Join-Path $Latest.FullName $rel
  $dst = Join-Path $Root $rel
  if (!(Test-Path $src)) { throw ('Missing backup file: ' + $rel) }
  Copy-Item -Force $src $dst
}
Write-Host ('Restored backup: ' + $Latest.FullName)
'@ | Set-Content -Encoding UTF8 $Restore

Write-Host 'Applied av1_reorder_recovery_v81.'
Write-Host ('Backup: ' + $BackupDir)
