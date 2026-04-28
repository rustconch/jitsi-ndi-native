$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backup = Join-Path $root (".jnn_patch_backups\gui_minimal_nick_link_v55_" + $stamp)
New-Item -ItemType Directory -Path $backup -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $backup "src") -Force | Out-Null

$guiSrc = Join-Path $PSScriptRoot "JitsiNdiGui.ps1"
$guiDst = Join-Path $root "JitsiNdiGui.ps1"
if (Test-Path $guiDst) { Copy-Item -Force $guiDst (Join-Path $backup "JitsiNdiGui.ps1") }
Copy-Item -Force $guiSrc $guiDst

# Native nickname safety fix: keep MUC resource technical, use --nick only for displayed <nick>.
# This prevents spaces/non-safe nicknames from breaking Jitsi media routing.
$signaling = Join-Path $root "src\JitsiSignaling.cpp"
if (Test-Path $signaling) {
    Copy-Item -Force $signaling (Join-Path $backup "src\JitsiSignaling.cpp")
    $text = [System.IO.File]::ReadAllText($signaling)
    $old = 'return bareMucJid() + "/" + cfg_.nick;'
    $new = 'return bareMucJid() + "/jitsi-ndi-native";'
    if ($text.Contains($old)) {
        $text = $text.Replace($old, $new)
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($signaling, $text, $utf8NoBom)
        Write-Host "[v55] Patched src\JitsiSignaling.cpp: MUC resource is now technical/stable."
    } elseif ($text.Contains($new)) {
        Write-Host "[v55] src\JitsiSignaling.cpp already has the stable MUC resource fix."
    } else {
        Write-Warning "[v55] Could not find expected mucJid line. GUI was installed, but native nick fix was not applied."
    }
} else {
    Write-Warning "[v55] src\JitsiSignaling.cpp not found. GUI was installed only."
}

Write-Host "[v55] Installed minimal GUI. Backup: $backup"
Write-Host "[v55] Rebuild native exe to activate nickname fix: .\rebuild_with_dav1d_v21.ps1"
