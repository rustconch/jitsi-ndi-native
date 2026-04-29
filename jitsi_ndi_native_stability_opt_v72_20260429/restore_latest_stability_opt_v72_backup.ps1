# Restore latest v72 stability optimization backup.
$ErrorActionPreference = "Stop"
$root = Join-Path (Get-Location).Path ".jnn_patch_backups"
if (-not (Test-Path $root)) { throw "No .jnn_patch_backups directory found." }
$backup = Get-ChildItem $root -Directory -Filter "stability_opt_v72_*" | Sort-Object Name -Descending | Select-Object -First 1
if (-not $backup) { throw "No stability_opt_v72 backup found." }
Write-Host "[v72] restoring from $($backup.FullName)"
$files = @(
    "src\PerParticipantNdiRouter.cpp",
    "src\Av1RtpFrameAssembler.cpp",
    "src\FfmpegMediaDecoder.cpp"
)
foreach ($f in $files) {
    $src = Join-Path $backup.FullName $f
    if (Test-Path $src) {
        Copy-Item $src $f -Force
        Write-Host "[v72] restored $f"
    } else {
        Write-Host "[v72] missing backup for $f"
    }
}
Write-Host "[v72] restore done. Rebuild native if needed."
