$ErrorActionPreference = 'Continue'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $scriptRoot '..')).Path
Set-Location -LiteralPath $projectRoot
Write-Host '[v74b] Trying to rollback v72/v72b/v72c stability patch if backup scripts exist...'
$candidates = @(
    '.\jitsi_ndi_native_stability_opt_v72c_fix_20260429\restore_latest_stability_opt_v72c_backup.ps1',
    '.\jitsi_ndi_native_stability_opt_v72b_fix_20260429\restore_latest_stability_opt_v72b_backup.ps1',
    '.\jitsi_ndi_native_stability_opt_v72_20260429\restore_latest_stability_opt_v72_backup.ps1'
)
$ran = $false
foreach ($c in $candidates) {
    if (Test-Path -LiteralPath $c) {
        Write-Host "[v74b] Running: $c"
        & $c
        $ran = $true
        break
    }
}
if (-not $ran) {
    Write-Host '[v74b] No v72 restore script found. Nothing rolled back.' -ForegroundColor Yellow
}
