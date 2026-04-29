$ErrorActionPreference = 'Stop'

function Find-RepoRoot {
    $d = Get-Item -LiteralPath (Get-Location).Path
    while ($null -ne $d) {
        $cmake = Join-Path $d.FullName 'CMakeLists.txt'
        $router = Join-Path $d.FullName 'src\PerParticipantNdiRouter.cpp'
        if ((Test-Path -LiteralPath $cmake) -and (Test-Path -LiteralPath $router)) {
            return $d.FullName
        }
        $d = $d.Parent
    }
    throw 'Repo root not found. Run this script from D:\MEDIA\Desktop\jitsi-ndi-native or inside it.'
}

$root = Find-RepoRoot
Set-Location -LiteralPath $root
Write-Host "[v74] Repo root: $root"

$candidates = @(
    'jitsi_ndi_native_stability_opt_v72c_fix_20260429\restore_latest_stability_opt_v72c_backup.ps1',
    'jitsi_ndi_native_stability_opt_v72b_fix_20260429\restore_latest_stability_opt_v72b_backup.ps1',
    'jitsi_ndi_native_stability_opt_v72_20260429\restore_latest_stability_opt_v72_backup.ps1'
)

$restore = $null
foreach ($rel in $candidates) {
    $p = Join-Path $root $rel
    if (Test-Path -LiteralPath $p) {
        $restore = $p
        break
    }
}

if (-not $restore) {
    throw 'No v72 restore script found. Keep the v72c patch folder in the repo root, then run this again.'
}

Write-Host "[v74] Running restore: $restore"
& powershell -NoProfile -ExecutionPolicy Bypass -File $restore
if ($LASTEXITCODE -ne 0) {
    throw "Restore script failed with code $LASTEXITCODE"
}

Write-Host '[v74] Rollback finished.'
Write-Host '[v74] Now rebuild native:'
Write-Host '       .\rebuild_with_dav1d_v21.ps1'
Write-Host '[v74] After successful rebuild, run:'
Write-Host '       .\jitsi_ndi_rollback_and_portable_v74_20260429\make_portable_v74.ps1'
