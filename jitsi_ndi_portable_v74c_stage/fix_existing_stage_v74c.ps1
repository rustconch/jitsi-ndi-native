$ErrorActionPreference = 'Stop'
param([string]$PortablePath)
if (-not $PortablePath) { $PortablePath = Read-Host 'Path to unpacked portable folder' }
$PortablePath = (Resolve-Path -LiteralPath $PortablePath).ProviderPath
$native = Join-Path $PortablePath 'build\Release\jitsi-ndi-native.exe'
if (-not (Test-Path -LiteralPath $native)) {
    Write-Host "MISS native exe: $native" -ForegroundColor Red
    Write-Host 'This script cannot fix a portable folder that does not contain build\Release\jitsi-ndi-native.exe.'
    exit 1
}
Get-ChildItem -LiteralPath $PortablePath -Recurse -Include '*.ps1','*.cmd','*.bat','*.txt','*.config' -File -ErrorAction SilentlyContinue | ForEach-Object {
    $text = [System.IO.File]::ReadAllText($_.FullName)
    if ($text.Contains('jitsi-ndi-natove.exe')) {
        $text = $text.Replace('jitsi-ndi-natove.exe','jitsi-ndi-native.exe')
        [System.IO.File]::WriteAllText($_.FullName, $text, [System.Text.Encoding]::ASCII)
        Write-Host "Fixed typo in $($_.FullName)"
    }
}
Write-Host 'Done.' -ForegroundColor Green
