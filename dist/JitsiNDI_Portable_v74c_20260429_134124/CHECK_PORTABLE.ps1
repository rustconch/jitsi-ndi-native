$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSCommandPath
function Check($label, $path) {
    if (Test-Path -LiteralPath $path) { Write-Host "OK   $label -> $path" -ForegroundColor Green }
    else { Write-Host "MISS $label -> $path" -ForegroundColor Red }
}
Check 'JitsiNDI.exe' (Join-Path $root 'JitsiNDI.exe')
Check 'JitsiNdiGui.ps1' (Join-Path $root 'JitsiNdiGui.ps1')
Check 'native exe' (Join-Path $root 'build\Release\jitsi-ndi-native.exe')
Check 'NDI runtime DLL' (Join-Path $root 'build\Release\Processing.NDI.Lib.x64.dll')
Check 'avcodec DLL' ((Get-ChildItem -LiteralPath (Join-Path $root 'build\Release') -Filter 'avcodec*.dll' -File -ErrorAction SilentlyContinue | Select-Object -First 1).FullName)
Check 'avutil DLL' ((Get-ChildItem -LiteralPath (Join-Path $root 'build\Release') -Filter 'avutil*.dll' -File -ErrorAction SilentlyContinue | Select-Object -First 1).FullName)
Check 'swscale DLL' ((Get-ChildItem -LiteralPath (Join-Path $root 'build\Release') -Filter 'swscale*.dll' -File -ErrorAction SilentlyContinue | Select-Object -First 1).FullName)
Check 'dav1d DLL' ((Get-ChildItem -LiteralPath (Join-Path $root 'build\Release') -Filter '*dav1d*.dll' -File -ErrorAction SilentlyContinue | Select-Object -First 1).FullName)
$bad = Get-ChildItem -LiteralPath $root -Recurse -Include '*.ps1','*.cmd','*.bat','*.txt','*.config' -File -ErrorAction SilentlyContinue | Select-String -Pattern 'natove' -SimpleMatch -ErrorAction SilentlyContinue
if ($bad) { Write-Host 'WARN natove typo found:' -ForegroundColor Yellow; $bad | ForEach-Object { Write-Host $_.Path ':' $_.LineNumber ':' $_.Line } } else { Write-Host 'OK   no natove typo found' -ForegroundColor Green }
