$ErrorActionPreference = 'Stop'
function Info($m) { Write-Host "[v21-check] $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "[v21-check][WARN] $m" -ForegroundColor Yellow }
function Die($m) { Write-Host "[v21-check][ERROR] $m" -ForegroundColor Red; exit 1 }

$dst = Join-Path (Get-Location).Path 'build\Release'
if (-not (Test-Path $dst)) { Die "Release directory not found: $dst" }

$davDll = Get-ChildItem $dst -Filter '*dav1d*.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $davDll) {
  Die "No dav1d DLL beside exe. Run rebuild_with_dav1d_v21.ps1, not only cmake --build."
}
Info "Found dav1d DLL beside exe: $($davDll.Name)"

$avcodec = Get-ChildItem $dst -Filter 'avcodec-*.dll' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if (-not $avcodec) { Die "avcodec DLL not found beside exe" }
Info "Found avcodec: $($avcodec.Name)"

$roots = @(
  "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022",
  "${env:ProgramFiles}\Microsoft Visual Studio\2022"
) | Where-Object { $_ -and (Test-Path $_) }
$dumpbin = $null
if ($roots.Count -gt 0) {
  $dumpbin = Get-ChildItem $roots -Recurse -Filter dumpbin.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\VC\\Tools\\MSVC\\.*\\bin\\Hostx64\\x64\\dumpbin\.exe$' } |
    Sort-Object FullName -Descending |
    Select-Object -First 1
}

if ($dumpbin) {
  Info "Using dumpbin: $($dumpbin.FullName)"
  $out = & $dumpbin.FullName /DEPENDENTS $avcodec.FullName 2>&1 | Out-String
  if ($out -match 'dav1d') {
    Info "OK: avcodec depends on dav1d. FFmpeg should expose libdav1d decoder."
  } else {
    Warn "dumpbin did not show dav1d dependency in avcodec. The FFmpeg build may still not include libdav1d."
    Warn "Relevant dependency output:"
    $out | Select-String -Pattern 'dll' | ForEach-Object { Write-Host $_.Line }
    exit 2
  }
} else {
  Warn "dumpbin not found; skipped dependency check"
}
