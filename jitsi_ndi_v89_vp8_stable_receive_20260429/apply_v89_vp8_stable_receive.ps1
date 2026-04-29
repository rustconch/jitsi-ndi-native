$ErrorActionPreference = "Stop"

$root = (Get-Location).Path
$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$srcDir = Join-Path $root "src"

if (!(Test-Path $srcDir)) {
    throw "src folder not found. Run this script from the repository root: D:\MEDIA\Desktop\jitsi-ndi-native"
}

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"

function Backup-File($path) {
    if (Test-Path $path) {
        Copy-Item -Force $path ($path + ".bak_v89_" + $stamp)
    }
}

# 1) Native WebRTC answerer: VP8-only SDP/answer, same screen 1080p/30fps and camera 720p/30fps constraints.
$nativeDst = Join-Path $srcDir "NativeWebRTCAnswerer.cpp"
$nativeSrc = Join-Path $patchDir "NativeWebRTCAnswerer.cpp"
if (!(Test-Path $nativeSrc)) {
    throw "Patch file NativeWebRTCAnswerer.cpp not found in patch folder"
}
Backup-File $nativeDst
Copy-Item -Force $nativeSrc $nativeDst

# 2) Jingle accept: do not advertise AV1 in session-accept XML.
$jinglePath = Join-Path $srcDir "JingleSession.cpp"
if (Test-Path $jinglePath) {
    Backup-File $jinglePath
    $txt = Get-Content -Raw -Encoding UTF8 $jinglePath
    $txt = $txt -replace 'return\s+codecNameLower\s*==\s*"av1"\s*\|\|\s*codecNameLower\s*==\s*"vp8"\s*;', 'return codecNameLower == "vp8";'
    $txt = $txt -replace 'return\s+codecNameLower\s*==\s*"vp8"\s*\|\|\s*codecNameLower\s*==\s*"av1"\s*;', 'return codecNameLower == "vp8";'
    Set-Content -Encoding UTF8 -NoNewline -Path $jinglePath -Value $txt
}

# 3) MUC presence: tell Jitsi that this endpoint wants VP8, not AV1.
$signalingPath = Join-Path $srcDir "JitsiSignaling.cpp"
if (Test-Path $signalingPath) {
    Backup-File $signalingPath
    $txt = Get-Content -Raw -Encoding UTF8 $signalingPath
    $txt = $txt -replace '<jitsi_participant_codecList>av1,vp8,opus</jitsi_participant_codecList>', '<jitsi_participant_codecList>vp8,opus</jitsi_participant_codecList>'
    $txt = $txt -replace '<jitsi_participant_codecList>vp8,av1,opus</jitsi_participant_codecList>', '<jitsi_participant_codecList>vp8,opus</jitsi_participant_codecList>'
    $txt = $txt -replace 'jitsi_participant_codecList>av1,vp8,opus<', 'jitsi_participant_codecList>vp8,opus<'
    Set-Content -Encoding UTF8 -NoNewline -Path $signalingPath -Value $txt
}

Write-Host "v89 VP8-stable receive patch applied. Rebuild with: .\rebuild_with_dav1d_v21.ps1"
