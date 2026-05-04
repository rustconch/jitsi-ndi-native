$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Write-Host "=== Jitsi NDI Portable v104 ===" -ForegroundColor Cyan
Write-Host "Root: $root"; Write-Host ""
$req = @('JitsiNDI.exe','JitsiNdiGui.ps1','jitsi-ndi-native.exe',
         'Processing.NDI.Lib.x64.dll','vcruntime140.dll','msvcp140.dll',
         'avcodec-62.dll','dav1d.dll','opus.dll','datachannel.dll')
$ok = $true
foreach ($f in $req) {
    $p = Join-Path $root $f
    if (Test-Path $p) { Write-Host "  OK   $f" -ForegroundColor Green }
    else { Write-Host "  MISS $f" -ForegroundColor Red; $ok = $false }
}
$dlls = (Get-ChildItem $root -Filter '*.dll' -EA SilentlyContinue).Count
Write-Host ""; Write-Host "Total DLLs: $dlls"
$fw = netsh advfirewall firewall show rule name="Jitsi NDI Native IN" 2>&1
Write-Host ""
if ($fw -match 'Jitsi NDI') { Write-Host "Firewall: rule found" -ForegroundColor Green }
else { Write-Host "Firewall: rule MISSING - run SETUP_FIREWALL.cmd as admin!" -ForegroundColor Yellow }
Write-Host ""
if ($ok) { Write-Host "All required files present." -ForegroundColor Green }
else { Write-Host "Some files missing - rebuild portable." -ForegroundColor Red }
