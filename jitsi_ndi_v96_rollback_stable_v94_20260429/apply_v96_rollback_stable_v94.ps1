$ErrorActionPreference = "Stop"

$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $patchDir "..")
$srcDir = Join-Path $repoRoot "src"

if (!(Test-Path $srcDir)) {
    throw "src directory not found. Extract this patch folder into the repo root and run the script from there."
}

$required = @(
    "NativeWebRTCAnswerer.cpp",
    "NativeWebRTCAnswerer.h",
    "main.cpp",
    "PerParticipantNdiRouter.cpp",
    "PerParticipantNdiRouter.h",
    "FfmpegMediaDecoder.cpp",
    "FfmpegMediaDecoder.h",
    "Av1RtpFrameAssembler.cpp",
    "Av1RtpFrameAssembler.h"
)

foreach ($file in $required) {
    $patchFile = Join-Path $patchDir $file
    if (!(Test-Path $patchFile)) {
        throw "Patch file missing: $file"
    }
}

$backupDir = Join-Path $repoRoot ("backup_v96_rollback_stable_v94_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

foreach ($file in $required) {
    $target = Join-Path $srcDir $file
    if (Test-Path $target) {
        Copy-Item -Force $target (Join-Path $backupDir $file)
    }
    Copy-Item -Force (Join-Path $patchDir $file) $target
}

# Keep the observer/silent join tweak. Do not replace the whole JitsiSignaling.cpp,
# because local GUI/name changes may exist in the user's tree.
$jitsiFile = Join-Path $srcDir "JitsiSignaling.cpp"
if (Test-Path $jitsiFile) {
    Copy-Item -Force $jitsiFile (Join-Path $backupDir "JitsiSignaling.cpp")
    $txt = Get-Content -Raw -Encoding UTF8 $jitsiFile
    $txt = $txt.Replace("<property name='startSilent' value='false'/>", "<property name='startSilent' value='true'/>")
    $txt = $txt.Replace("<property name='startAudioMuted' value='false'/>", "<property name='startAudioMuted' value='true'/>")
    $txt = $txt.Replace("<property name='startVideoMuted' value='false'/>", "<property name='startVideoMuted' value='true'/>")
    Set-Content -Encoding UTF8 -NoNewline -Path $jitsiFile -Value $txt
}

Write-Host "v96 applied. Backup:" $backupDir
Write-Host "Changes: rollback to v94 stable behavior; removes v95 same-device 720p cap, removes forced NDI resize clamp, restores safer queue sizes and safer AV1 decoder reset thresholds. Keeps observer-safe constraints, no legacy LastNChangedEvent, silent/muted conference request, screen/camera 1080p/30fps."
Write-Host "Now rebuild with: .\rebuild_with_dav1d_v21.ps1"
