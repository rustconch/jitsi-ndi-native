$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"

function Backup-Copy($relativePath) {
    $src = Join-Path $PSScriptRoot $relativePath
    $dst = Join-Path $root $relativePath
    if (-not (Test-Path $src)) { throw "Patch file missing: $src" }
    if (Test-Path $dst) {
        Copy-Item -Force $dst ($dst + ".bak_v59b_" + $stamp)
    }
    $parent = Split-Path -Parent $dst
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    Copy-Item -Force $src $dst
    Write-Host "Updated $relativePath"
}

Backup-Copy "JitsiNdiGui.ps1"
Backup-Copy "src\JitsiSignaling.cpp"
Backup-Copy "src\main.cpp"
Write-Host "v59b applied. Rebuild native if v59 native changes were not already rebuilt."
