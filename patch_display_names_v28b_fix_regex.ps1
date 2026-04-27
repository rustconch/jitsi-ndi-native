$ErrorActionPreference = 'Stop'

function Fail($msg) {
  Write-Host "[v28b][ERROR] $msg" -ForegroundColor Red
  exit 1
}

$root = (Get-Location).Path
Write-Host "[v28b] Repository root: $root"

$sourceMapCpp = Join-Path $root 'src\JitsiSourceMap.cpp'
if (!(Test-Path $sourceMapCpp)) { Fail "src\JitsiSourceMap.cpp not found. Run this script from repository root." }

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
Copy-Item $sourceMapCpp "$sourceMapCpp.bak_v28b_$stamp" -Force
Write-Host "[v28b] Backup: $sourceMapCpp.bak_v28b_$stamp"

$cpp = Get-Content $sourceMapCpp -Raw -Encoding UTF8
$before = $cpp

# v28 typo: this raw string closes too early at +)" and MSVC then sees \s as an invalid escape.
# Broken:
#   const std::regex keyRe(R"("([^"]+)"\s*:)");
# Fixed by using a custom raw-string delimiter.
$cpp = $cpp.Replace('const std::regex keyRe(R"("([^"]+)"\s*:)");', 'const std::regex keyRe(R"KEY("([^"]+)"\s*:)KEY");')
$cpp = $cpp.Replace('const std::regex keyRe(R"("([^"]+)"\s*:)" );', 'const std::regex keyRe(R"KEY("([^"]+)"\s*:)KEY");')

# More tolerant fallback: replace the whole keyRe line if it still contains the broken R"(" pattern.
if ($cpp -match 'const\s+std::regex\s+keyRe\(R"\("') {
  $cpp = [regex]::Replace(
    $cpp,
    'const\s+std::regex\s+keyRe\([^;]*;','const std::regex keyRe(R"KEY("([^"]+)"\s*:)KEY");'
  )
}

if ($cpp -eq $before) {
  Write-Host "[v28b] Exact broken keyRe line was not found; checking if file is already fixed..."
}

if ($cpp -notmatch 'R"KEY\("\(\[\^"\]\+\)"\\s\*:\)KEY"') {
  # Do not fail just because regex text matching is awkward; print context for diagnostics.
  Write-Host "[v28b] keyRe context after patch:" -ForegroundColor Yellow
  ($cpp -split "`r?`n") | Select-String -Pattern 'keyRe|sourceNamesFromSourceInfo' -Context 2,2 | ForEach-Object { $_.ToString() }
}

Set-Content $sourceMapCpp $cpp -Encoding UTF8
Write-Host "[v28b] Patched JitsiSourceMap.cpp regex raw-string delimiter"

Write-Host "[v28b] Building Release..."
cmake --build build --config Release
if ($LASTEXITCODE -ne 0) { Fail "Build failed" }

$copyScript = Join-Path $root 'copy_runtime_dlls_v21.ps1'
if (Test-Path $copyScript) {
  Write-Host "[v28b] Running existing runtime DLL copier..."
  powershell -ExecutionPolicy Bypass -File $copyScript
}

Write-Host ""
Write-Host "[v28b] Done." -ForegroundColor Green
Write-Host "Run:"
Write-Host "  .\build\Release\jitsi-ndi-native.exe --room 6767676766767penxyi"
