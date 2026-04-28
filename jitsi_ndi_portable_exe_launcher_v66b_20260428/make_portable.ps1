# Jitsi NDI Native - portable EXE launcher packager v66
# Run from repository root or from the extracted packager folder inside repository root.
# This script creates a portable ZIP with JitsiNDI.exe launcher.

$ErrorActionPreference = 'Stop'

function Write-Step($msg) {
    Write-Host "[v66] $msg"
}

function Resolve-RepoRoot {
    $scriptDir = Split-Path -Parent $MyInvocation.ScriptName
    if ([string]::IsNullOrWhiteSpace($scriptDir)) { $scriptDir = (Get-Location).Path }
    $candidates = @(
        (Get-Location).Path,
        $scriptDir,
        (Split-Path -Parent $scriptDir)
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

    foreach ($c in $candidates) {
        if ((Test-Path (Join-Path $c 'JitsiNdiGui.ps1')) -and (Test-Path (Join-Path $c 'src'))) {
            return (Resolve-Path $c).Path
        }
    }
    throw 'Repository root not found. Put this packager folder inside jitsi-ndi-native root and run again.'
}

function Find-NativeExe($root) {
    $candidates = @(
        (Join-Path $root 'build\Release\jitsi-ndi-native.exe'),
        (Join-Path $root 'build-ndi\Release\jitsi-ndi-native.exe'),
        (Join-Path $root 'build\RelWithDebInfo\jitsi-ndi-native.exe'),
        (Join-Path $root 'build-ndi\RelWithDebInfo\jitsi-ndi-native.exe'),
        (Join-Path $root 'jitsi-ndi-native.exe')
    )
    foreach ($p in $candidates) {
        if (Test-Path $p) { return (Resolve-Path $p).Path }
    }
    throw 'Native exe not found. Build the project first.'
}

function Copy-IfExists($src, $dst) {
    if (Test-Path $src) {
        $parent = Split-Path -Parent $dst
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        Copy-Item -Force $src $dst
        return $true
    }
    return $false
}

function Build-LauncherExe($outExe) {
    $code = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

namespace JitsiNDIPortableLauncher {
    internal static class Program {
        [STAThread]
        private static void Main(string[] args) {
            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            string ps1 = Path.Combine(baseDir, "JitsiNdiGui.ps1");
            if (!File.Exists(ps1)) {
                MessageBox.Show(
                    "JitsiNdiGui.ps1 was not found near JitsiNDI.exe.",
                    "Jitsi NDI",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                return;
            }

            string winDir = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            string powershell = Path.Combine(winDir, "System32\\WindowsPowerShell\\v1.0\\powershell.exe");
            if (!File.Exists(powershell)) {
                powershell = "powershell.exe";
            }

            string argLine = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + ps1 + "\"";

            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = powershell;
            psi.Arguments = argLine;
            psi.WorkingDirectory = baseDir;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WindowStyle = ProcessWindowStyle.Hidden;

            try {
                Process.Start(psi);
            } catch (Exception ex) {
                MessageBox.Show(
                    "Failed to start Jitsi NDI GUI.\r\n\r\n" + ex.Message,
                    "Jitsi NDI",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
            }
        }
    }
}
'@

    $tmpSrc = [System.IO.Path]::ChangeExtension($outExe, '.cs')
    Set-Content -Path $tmpSrc -Value $code -Encoding ASCII

    try {
        Add-Type -TypeDefinition $code -ReferencedAssemblies @('System.Windows.Forms.dll','System.Drawing.dll') -OutputAssembly $outExe -OutputType WindowsApplication -Language CSharp
        Remove-Item -Force $tmpSrc -ErrorAction SilentlyContinue
        return
    } catch {
        Write-Step "Add-Type compiler failed, trying csc.exe fallback..."
    }

    $cscCandidates = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )
    $csc = $cscCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $csc) { throw 'No C# compiler found. Install .NET Framework build tools or run from Developer PowerShell.' }

    & $csc /nologo /target:winexe /out:$outExe /reference:System.Windows.Forms.dll /reference:System.Drawing.dll $tmpSrc
    if ($LASTEXITCODE -ne 0) { throw 'csc.exe failed to build JitsiNDI.exe launcher.' }
    Remove-Item -Force $tmpSrc -ErrorAction SilentlyContinue
}

$root = Resolve-RepoRoot
Write-Step "Repo root: $root"

$guiSrc = Join-Path $root 'JitsiNdiGui.ps1'
if (-not (Test-Path $guiSrc)) { throw 'JitsiNdiGui.ps1 not found.' }

$nativeExe = Find-NativeExe $root
$nativeDir = Split-Path -Parent $nativeExe
Write-Step "Native exe: $nativeExe"

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$distDir = Join-Path $root 'dist'
$stage = Join-Path $distDir "JitsiNDI_Portable_v66_$timestamp"
$zipPath = "$stage.zip"

if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'logs') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'build\Release') | Out-Null

Write-Step 'Copying GUI...'
Copy-Item -Force $guiSrc (Join-Path $stage 'JitsiNdiGui.ps1')

Write-Step 'Copying native exe and runtime DLLs...'
Copy-Item -Force $nativeExe (Join-Path $stage 'build\Release\jitsi-ndi-native.exe')
Get-ChildItem -Path $nativeDir -File -ErrorAction SilentlyContinue | Where-Object {
    $_.Extension -match '^\.(dll|pdb|json|dat)$'
} | ForEach-Object {
    Copy-Item -Force $_.FullName (Join-Path $stage ('build\Release\' + $_.Name))
}

# Copy common runtime DLLs from nearby build folders if they are not already copied.
$runtimeNames = @(
    'Processing.NDI.Lib.x64.dll',
    'avcodec-61.dll','avformat-61.dll','avutil-59.dll','swscale-8.dll','swresample-5.dll',
    'avcodec-60.dll','avformat-60.dll','avutil-58.dll','swscale-7.dll','swresample-4.dll',
    'dav1d.dll','libdav1d.dll','opus.dll','libopus.dll'
)
foreach ($name in $runtimeNames) {
    $dst = Join-Path $stage ('build\Release\' + $name)
    if (Test-Path $dst) { continue }
    $found = Get-ChildItem -Path $root -Recurse -File -Filter $name -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\dist\\' } |
        Select-Object -First 1
    if ($found) {
        Copy-Item -Force $found.FullName $dst
        Write-Step "Copied runtime: $name"
    }
}

if (Test-Path (Join-Path $root 'gui')) {
    Write-Step 'Copying gui folder...'
    Copy-Item -Recurse -Force (Join-Path $root 'gui') (Join-Path $stage 'gui')
}

Write-Step 'Building JitsiNDI.exe launcher...'
Build-LauncherExe (Join-Path $stage 'JitsiNDI.exe')

# Optional CMD shortcut, but EXE is the primary launcher.
$cmd = @'
@echo off
start "" "%~dp0JitsiNDI.exe"
'@
Set-Content -Path (Join-Path $stage 'START_JITSI_NDI.cmd') -Value $cmd -Encoding ASCII

$check = @'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Write-Host "Jitsi NDI portable check"
Write-Host "Root: $root"
$items = @(
    'JitsiNDI.exe',
    'JitsiNdiGui.ps1',
    'build\Release\jitsi-ndi-native.exe',
    'build\Release\Processing.NDI.Lib.x64.dll'
)
foreach ($i in $items) {
    $p = Join-Path $root $i
    if (Test-Path $p) { Write-Host "OK   $i" } else { Write-Host "MISS $i" }
}
$dlls = Get-ChildItem -Path (Join-Path $root 'build\Release') -Filter '*.dll' -ErrorAction SilentlyContinue
Write-Host "DLL count in build\Release: $($dlls.Count)"
Write-Host "Launch with: JitsiNDI.exe"
'@
Set-Content -Path (Join-Path $stage 'CHECK_PORTABLE.ps1') -Value $check -Encoding ASCII

$readme = @'
Jitsi NDI Portable v66
======================

Primary launch file:
  JitsiNDI.exe

What it does:
  - Starts JitsiNdiGui.ps1 in hidden PowerShell mode.
  - No separate PowerShell console window is shown.
  - GUI logs stay in the logs folder.
  - Native stdout is not displayed by the launcher.

Folder layout:
  JitsiNDI.exe
  JitsiNdiGui.ps1
  build\Release\jitsi-ndi-native.exe
  build\Release\*.dll
  gui\                 optional visual assets/fonts
  logs\                GUI log files

If something does not launch, run:
  powershell -ExecutionPolicy Bypass -File .\CHECK_PORTABLE.ps1

Notes:
  - NDI runtime DLL must be present as build\Release\Processing.NDI.Lib.x64.dll.
  - If antivirus blocks the launcher, allow JitsiNDI.exe or run the PS1 directly as a fallback.
'@
Set-Content -Path (Join-Path $stage 'README_PORTABLE.txt') -Value $readme -Encoding UTF8

Write-Step 'Creating zip...'
if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipPath -Force

Write-Step "Portable folder: $stage"
Write-Step "Portable zip: $zipPath"
Write-Step 'Done. Copy the generated ZIP to another Windows PC and run JitsiNDI.exe.'
