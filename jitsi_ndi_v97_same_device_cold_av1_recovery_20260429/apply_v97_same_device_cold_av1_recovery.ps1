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

$backupDir = Join-Path $repoRoot ("backup_v97_same_device_cold_av1_recovery_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

foreach ($file in $required) {
    $target = Join-Path $srcDir $file
    if (Test-Path $target) {
        Copy-Item -Force $target (Join-Path $backupDir $file)
    }
    Copy-Item -Force (Join-Path $patchDir $file) $target
}

# Keep observer/silent join. Do not replace the whole JitsiSignaling.cpp,
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

Write-Host "v97 applied. Backup:" $backupDir
Write-Host "Changes: v96 stable base plus source-local cold AV1 recovery for same-device streams that show producedFrames=1 decodedFrames=0. No global reconnect. Camera/screen remain 1080p/30fps. Observer-safe constraints remain enabled."
Write-Host "Now rebuild with: .\rebuild_with_dav1d_v21.ps1"
