$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$rel = Join-Path $root 'build\Release'
Write-Host "Jitsi NDI Portable v74d check"
Write-Host "Root: $root"
Write-Host "Release: $rel"
Write-Host ""
$must = @(
 'jitsi-ndi-native.exe',
 'Processing.NDI.Lib.x64.dll',
 'avcodec*.dll',
 'avutil*.dll',
 'swscale*.dll',
 'swresample*.dll',
 'dav1d*.dll',
 'libdav1d*.dll',
 'vcruntime140.dll',
 'vcruntime140_1.dll',
 'msvcp140.dll'
)
foreach ($m in $must) {
    $hit = Get-ChildItem -Path $rel -Filter $m -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { Write-Host ("OK   " + $hit.Name) -ForegroundColor Green }
    else { Write-Host ("MISS " + $m) -ForegroundColor Yellow }
}
Write-Host ""
Write-Host "Recent native logs:"
Get-ChildItem -Path (Join-Path $root 'logs') -Filter 'jitsi-ndi-native_*.log' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 5 Name,Length,LastWriteTime |
    Format-Table -AutoSize
Write-Host ""
Write-Host "If video freezes again, send the newest logs\jitsi-ndi-native_*.log around the freeze time."
