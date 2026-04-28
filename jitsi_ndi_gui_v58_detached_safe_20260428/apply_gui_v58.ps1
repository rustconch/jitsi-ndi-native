$ErrorActionPreference = 'Stop'
$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $patchDir
$src = Join-Path $patchDir 'JitsiNdiGui.ps1'
$dst = Join-Path $repoRoot 'JitsiNdiGui.ps1'
if (-not (Test-Path $src)) { throw "Patch file not found: $src" }
if (Test-Path $dst) {
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    Copy-Item -LiteralPath $dst -Destination (Join-Path $repoRoot ("JitsiNdiGui.backup_v58_$stamp.ps1")) -Force
}
Copy-Item -LiteralPath $src -Destination $dst -Force
Write-Host '[v58] Applied GUI only patch. Native code was not touched.'
Write-Host '[v58] Start with: powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1'
