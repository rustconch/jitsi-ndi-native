# Jitsi NDI Native - portable packager v74d safe EXE-only
$ErrorActionPreference = 'Stop'
function Info($m) { Write-Host "[v74d] $m" }
function Warn($m) { Write-Host "[v74d][WARN] $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "[v74d][ERROR] $m" -ForegroundColor Red; exit 1 }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
Set-Location $repoRoot

$templateGui = Join-Path $scriptDir 'JitsiNdiGui.PortableV74d.ps1'
$releaseDir = Join-Path $repoRoot 'build\Release'
$nativeExe = Join-Path $releaseDir 'jitsi-ndi-native.exe'

if (-not (Test-Path $templateGui)) { Fail "Template GUI not found: $templateGui" }
if (-not (Test-Path $nativeExe)) { Fail "Native exe not found: $nativeExe. Build Release first." }

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$distDir = Join-Path $repoRoot 'dist'
New-Item -ItemType Directory -Force -Path $distDir | Out-Null
$portableRoot = Join-Path $distDir "JitsiNDI_Portable_v74d_$stamp"
$portableRelease = Join-Path $portableRoot 'build\Release'
New-Item -ItemType Directory -Force -Path $portableRelease | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $portableRoot 'logs') | Out-Null
Info "Portable root: $portableRoot"

Copy-Item -Force $templateGui (Join-Path $portableRoot 'JitsiNdiGui.ps1')
if (Test-Path (Join-Path $repoRoot 'gui')) {
    Copy-Item -Recurse -Force (Join-Path $repoRoot 'gui') (Join-Path $portableRoot 'gui')
    Info "Copied gui folder"
}

Info "Copying full build\Release"
Copy-Item -Recurse -Force (Join-Path $releaseDir '*') $portableRelease
Copy-Item -Force $nativeExe (Join-Path $portableRelease 'jitsi-ndi-native.exe')
Info "Native exe force-copied to portable build\Release"

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
                Copy-Item -Force $_.FullName (Join-Path $portableRelease $_.Name)
                [void]$copiedDlls.Add($_.Name.ToLowerInvariant())
            }
        } catch {}
    }
}
Info ("Runtime DLL names copied/confirmed: " + $copiedDlls.Count)

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
    & $cscCandidates[0] /nologo /target:winexe /out:(Join-Path $portableRoot 'JitsiNDI.exe') /reference:System.Windows.Forms.dll $launcherCs | Out-Host
    Remove-Item -Force $launcherCs -ErrorAction SilentlyContinue
    Info "Built JitsiNDI.exe launcher"
} else {
    Fail "csc.exe not found; cannot build required JitsiNDI.exe launcher."
}

@'
@echo off
setlocal
cd /d "%~dp0"
set "PATH=%~dp0build\Release;%~dp0;%PATH%"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0JitsiNdiGui.ps1"
'@ | Set-Content -Encoding ASCII -Path (Join-Path $portableRoot 'START_JITSI_NDI.cmd')

@'
@echo off
setlocal
cd /d "%~dp0"
set "PATH=%~dp0build\Release;%~dp0;%PATH%"
if not exist logs mkdir logs
set /p ROOM=Room or full Jitsi link: 
set /p NICK=Nick (empty for default): 
if "%NICK%"=="" (
  "%~dp0build\Release\jitsi-ndi-native.exe" --room "%ROOM%" 1>"%~dp0logs\native_video_diag.log" 2>&1
) else (
  "%~dp0build\Release\jitsi-ndi-native.exe" --room "%ROOM%" --nick "%NICK%" 1>"%~dp0logs\native_video_diag.log" 2>&1
)
echo.
echo Native exited. Log: %~dp0logs\native_video_diag.log
pause
'@ | Set-Content -Encoding ASCII -Path (Join-Path $portableRoot 'START_NATIVE_VIDEO_DIAG.cmd')

@'
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$rel = Join-Path $root 'build\Release'
Write-Host "Jitsi NDI Portable v74d check"
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
Write-Host "Recent native logs:"
Get-ChildItem -Path (Join-Path $root 'logs') -Filter 'jitsi-ndi-native_*.log' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 5 Name,Length,LastWriteTime |
    Format-Table -AutoSize
Write-Host ""
Write-Host "If video freezes again, send the newest logs\jitsi-ndi-native_*.log around the freeze time."
'@ | Set-Content -Encoding ASCII -Path (Join-Path $portableRoot 'CHECK_PORTABLE_VIDEO.ps1')

@'
Jitsi NDI Portable v74d safe

Main launch:
  JitsiNDI.exe

What changed from v70:
  - removed video watchdog;
  - removed automatic native restart;
  - GUI does not read native stdout/stderr directly;
  - native is started by a hidden PowerShell runner;
  - native stdout/stderr is redirected to logs\jitsi-ndi-native_YYYYMMDD_HHMMSS.log.
  - no START_*.cmd launcher is created; JitsiNDI.exe is the only main launcher.

If video freezes:
  1) do not rely on GUI watchdog; stop/start manually;
  2) send the newest logs\jitsi-ndi-native_*.log around the freeze time.
'@ | Set-Content -Encoding ASCII -Path (Join-Path $portableRoot 'README_PORTABLE_V74D.txt')

$stageNativeExe = Join-Path $portableRelease 'jitsi-ndi-native.exe'
$stageLauncher = Join-Path $portableRoot 'JitsiNDI.exe'
if (-not (Test-Path $stageNativeExe)) { Fail "Portable sanity failed: missing $stageNativeExe" }
if (-not (Test-Path $stageLauncher)) { Fail "Portable sanity failed: missing $stageLauncher" }
$cmdLaunchers = Get-ChildItem -Path $portableRoot -Filter '*.cmd' -File -ErrorAction SilentlyContinue
if ($cmdLaunchers) { Fail 'Portable sanity failed: CMD launcher exists, but this package must be EXE-only.' }
Info "Sanity OK: native exe and JitsiNDI.exe are present; no CMD launchers."

$zipPath = Join-Path $distDir ("JitsiNDI_Portable_v74d_$stamp.zip")
if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
Compress-Archive -Force -Path (Join-Path $portableRoot '*') -DestinationPath $zipPath
Info "Created: $zipPath"
Info "Run on another PC: extract and start JitsiNDI.exe"
