# Jitsi NDI Native - complete portable EXE packager v68
# Run from repository root after your working GUI/native version is installed.
# Creates a portable ZIP with hidden launcher and broader runtime DLL collection.

$ErrorActionPreference = 'Stop'

function Write-Step([string]$msg) { Write-Host "[v68] $msg" }
function Write-Warn([string]$msg) { Write-Host "[v68][WARN] $msg" -ForegroundColor Yellow }

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

function Find-NativeExe([string]$root) {
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

function Copy-FileSafe([string]$src, [string]$dst, [switch]$Overwrite) {
    if (-not (Test-Path $src)) { return $false }
    $parent = Split-Path -Parent $dst
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    if ((Test-Path $dst) -and -not $Overwrite) { return $false }
    Copy-Item -LiteralPath $src -Destination $dst -Force
    return $true
}

function Copy-DllFolder([string]$srcDir, [string]$dstDir, [string]$tag) {
    if (-not (Test-Path $srcDir)) { return 0 }
    $count = 0
    Get-ChildItem -LiteralPath $srcDir -File -Filter '*.dll' -ErrorAction SilentlyContinue | ForEach-Object {
        $dst = Join-Path $dstDir $_.Name
        if (Copy-FileSafe $_.FullName $dst) { $count++ }
    }
    if ($count -gt 0) { Write-Step "Copied $count DLL(s) from $tag" }
    return $count
}

function Patch-GuiForPortable([string]$guiPath) {
    $txt = Get-Content -LiteralPath $guiPath -Raw -Encoding UTF8

    # Hide the native console in portable mode.
    $txt = $txt -replace '\$psi\.CreateNoWindow\s*=\s*\$false', '$psi.CreateNoWindow = $true'
    $txt = $txt -replace '\$psi\.CreateNoWindow\s*=\s*\$False', '$psi.CreateNoWindow = $true'

    # Make sure the native exe folder is in PATH for DLL resolution.
    $needle = '$psi.WorkingDirectory = Split-Path -Parent $exe'
    if ($txt.Contains($needle) -and -not $txt.Contains('PORTABLE_DLL_PATH_PATCH_V68')) {
        $replacement = @'
$psi.WorkingDirectory = Split-Path -Parent $exe
        # PORTABLE_DLL_PATH_PATCH_V68: make local runtime DLLs visible to native exe.
        try {
            $nativeDirForPath = Split-Path -Parent $exe
            $oldPathForProcess = $psi.EnvironmentVariables['PATH']
            if ([string]::IsNullOrWhiteSpace($oldPathForProcess)) { $oldPathForProcess = $env:PATH }
            $psi.EnvironmentVariables['PATH'] = $nativeDirForPath + ';' + $script:repoRoot + ';' + $oldPathForProcess
        } catch {}
'@
        $txt = $txt.Replace($needle, $replacement)
    }

    Set-Content -LiteralPath $guiPath -Value $txt -Encoding UTF8
}

function Build-LauncherExe([string]$outExe) {
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

            string powershell = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                "System32\\WindowsPowerShell\\v1.0\\powershell.exe");
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

    try {
        Add-Type -TypeDefinition $code -ReferencedAssemblies @('System.Windows.Forms.dll','System.Drawing.dll') -OutputAssembly $outExe -OutputType WindowsApplication -Language CSharp
        return
    } catch {
        Write-Step "Add-Type compiler failed, trying csc.exe fallback..."
    }

    $tmpSrc = [System.IO.Path]::ChangeExtension($outExe, '.cs')
    Set-Content -Path $tmpSrc -Value $code -Encoding ASCII

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
$stage = Join-Path $distDir "JitsiNDI_Portable_v68_$timestamp"
$zipPath = "$stage.zip"

if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'logs') | Out-Null
$releaseOut = Join-Path $stage 'build\Release'
New-Item -ItemType Directory -Force -Path $releaseOut | Out-Null

Write-Step 'Copying GUI...'
$guiOut = Join-Path $stage 'JitsiNdiGui.ps1'
Copy-Item -LiteralPath $guiSrc -Destination $guiOut -Force
Patch-GuiForPortable $guiOut

Write-Step 'Copying full native Release folder...'
Get-ChildItem -LiteralPath $nativeDir -File -ErrorAction SilentlyContinue | ForEach-Object {
    Copy-FileSafe $_.FullName (Join-Path $releaseOut $_.Name) -Overwrite | Out-Null
}
# Ensure the expected exe name exists.
Copy-FileSafe $nativeExe (Join-Path $releaseOut 'jitsi-ndi-native.exe') -Overwrite | Out-Null

Write-Step 'Collecting runtime DLLs...'
$runtimeDirs = @(
    (Join-Path $root 'vcpkg_installed\x64-windows\bin'),
    (Join-Path $root 'build\vcpkg_installed\x64-windows\bin'),
    (Join-Path $root 'build-ndi\vcpkg_installed\x64-windows\bin'),
    (Join-Path $root 'build\Release'),
    (Join-Path $root 'build-ndi\Release'),
    (Join-Path $root 'build\RelWithDebInfo'),
    (Join-Path $root 'build-ndi\RelWithDebInfo')
)
foreach ($d in $runtimeDirs) {
    Copy-DllFolder $d $releaseOut $d | Out-Null
}

# Copy DLLs from common CMake build output locations, but avoid huge source/dist folders.
$buildDllRoots = @(
    (Join-Path $root 'build'),
    (Join-Path $root 'build-ndi')
)
foreach ($bd in $buildDllRoots) {
    if (Test-Path $bd) {
        Get-ChildItem -LiteralPath $bd -Recurse -File -Filter '*.dll' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\dist\\' -and $_.FullName -notmatch '\\CMakeFiles\\' } |
            ForEach-Object {
                Copy-FileSafe $_.FullName (Join-Path $releaseOut $_.Name) | Out-Null
            }
    }
}

# Copy Visual C++ runtime DLLs from the working machine.
$vcNames = @(
    'vcruntime140.dll',
    'vcruntime140_1.dll',
    'msvcp140.dll',
    'msvcp140_1.dll',
    'msvcp140_2.dll',
    'concrt140.dll',
    'vcomp140.dll'
)
foreach ($n in $vcNames) {
    $srcs = @(
        (Join-Path $env:WINDIR "System32\$n"),
        (Join-Path $env:WINDIR "SysWOW64\$n")
    )
    foreach ($s in $srcs) {
        if (Test-Path $s) {
            Copy-FileSafe $s (Join-Path $releaseOut $n) | Out-Null
            break
        }
    }
}

# Copy NDI runtime DLL from known installed paths or from repo.
$ndiName = 'Processing.NDI.Lib.x64.dll'
$ndiCandidates = @(
    (Join-Path $nativeDir $ndiName),
    (Join-Path $root $ndiName),
    (Join-Path $root "build\Release\$ndiName"),
    (Join-Path $env:ProgramFiles "NDI\NDI 6 Runtime\v6\$ndiName"),
    (Join-Path $env:ProgramFiles "NDI\NDI 5 Runtime\v5\$ndiName"),
    (Join-Path $env:ProgramFiles "NDI\NDI Runtime\$ndiName"),
    (Join-Path $env:ProgramFiles "NewTek\NDI 5 Runtime\v5\$ndiName"),
    (Join-Path $env:ProgramFiles "NewTek\NDI 4 Runtime\v4\$ndiName")
)
$ndiCopied = $false
foreach ($s in $ndiCandidates) {
    if ($s -and (Test-Path $s)) {
        Copy-FileSafe $s (Join-Path $releaseOut $ndiName) -Overwrite | Out-Null
        $ndiCopied = $true
        Write-Step "Copied NDI runtime DLL: $s"
        break
    }
}
if (-not $ndiCopied) {
    $foundNdi = Get-ChildItem -LiteralPath $root -Recurse -File -Filter $ndiName -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\dist\\' } |
        Select-Object -First 1
    if ($foundNdi) {
        Copy-FileSafe $foundNdi.FullName (Join-Path $releaseOut $ndiName) -Overwrite | Out-Null
        $ndiCopied = $true
        Write-Step "Copied NDI runtime DLL from repo: $($foundNdi.FullName)"
    }
}
if (-not $ndiCopied) {
    Write-Warn "$ndiName was not found. Portable NDI will not start on PCs without installed NDI Runtime."
}

if (Test-Path (Join-Path $root 'gui')) {
    Write-Step 'Copying gui folder...'
    Copy-Item -Recurse -Force (Join-Path $root 'gui') (Join-Path $stage 'gui')
}

Write-Step 'Building hidden JitsiNDI.exe launcher...'
Build-LauncherExe (Join-Path $stage 'JitsiNDI.exe')

$cmd = @'
@echo off
start "" "%~dp0JitsiNDI.exe"
'@
Set-Content -Path (Join-Path $stage 'START_JITSI_NDI.cmd') -Value $cmd -Encoding ASCII

$check = @'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$rel = Join-Path $root 'build\Release'
Write-Host "Jitsi NDI portable check v68"
Write-Host "Root: $root"
Write-Host ""

$items = @(
    'JitsiNDI.exe',
    'JitsiNdiGui.ps1',
    'build\Release\jitsi-ndi-native.exe',
    'build\Release\Processing.NDI.Lib.x64.dll',
    'build\Release\vcruntime140.dll',
    'build\Release\vcruntime140_1.dll',
    'build\Release\msvcp140.dll'
)
foreach ($i in $items) {
    $p = Join-Path $root $i
    if (Test-Path $p) { Write-Host "OK   $i" -ForegroundColor Green } else { Write-Host "MISS $i" -ForegroundColor Yellow }
}

Write-Host ""
$dlls = Get-ChildItem -Path $rel -Filter '*.dll' -ErrorAction SilentlyContinue
Write-Host "DLL count in build\Release: $($dlls.Count)"
$dlls | Sort-Object Name | Select-Object -ExpandProperty Name | ForEach-Object { Write-Host "  $_" }

Write-Host ""
Write-Host "If NDI source is still missing:"
Write-Host "1) Allow JitsiNDI.exe and jitsi-ndi-native.exe in Windows Firewall."
Write-Host "2) Make sure NDI Tools/Runtime is installed, or Processing.NDI.Lib.x64.dll is present above."
Write-Host "3) Run JitsiNDI.exe, connect, then open the newest file in logs."
'@
Set-Content -Path (Join-Path $stage 'CHECK_PORTABLE.ps1') -Value $check -Encoding ASCII

$readme = @'
Jitsi NDI Portable v68
======================

Primary launch:
  JitsiNDI.exe

This portable build tries harder than v66:
  - Copies the full native Release folder.
  - Copies vcpkg/runtime DLLs found in the repo/build folders.
  - Copies common Visual C++ runtime DLLs from the working machine.
  - Copies Processing.NDI.Lib.x64.dll from known NDI Runtime locations if found.
  - Patches the portable GUI copy so native runs without a separate console window.
  - Adds the native exe folder to PATH before launching native.

If NDI does not appear on another PC:
  1. Run:
       powershell -ExecutionPolicy Bypass -File .\CHECK_PORTABLE.ps1
  2. Check that this file exists:
       build\Release\Processing.NDI.Lib.x64.dll
  3. Allow JitsiNDI.exe and build\Release\jitsi-ndi-native.exe in Windows Firewall.
  4. If the NDI DLL is missing, install NDI Tools/Runtime on the source PC and rebuild this portable archive.

Logs:
  GUI logs are stored in:
       logs\

Main project is not modified except dist output.
'@
Set-Content -Path (Join-Path $stage 'README_PORTABLE.txt') -Value $readme -Encoding UTF8

Write-Step 'Creating zip...'
if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipPath -Force

Write-Step "Portable folder: $stage"
Write-Step "Portable zip: $zipPath"
Write-Step 'Done. Copy the generated ZIP to another Windows PC and run JitsiNDI.exe.'
