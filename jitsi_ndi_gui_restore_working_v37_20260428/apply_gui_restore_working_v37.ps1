$ErrorActionPreference = "Stop"
$patchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $patchDir
$src = Join-Path $patchDir "JitsiNdiGui.ps1"
$dst = Join-Path $repoRoot "JitsiNdiGui.ps1"
$settings = Join-Path $repoRoot "JitsiNdiGui.settings.json"
$backupRoot = Join-Path $repoRoot ".jnn_patch_backups"
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupDir = Join-Path $backupRoot ("gui_restore_v37_" + $stamp)
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
if (-not (Test-Path $src)) { throw ("Patch file not found: " + $src) }
if (Test-Path $dst) { Copy-Item -Force $dst (Join-Path $backupDir "JitsiNdiGui.ps1") }
if (Test-Path $settings) {
    Copy-Item -Force $settings (Join-Path $backupDir "JitsiNdiGui.settings.json")
    Rename-Item -Force $settings ("JitsiNdiGui.settings.json.disabled_v37_" + $stamp)
}
Copy-Item -Force $src $dst
Write-Host "GUI v37 restore applied. Native/WebRTC/NDI files were not changed."
Write-Host ("Backup: " + $backupDir)
Write-Host "Old JitsiNdiGui.settings.json was disabled if it existed."
