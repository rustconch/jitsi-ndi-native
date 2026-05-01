$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$rel = Join-Path $root 'build\Release'
Write-Host "Jitsi NDI portable check v68"
Write-Host "Root: $root"
Write-Host ""

$items = @(
    'JitsiNDI.exe',
    'JitsiNdiGui.ps1',
    'build\Release\jitsi-ndi-native.exe',
    'build\Release\Processing.NDI.Lib.x64.dll',
    'build\Release\vcruntime140.dll',
    'build\Release\vcruntime140_1.dll',
    'build\Release\msvcp140.dll'
)
foreach ($i in $items) {
    $p = Join-Path $root $i
    if (Test-Path $p) { Write-Host "OK   $i" -ForegroundColor Green } else { Write-Host "MISS $i" -ForegroundColor Yellow }
}

Write-Host ""
$dlls = Get-ChildItem -Path $rel -Filter '*.dll' -ErrorAction SilentlyContinue
Write-Host "DLL count in build\Release: $($dlls.Count)"
$dlls | Sort-Object Name | Select-Object -ExpandProperty Name | ForEach-Object { Write-Host "  $_" }

Write-Host ""
Write-Host "If NDI source is still missing:"
Write-Host "1) Allow JitsiNDI.exe and jitsi-ndi-native.exe in Windows Firewall."
Write-Host "2) Make sure NDI Tools/Runtime is installed, or Processing.NDI.Lib.x64.dll is present above."
Write-Host "3) Run JitsiNDI.exe, connect, then open the newest file in logs."
