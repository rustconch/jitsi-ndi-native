$ErrorActionPreference = 'Stop'
$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir = Resolve-Path (Join-Path $patchDir '..')
Set-Location $repoDir
if (-not (Test-Path '.\rebuild_with_dav1d_v21.ps1')) {
  throw 'rebuild_with_dav1d_v21.ps1 not found in repo root.'
}
.\rebuild_with_dav1d_v21.ps1
