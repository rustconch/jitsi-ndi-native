param(
    [string]$RepoRoot = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'
$patch = Join-Path $RepoRoot 'jitsi_ndi_native_nudnye_fixes.patch'
if (-not (Test-Path $patch)) {
    throw "Patch not found: $patch"
}

Push-Location $RepoRoot
try {
    git apply --whitespace=nowarn $patch
    Write-Host 'Patch applied.'
} finally {
    Pop-Location
}
