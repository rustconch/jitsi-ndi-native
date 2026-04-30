$ErrorActionPreference = "Stop"

$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $patchDir
$srcDir = Join-Path $repoRoot "src"
$backup = Get-ChildItem -Directory -Path $repoRoot -Filter "backup_v99_conference_safe_budget_*" | Sort-Object Name -Descending | Select-Object -First 1

if (!$backup) {
    throw "No v99 backup directory found."
}

Get-ChildItem -File $backup.FullName | ForEach-Object {
    Copy-Item -Force $_.FullName (Join-Path $srcDir $_.Name)
}

Write-Host "Restored backup:" $backup.FullName
