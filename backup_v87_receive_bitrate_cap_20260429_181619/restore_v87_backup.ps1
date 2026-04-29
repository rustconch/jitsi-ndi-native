$ErrorActionPreference = "Stop"
$backupDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $backupDir "..")
$srcDir = Join-Path $repoRoot "src"
$files = @("NativeWebRTCAnswerer.cpp", "Av1RtpFrameAssembler.cpp", "Av1RtpFrameAssembler.h")
foreach ($file in $files) {
    $backup = Join-Path $backupDir $file
    $target = Join-Path $srcDir $file
    if (Test-Path $backup) {
        Copy-Item -Force $backup $target
    }
}
Write-Host "Restored v87 backup from $backupDir"
