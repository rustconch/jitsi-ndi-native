$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backup = Join-Path $root (".jnn_patch_backups\restore_minimal_v56_" + $stamp)
New-Item -ItemType Directory -Path $backup -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $backup "src") -Force | Out-Null

$guiSrc = Join-Path $PSScriptRoot "JitsiNdiGui.ps1"
$guiDst = Join-Path $root "JitsiNdiGui.ps1"
if (Test-Path $guiDst) { Copy-Item -Force $guiDst (Join-Path $backup "JitsiNdiGui.ps1") }
Copy-Item -Force $guiSrc $guiDst
Write-Host "[v56] Installed minimal safe GUI: --room only, no --nick, no NDI scanning."

$signaling = Join-Path $root "src\JitsiSignaling.cpp"
if (Test-Path $signaling) {
    Copy-Item -Force $signaling (Join-Path $backup "src\JitsiSignaling.cpp")
    $text = [System.IO.File]::ReadAllText($signaling)
    $bad = 'return bareMucJid() + "/jitsi-ndi-native";'
    $good = 'return bareMucJid() + "/" + cfg_.nick;'
    if ($text.Contains($bad)) {
        $text = $text.Replace($bad, $good)
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($signaling, $text, $utf8NoBom)
        Write-Host "[v56] Reverted v55 native nick/resource change in src\JitsiSignaling.cpp."
        Write-Host "[v56] Rebuild required: .\rebuild_with_dav1d_v21.ps1"
    } else {
        Write-Host "[v56] Native nick/resource line already looks unchanged. Rebuild may not be needed."
    }
} else {
    Write-Warning "[v56] src\JitsiSignaling.cpp not found. GUI installed only."
}

Write-Host "[v56] Backup: $backup"
