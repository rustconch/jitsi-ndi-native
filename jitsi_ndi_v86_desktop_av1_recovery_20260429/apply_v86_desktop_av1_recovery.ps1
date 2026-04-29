$ErrorActionPreference = "Stop"

$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $patchDir "..")
$srcDir = Join-Path $repoRoot "src"

if (!(Test-Path $srcDir)) {
    throw "src directory not found. Run this script from the extracted patch folder inside the jitsi-ndi-native repo."
}

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupDir = Join-Path $repoRoot ("backup_v86_desktop_av1_recovery_" + $stamp)
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

$files = @(
    "NativeWebRTCAnswerer.cpp",
    "Av1RtpFrameAssembler.cpp",
    "Av1RtpFrameAssembler.h"
)

foreach ($file in $files) {
    $target = Join-Path $srcDir $file
    $patch = Join-Path $patchDir $file

    if (!(Test-Path $patch)) {
        throw "Patch file missing: $patch"
    }

    if (Test-Path $target) {
        Copy-Item -Force $target (Join-Path $backupDir $file)
    }

    Copy-Item -Force $patch $target
}

$restoreScript = Join-Path $backupDir "restore_v86_backup.ps1"
@"
`$ErrorActionPreference = "Stop"
`$backupDir = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$repoRoot = Resolve-Path (Join-Path `$backupDir "..")
`$srcDir = Join-Path `$repoRoot "src"
`$files = @("NativeWebRTCAnswerer.cpp", "Av1RtpFrameAssembler.cpp", "Av1RtpFrameAssembler.h")
foreach (`$file in `$files) {
    `$backup = Join-Path `$backupDir `$file
    `$target = Join-Path `$srcDir `$file
    if (Test-Path `$backup) {
        Copy-Item -Force `$backup `$target
    }
}
Write-Host "Restored v86 backup from `$backupDir"
"@ | Set-Content -Encoding ASCII $restoreScript

Write-Host "Applied v86 desktop AV1 recovery patch. Backup: $backupDir"
Write-Host "Now rebuild with: .\\rebuild_with_dav1d_v21.ps1"
