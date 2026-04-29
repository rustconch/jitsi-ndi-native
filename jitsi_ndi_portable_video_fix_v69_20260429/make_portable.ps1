# Jitsi NDI Native - portable packager v69 video runtime fix
# Run from repo root after extracting this folder.
$ErrorActionPreference = 'Stop'

function Info($m) { Write-Host "[v69] $m" }
function Warn($m) { Write-Host "[v69][WARN] $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "[v69][ERROR] $m" -ForegroundColor Red; exit 1 }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
Set-Location $repoRoot

$gui = Join-Path $repoRoot 'JitsiNdiGui.ps1'
$releaseDir = Join-Path $repoRoot 'build\Release'
$nativeExe = Join-Path $releaseDir 'jitsi-ndi-native.exe'

if (-not (Test-Path $gui)) { Fail "JitsiNdiGui.ps1 not found in repo root: $repoRoot" }
if (-not (Test-Path $nativeExe)) { Fail "Native exe not found: $nativeExe" }

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$distDir = Join-Path $repoRoot 'dist'
New-Item -ItemType Directory -Force -Path $distDir | Out-Null
$portableRoot = Join-Path $distDir "JitsiNDI_Portable_v69_video_full_$stamp"
$portableRelease = Join-Path $portableRoot 'build\Release'
New-Item -ItemType Directory -Force -Path $portableRelease | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $portableRoot 'logs') | Out-Null

Info "Portable root: $portableRoot"

# Copy GUI and optional gui resources.
Copy-Item -Force $gui (Join-Path $portableRoot 'JitsiNdiGui.ps1')
if (Test-Path (Join-Path $repoRoot 'gui')) {
    Copy-Item -Recurse -Force (Join-Path $repoRoot 'gui') (Join-Path $portableRoot 'gui')
    Info "Copied gui folder"
}

# Copy the whole Release directory. This is deliberately broader than v66/v68.
Info "Copying full build\\Release"
Copy-Item -Recurse -Force (Join-Path $releaseDir '*') $portableRelease

# Additional runtime DLL collection.
$dllPatterns = @(
    'Processing.NDI*.dll',
    'av*.dll','sw*.dll','postproc*.dll',
    'dav1d*.dll','libdav1d*.dll',
    'vpx*.dll','libvpx*.dll',
    'aom*.dll','libaom*.dll','SvtAv1*.dll','svt*.dll',
    'x264*.dll','libx264*.dll','x265*.dll','libx265*.dll',
    'opus*.dll','libopus*.dll',
    'ssl*.dll','crypto*.dll','libssl*.dll','libcrypto*.dll',
    'zlib*.dll','zstd*.dll','bz2*.dll','lzma*.dll','brotli*.dll',
    'vcruntime*.dll','msvcp*.dll','concrt*.dll','api-ms-win-*.dll',
    'libgcc*.dll','libstdc++*.dll','libwinpthread*.dll'
)

$searchRoots = @(
    $releaseDir,
    (Join-Path $repoRoot 'build'),
    (Join-Path $repoRoot 'vcpkg_installed\x64-windows\bin'),
    (Join-Path $repoRoot 'build\vcpkg_installed\x64-windows\bin'),
    (Join-Path $repoRoot 'vcpkg\installed\x64-windows\bin'),
    (Join-Path $repoRoot 'out'),
    (Join-Path $repoRoot 'bin')
) | Where-Object { Test-Path $_ }

$copiedDlls = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($root in $searchRoots) {
    Info "Scanning DLLs: $root"
    foreach ($pattern in $dllPatterns) {
        try {
            Get-ChildItem -Path $root -Filter $pattern -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                $dest = Join-Path $portableRelease $_.Name
                Copy-Item -Force $_.FullName $dest
                [void]$copiedDlls.Add($_.Name.ToLowerInvariant())
            }
        } catch { }
    }
}
Info ("Runtime DLL names copied/confirmed: " + $copiedDlls.Count)

# Try to copy NDI runtime from common install locations if it was not in Release.
$ndiNames = @('Processing.NDI.Lib.x64.dll','Processing.NDI.Lib.x86.dll')
$commonNdiRoots = @(
    ${env:NDI_RUNTIME_DIR_V6}, ${env:NDI_RUNTIME_DIR_V5}, ${env:NDI_RUNTIME_DIR},
    'C:\Program Files\NDI\NDI 6 Runtime\v6',
    'C:\Program Files\NDI\NDI 5 Runtime\v5',
    'C:\Program Files\NewTek\NDI 4 Runtime\v4',
    'C:\Program Files\NDI\NDI 6 Tools\Runtime',
    'C:\Program Files\NDI\NDI 5 Tools\Runtime'
) | Where-Object { $_ -and (Test-Path $_) }
foreach ($r in $commonNdiRoots) {
    foreach ($n in $ndiNames) {
        Get-ChildItem -Path $r -Filter $n -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object {
            Copy-Item -Force $_.FullName (Join-Path $portableRelease $_.Name)
            Info "Copied NDI runtime: $($_.FullName)"
        }
    }
}

# Patch portable GUI with runtime PATH bootstrap. Keep ASCII/UTF-8 without BOM.
$portableGui = Join-Path $portableRoot 'JitsiNdiGui.ps1'
$guiText = [System.IO.File]::ReadAllText($portableGui)
$bootstrap = @'
# v69 portable runtime bootstrap
try {
    $script:PortableRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    $script:PortableReleaseDir = Join-Path $script:PortableRoot 'build\Release'
    if (Test-Path $script:PortableReleaseDir) {
        $env:PATH = "$script:PortableReleaseDir;$script:PortableRoot;$env:PATH"
    }
} catch {}
# /v69 portable runtime bootstrap

'@
if ($guiText -notmatch 'v69 portable runtime bootstrap') {
    $guiText = $bootstrap + $guiText
}
# Replace old absolute repo path if present.
$escapedRepo = [regex]::Escape($repoRoot)
$guiText = [regex]::Replace($guiText, $escapedRepo.Replace('\\','\\'), '$PSScriptRoot')
# Best-effort force portable native path if the old Desktop path is hard-coded.
$guiText = $guiText -replace '[A-Za-z]:\\[^\r\n"'']*jitsi-ndi-native\\build\\Release\\jitsi-ndi-native\.exe', '$PSScriptRoot\build\Release\jitsi-ndi-native.exe'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($portableGui, $guiText, $utf8NoBom)
Info "Patched portable GUI PATH bootstrap"

# Create hidden EXE launcher for the GUI.
$launcherCs = Join-Path $portableRoot 'JitsiNDI.Launcher.cs'
@'
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

static class Program {
    [STAThread]
    static void Main() {
        string baseDir = AppDomain.CurrentDomain.BaseDirectory;
        string ps1 = Path.Combine(baseDir, "JitsiNdiGui.ps1");
        if (!File.Exists(ps1)) {
            MessageBox.Show("JitsiNdiGui.ps1 was not found next to JitsiNDI.exe", "Jitsi NDI", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }
        string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
        if (!File.Exists(ps)) ps = "powershell.exe";
        var p = new ProcessStartInfo();
        p.FileName = ps;
        p.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + ps1 + "\"";
        p.WorkingDirectory = baseDir;
        p.UseShellExecute = false;
        p.CreateNoWindow = true;
        p.EnvironmentVariables["PATH"] = Path.Combine(baseDir, "build", "Release") + ";" + baseDir + ";" + p.EnvironmentVariables["PATH"];
        try { Process.Start(p); }
        catch (Exception ex) { MessageBox.Show(ex.ToString(), "Jitsi NDI launch failed", MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }
}
'@ | Set-Content -Encoding ASCII -Path $launcherCs

$cscCandidates = @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
) | Where-Object { Test-Path $_ }
if ($cscCandidates.Count -gt 0) {
    $csc = $cscCandidates[0]
    & $csc /nologo /target:winexe /out:(Join-Path $portableRoot 'JitsiNDI.exe') /reference:System.Windows.Forms.dll $launcherCs | Out-Host
    Remove-Item -Force $launcherCs -ErrorAction SilentlyContinue
    Info "Built JitsiNDI.exe launcher"
} else {
    Warn "csc.exe not found; EXE launcher not built. START_JITSI_NDI.cmd will still be created."
}

# Hidden CMD fallback.
@'
@echo off
setlocal
cd /d "%~dp0"
set "PATH=%~dp0build\Release;%~dp0;%PATH%"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0JitsiNdiGui.ps1"
'@ | Set-Content -Encoding ASCII -Path (Join-Path $portableRoot 'START_JITSI_NDI.cmd')

# Visible native diagnostic launcher. Useful when video freezes.
@'
@echo off
setlocal
cd /d "%~dp0"
set "PATH=%~dp0build\Release;%~dp0;%PATH%"
if not exist logs mkdir logs
set /p ROOM=Room or full Jitsi link: 
set /p NICK=Nick (empty for default): 
set "ROOMARG=%ROOM%"
if "%NICK%"=="" (
  "%~dp0build\Release\jitsi-ndi-native.exe" --room "%ROOMARG%" 1>"%~dp0logs\native_video_diag.log" 2>&1
) else (
  "%~dp0build\Release\jitsi-ndi-native.exe" --room "%ROOMARG%" --nick "%NICK%" 1>"%~dp0logs\native_video_diag.log" 2>&1
)
echo.
echo Native exited. Log: %~dp0logs\native_video_diag.log
pause
'@ | Set-Content -Encoding ASCII -Path (Join-Path $portableRoot 'START_NATIVE_VIDEO_DIAG.cmd')

# Portable video dependency checker.
@'
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$rel = Join-Path $root 'build\Release'
Write-Host "Jitsi NDI Portable v69 video check"
Write-Host "Root: $root"
Write-Host "Release: $rel"
Write-Host ""
$must = @(
 'jitsi-ndi-native.exe',
 'Processing.NDI.Lib.x64.dll',
 'avcodec*.dll',
 'avutil*.dll',
 'swscale*.dll',
 'swresample*.dll',
 'dav1d*.dll',
 'libdav1d*.dll',
 'vcruntime140.dll',
 'vcruntime140_1.dll',
 'msvcp140.dll'
)
foreach ($m in $must) {
    $hit = Get-ChildItem -Path $rel -Filter $m -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { Write-Host ("OK   " + $hit.Name) -ForegroundColor Green }
    else { Write-Host ("MISS " + $m) -ForegroundColor Yellow }
}
Write-Host ""
Write-Host "FFmpeg/video related DLLs:"
Get-ChildItem -Path $rel -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(av|sw|dav1d|libdav1d|vpx|libvpx|aom|libaom|Svt|x264|x265|libx264|libx265|opus|libopus)' } | Sort-Object Name | Select-Object Name,Length | Format-Table -AutoSize
Write-Host ""
Write-Host "If video freezes, run START_NATIVE_VIDEO_DIAG.cmd and send logs\native_video_diag.log around lines containing:"
Write-Host "FfmpegMediaDecoder, AV1, VP8, NDI video frame sent, RTP sequence gap, decoder"
'@ | Set-Content -Encoding ASCII -Path (Join-Path $portableRoot 'CHECK_PORTABLE_VIDEO.ps1')

# Readme.
@'
Jitsi NDI Portable v69 video runtime fix

Main launch:
  JitsiNDI.exe

Fallback launch:
  START_JITSI_NDI.cmd

If audio works but video freezes:
  1) Run powershell -ExecutionPolicy Bypass -File .\CHECK_PORTABLE_VIDEO.ps1
  2) Check that FFmpeg/video DLLs are present: avcodec, avutil, swscale, swresample, dav1d/libdav1d.
  3) Run START_NATIVE_VIDEO_DIAG.cmd, reproduce the freeze, then open logs\native_video_diag.log.

This package does not change Jitsi native code. It only packages the complete runtime and adds diagnostics.
'@ | Set-Content -Encoding ASCII -Path (Join-Path $portableRoot 'README_PORTABLE_V69.txt')

# Zip it.
$zipPath = Join-Path $distDir ("JitsiNDI_Portable_v69_video_full_$stamp.zip")
if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
Compress-Archive -Force -Path (Join-Path $portableRoot '*') -DestinationPath $zipPath
Info "Created: $zipPath"
Info "Run on another PC: extract and start JitsiNDI.exe"
