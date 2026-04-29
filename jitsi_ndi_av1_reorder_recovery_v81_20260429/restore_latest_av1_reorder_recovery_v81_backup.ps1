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
