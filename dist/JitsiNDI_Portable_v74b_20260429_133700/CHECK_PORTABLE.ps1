$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$release = Join-Path $root 'build\Release'
function Check($label, $path) {
    if (Test-Path -LiteralPath $path) { Write-Host ("OK   " + $label) -ForegroundColor Green }
    else { Write-Host ("MISS " + $label + " -> " + $path) -ForegroundColor Red }
}
Write-Host 'Jitsi NDI portable check v74b'
Write-Host "Root: $root"
Check 'JitsiNDI.exe' (Join-Path $root 'JitsiNDI.exe')
Check 'JitsiNdiGui.ps1' (Join-Path $root 'JitsiNdiGui.ps1')
Check 'build\Release\jitsi-ndi-native.exe' (Join-Path $release 'jitsi-ndi-native.exe')
$wrong = Join-Path $release 'jitsi-ndi-natove.exe'
if (Test-Path -LiteralPath $wrong) { Write-Host "TYPO FOUND: $wrong" -ForegroundColor Red }
Check 'Processing.NDI.Lib.x64.dll' (Join-Path $release 'Processing.NDI.Lib.x64.dll')
$dlls = Get-ChildItem -LiteralPath $release -Filter '*.dll' -File -ErrorAction SilentlyContinue
Write-Host ("DLL count in build\Release: " + ($dlls.Count))
Write-Host ''
Write-Host 'Video-related DLLs:'
$dlls | Where-Object { $_.Name -match 'avcodec|avutil|swscale|swresample|dav1d|vpx|aom|SvtAv1|vcruntime|msvcp' } | Sort-Object Name | ForEach-Object { Write-Host ('  ' + $_.Name) }
Write-Host ''
Write-Host 'Typo scan:'
$hits = Get-ChildItem -LiteralPath $root -Include '*.ps1','*.txt','*.json','*.config','*.cs' -File -Recurse -ErrorAction SilentlyContinue | Select-String -Pattern 'jitsi-ndi-natove' -SimpleMatch -ErrorAction SilentlyContinue
if ($hits) { $hits | ForEach-Object { Write-Host ("TYPO REF: " + $_.Path + ':' + $_.LineNumber) -ForegroundColor Red } } else { Write-Host 'OK   no jitsi-ndi-natove references found' -ForegroundColor Green }