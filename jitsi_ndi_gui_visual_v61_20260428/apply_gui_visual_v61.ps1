$ErrorActionPreference = 'Stop'
$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $patchDir
$src = Join-Path $patchDir 'JitsiNdiGui.ps1'
$dst = Join-Path $root 'JitsiNdiGui.ps1'
if (-not (Test-Path $src)) { throw "Patch file not found: $src" }
if (Test-Path $dst) {
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    Copy-Item -LiteralPath $dst -Destination (Join-Path $root "JitsiNdiGui.backup_v61_$stamp.ps1") -Force
}
Copy-Item -LiteralPath $src -Destination $dst -Force
Write-Host '[v61] GUI visual redesign applied.'
Write-Host '[v61] Only JitsiNdiGui.ps1 was changed. No rebuild required.'
Write-Host '[v61] Fonts are not bundled. To use Circe from files, keep your supplied gui folder in repo root.'
