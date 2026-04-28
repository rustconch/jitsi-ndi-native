$ErrorActionPreference = 'Stop'

$root = (Get-Location).Path
Write-Host "[fetch-fix] Project root: $root"

$rebuild = Join-Path $root 'rebuild_with_dav1d_v21.ps1'
if (-not (Test-Path $rebuild)) {
    throw "rebuild_with_dav1d_v21.ps1 not found. Run this script from the project root."
}

Write-Host "[fetch-fix] Applying safer git HTTP settings for this Windows user..."
git config --global http.version HTTP/1.1 | Out-Null
git config --global http.postBuffer 524288000 | Out-Null
git config --global core.compression 0 | Out-Null

$pathsToRemove = @(
    'build/_deps/libdatachannel-src',
    'build/_deps/libdatachannel-build',
    'build/_deps/libdatachannel-subbuild',
    'build-ndi/_deps/libdatachannel-src',
    'build-ndi/_deps/libdatachannel-build',
    'build-ndi/_deps/libdatachannel-subbuild'
)

foreach ($rel in $pathsToRemove) {
    $p = Join-Path $root $rel
    if (Test-Path $p) {
        Write-Host "[fetch-fix] Removing partial/corrupt dependency folder: $rel"
        Remove-Item -Recurse -Force $p
    }
}

$ok = $false
for ($i = 1; $i -le 3; $i++) {
    Write-Host "[fetch-fix] Build attempt $i of 3..."
    try {
        & powershell -ExecutionPolicy Bypass -File $rebuild
        if ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE) {
            $ok = $true
            break
        }
        Write-Host "[fetch-fix] Build script exited with code $LASTEXITCODE"
    } catch {
        Write-Host "[fetch-fix] Attempt $i failed: $($_.Exception.Message)"
    }

    if ($i -lt 3) {
        Write-Host "[fetch-fix] Waiting 5 seconds before retry..."
        Start-Sleep -Seconds 5
    }
}

if (-not $ok) {
    throw "Build still failed after retries. This is most likely a GitHub/network fetch problem, not a C++ compile error. Try another network/VPN off-on, then run this script again."
}

Write-Host "[fetch-fix] Done. Build completed."
