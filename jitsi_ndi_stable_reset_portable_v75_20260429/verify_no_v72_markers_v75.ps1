# v75 source marker check
$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path
$router = Join-Path $root 'src\PerParticipantNdiRouter.cpp'
$decoder = Join-Path $root 'src\FfmpegMediaDecoder.cpp'
Write-Host "[v75] Checking source markers in $root"
if (Test-Path $router) {
    $txt = [System.IO.File]::ReadAllText($router)
    if ($txt -match 'live-trim|live trim|freshest|drop.*fresh') { Write-Host "[WARN] Possible v72 live-trim markers in PerParticipantNdiRouter.cpp" }
    else { Write-Host "[OK] No obvious live-trim markers in PerParticipantNdiRouter.cpp" }
}
if (Test-Path $decoder) {
    $txt = [System.IO.File]::ReadAllText($decoder)
    if ($txt -match 'SWS_FAST_BILINEAR') { Write-Host "[WARN] SWS_FAST_BILINEAR marker found in FfmpegMediaDecoder.cpp" }
    else { Write-Host "[OK] No SWS_FAST_BILINEAR marker found in FfmpegMediaDecoder.cpp" }
}
