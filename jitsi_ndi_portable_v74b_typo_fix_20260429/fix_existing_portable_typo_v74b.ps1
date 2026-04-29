param(
    [string]$PortableRoot = ''
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($PortableRoot)) {
    $PortableRoot = Read-Host 'Path to extracted portable folder'
}
$PortableRoot = (Resolve-Path -LiteralPath $PortableRoot).Path
$release = Join-Path $PortableRoot 'build\Release'
$correct = Join-Path $release 'jitsi-ndi-native.exe'
$wrong = Join-Path $release 'jitsi-ndi-natove.exe'
if ((-not (Test-Path -LiteralPath $correct)) -and (Test-Path -LiteralPath $wrong)) {
    Rename-Item -LiteralPath $wrong -NewName 'jitsi-ndi-native.exe'
    Write-Host '[v74b] Renamed typo exe to jitsi-ndi-native.exe' -ForegroundColor Green
}
Get-ChildItem -LiteralPath $PortableRoot -Include '*.ps1','*.txt','*.json','*.config' -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        $t = [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8)
        if ($t.Contains('jitsi-ndi-natove')) {
            $t = $t.Replace('jitsi-ndi-natove', 'jitsi-ndi-native')
            [System.IO.File]::WriteAllText($_.FullName, $t, (New-Object System.Text.UTF8Encoding($false)))
            Write-Host ("[v74b] Patched typo in " + $_.FullName)
        }
    } catch {}
}
Write-Host '[v74b] Done. Try JitsiNDI.exe again.' -ForegroundColor Green
