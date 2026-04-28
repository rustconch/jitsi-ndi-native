$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$targets = @("JitsiNdiGui.ps1", "src\JitsiSignaling.cpp", "src\main.cpp")
foreach ($rel in $targets) {
    $dst = Join-Path $root $rel
    $dir = Split-Path -Parent $dst
    $name = Split-Path -Leaf $dst
    $backup = Get-ChildItem -Path $dir -Filter ($name + ".bak_v59b_*") -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($backup) {
        Copy-Item -Force $backup.FullName $dst
        Write-Host "Restored $rel from $($backup.Name)"
    } else {
        Write-Host "No v59b backup found for $rel"
    }
}
