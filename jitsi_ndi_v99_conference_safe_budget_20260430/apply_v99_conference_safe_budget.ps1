$ErrorActionPreference = "Stop"

$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $patchDir
$srcDir = Join-Path $repoRoot "src"

if (!(Test-Path $srcDir)) {
    throw "src directory not found. Extract this patch into the jitsi-ndi-native repository root."
}

$files = @(
    "Av1RtpFrameAssembler.cpp",
    "Av1RtpFrameAssembler.h",
    "FfmpegMediaDecoder.cpp",
    "FfmpegMediaDecoder.h",
    "NativeWebRTCAnswerer.cpp",
    "NativeWebRTCAnswerer.h",
    "PerParticipantNdiRouter.cpp",
    "PerParticipantNdiRouter.h",
    "main.cpp"
)

$backupDir = Join-Path $repoRoot ("backup_v99_conference_safe_budget_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
New-Item -ItemType Directory -Path $backupDir | Out-Null

foreach ($file in $files) {
    $source = Join-Path $patchDir $file
    $target = Join-Path $srcDir $file

    if (!(Test-Path $source)) {
        throw "Patch file missing: $source"
    }
    if (!(Test-Path $target)) {
        throw "Target file missing: $target"
    }

    Copy-Item -Force $target (Join-Path $backupDir $file)
    Copy-Item -Force $source $target
}

Write-Host "v99 conference-safe budget patch applied. Backup:" $backupDir
Write-Host "Now rebuild with: .\rebuild_with_dav1d_v21.ps1"
