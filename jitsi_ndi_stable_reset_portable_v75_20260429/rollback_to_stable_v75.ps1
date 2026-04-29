# v75 stable reset for jitsi-ndi-native
# ASCII-only PowerShell script to avoid encoding/parser issues.
$ErrorActionPreference = 'Stop'

function Log($m) { Write-Host "[v75] $m" }

function Find-ProjectRoot {
    $candidates = @()
    $candidates += (Get-Location).Path
    if ($PSScriptRoot) { $candidates += (Split-Path -Parent $PSScriptRoot) }
    if ($PSScriptRoot) { $candidates += $PSScriptRoot }
    foreach ($s in $candidates) {
        if (-not $s) { continue }
        $d = Get-Item -LiteralPath $s -ErrorAction SilentlyContinue
        while ($d -and $d.PSIsContainer) {
            $cmake = Join-Path $d.FullName 'CMakeLists.txt'
            $src = Join-Path $d.FullName 'src'
            if ((Test-Path -LiteralPath $cmake) -and (Test-Path -LiteralPath $src)) {
                return $d.FullName
            }
            $d = $d.Parent
        }
    }
    throw 'Project root not found. Run this from repo root: D:\MEDIA\Desktop\jitsi-ndi-native'
}

$root = Find-ProjectRoot
Log "Project root: $root"
Set-Location -LiteralPath $root

$restoreScripts = @(
    'jitsi_ndi_native_stability_opt_v72c_fix_20260429\restore_latest_stability_opt_v72c_backup.ps1',
    'jitsi_ndi_native_stability_opt_v72b_fix_20260429\restore_latest_stability_opt_v72b_backup.ps1',
    'jitsi_ndi_native_stability_opt_v72_20260429\restore_latest_stability_opt_v72_backup.ps1'
)

$ranRestore = $false
foreach ($rel in $restoreScripts) {
    $p = Join-Path $root $rel
    if (Test-Path -LiteralPath $p) {
        Log "Running restore script: $rel"
        & powershell -NoProfile -ExecutionPolicy Bypass -File $p
        if ($LASTEXITCODE -ne 0) {
            throw "Restore script failed: $rel"
        }
        $ranRestore = $true
        break
    }
}

if (-not $ranRestore) {
    Log "Restore script was not found. Trying backup-file fallback."

    $backupDirs = Get-ChildItem -LiteralPath $root -Recurse -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'backup|bak|v72' } |
        Sort-Object LastWriteTime -Descending

    $wanted = @(
        'src\PerParticipantNdiRouter.cpp',
        'src\FfmpegMediaDecoder.cpp',
        'src\RealNdiSender.cpp',
        'src\NativeWebRTCAnswerer.cpp'
    )

    $restoredAny = $false
    foreach ($rel in $wanted) {
        $fileName = Split-Path $rel -Leaf
        $found = $backupDirs | ForEach-Object {
            $candidate = Join-Path $_.FullName $rel
            if (Test-Path -LiteralPath $candidate) { Get-Item -LiteralPath $candidate }
            else {
                Get-ChildItem -LiteralPath $_.FullName -Recurse -File -Filter $fileName -ErrorAction SilentlyContinue | Select-Object -First 1
            }
        } | Where-Object { $_ } | Sort-Object LastWriteTime -Descending | Select-Object -First 1

        if ($found) {
            $dst = Join-Path $root $rel
            Log "Fallback restore: $($found.FullName) -> $dst"
            Copy-Item -LiteralPath $found.FullName -Destination $dst -Force
            $restoredAny = $true
        }
    }

    if (-not $restoredAny) {
        throw 'No v72 restore script or backup files found. Need a known-good source snapshot/archive to restore native code.'
    }
}

# Check for obvious v72 optimization markers.
$router = Join-Path $root 'src\PerParticipantNdiRouter.cpp'
$decoder = Join-Path $root 'src\FfmpegMediaDecoder.cpp'
$markers = @()
if (Test-Path -LiteralPath $router) {
    $txt = [System.IO.File]::ReadAllText($router)
    if ($txt -match 'live-trim|live trim|drop.*fresh|freshest') { $markers += 'PerParticipantNdiRouter live-trim markers' }
}
if (Test-Path -LiteralPath $decoder) {
    $txt = [System.IO.File]::ReadAllText($decoder)
    if ($txt -match 'SWS_FAST_BILINEAR') { $markers += 'FfmpegMediaDecoder SWS_FAST_BILINEAR marker' }
}
if ($markers.Count -gt 0) {
    Write-Host "[v75][WARN] Some v72 optimization markers may still be present:"
    $markers | ForEach-Object { Write-Host "  - $_" }
    Write-Host "[v75][WARN] Continue only if you know this source is stable."
} else {
    Log "No obvious v72 optimization markers found."
}

Log "Stable reset step complete."
Log "Next recommended command:"
Log ".\rebuild_with_dav1d_v21.ps1"
