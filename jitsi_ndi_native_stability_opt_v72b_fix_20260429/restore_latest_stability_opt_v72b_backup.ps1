# Restore latest v72/v72b stability optimization backup.
# ASCII-only PowerShell script.
$ErrorActionPreference = "Stop"

function Is-RepoRoot($p) {
    if (-not $p) { return $false }
    return ((Test-Path (Join-Path $p "src\PerParticipantNdiRouter.cpp")) -and (Test-Path (Join-Path $p "CMakeLists.txt")))
}
function Find-RepoRoot() {
    $starts = @((Get-Location).Path)
    if ($PSScriptRoot) { $starts += $PSScriptRoot; $starts += (Split-Path -Parent $PSScriptRoot) }
    foreach ($s in $starts) {
        if (-not $s) { continue }
        $d = [System.IO.DirectoryInfo](Resolve-Path -LiteralPath $s)
        while ($d -ne $null) {
            if (Is-RepoRoot $d.FullName) { return $d.FullName }
            $d = $d.Parent
        }
    }
    throw "Could not find repo root."
}

$repo = Find-RepoRoot
Set-Location $repo
[System.IO.Directory]::SetCurrentDirectory($repo)
$root = Join-Path $repo ".jnn_patch_backups"
if (-not (Test-Path $root)) { throw "No .jnn_patch_backups directory found." }
$backup = Get-ChildItem $root -Directory | Where-Object { $_.Name -like "stability_opt_v72*" } | Sort-Object Name -Descending | Select-Object -First 1
if (-not $backup) { throw "No stability_opt_v72/v72b backup found." }
Write-Host "[v72b] restoring from $($backup.FullName)"
$files = @(
    "src\PerParticipantNdiRouter.cpp",
    "src\Av1RtpFrameAssembler.cpp",
    "src\FfmpegMediaDecoder.cpp"
)
foreach ($f in $files) {
    $src = Join-Path $backup.FullName $f
    $dst = Join-Path $repo $f
    if (Test-Path $src) {
        Copy-Item $src $dst -Force
        Write-Host "[v72b] restored $f"
    } else {
        Write-Host "[v72b] missing backup for $f"
    }
}
Write-Host "[v72b] restore done. Rebuild native if needed."
