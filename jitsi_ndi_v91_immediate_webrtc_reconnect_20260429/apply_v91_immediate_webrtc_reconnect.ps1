$ErrorActionPreference = 'Stop'

$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $patchDir '..')
$srcDir = Join-Path $repoRoot 'src'

if (-not (Test-Path $srcDir)) {
    throw "src directory not found. Run this script from the extracted patch inside the jitsi-ndi-native repo root."
}

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$files = @(
    'NativeWebRTCAnswerer.cpp',
    'NativeWebRTCAnswerer.h',
    'JitsiSignaling.cpp',
    'JitsiSignaling.h',
    'main.cpp',
    'Av1RtpFrameAssembler.cpp',
    'Av1RtpFrameAssembler.h',
    'NDISender.cpp',
    'NDISender.h'
)

foreach ($file in $files) {
    $from = Join-Path $patchDir $file
    $to = Join-Path $srcDir $file

    if (-not (Test-Path $from)) {
        throw "Patch file missing: $file"
    }

    if (Test-Path $to) {
        Copy-Item -Force $to ($to + ".bak_v91_" + $timestamp)
    }

    Copy-Item -Force $from $to
    Write-Host "Patched src/$file"
}

Write-Host "v91 applied: AV1/NDI v90 kept, screen 1080p/30fps kept, immediate WebRTC reconnect added."
