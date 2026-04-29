# v75 stable portable packager for jitsi-ndi-native
# Builds portable package from the currently built stable native.
# Main launch file in portable: JitsiNDI.exe only. No cmd launcher is created.
$ErrorActionPreference = 'Stop'

function Log($m) { Write-Host "[v75] $m" }

function Find-ProjectRoot {
    $candidates = @()
    $candidates += (Get-Location).Path
    if ($PSScriptRoot) { $candidates += (Split-Path -Parent $PSScriptRoot) }
    foreach ($s in $candidates) {
        if (-not $s) { continue }
        $d = Get-Item -LiteralPath $s -ErrorAction SilentlyContinue
        while ($d -and $d.PSIsContainer) {
            if ((Test-Path -LiteralPath (Join-Path $d.FullName 'CMakeLists.txt')) -and
                (Test-Path -LiteralPath (Join-Path $d.FullName 'src'))) {
                return $d.FullName
            }
            $d = $d.Parent
        }
    }
    throw 'Project root not found. Run this from repo root.'
}

function Copy-DirContents($src, $dst) {
    if (-not (Test-Path -LiteralPath $src)) { return }
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Get-ChildItem -LiteralPath $src -Force | ForEach-Object {
        $target = Join-Path $dst $_.Name
        if ($_.PSIsContainer) {
            Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse -Force
        } else {
            Copy-Item -LiteralPath $_.FullName -Destination $target -Force
        }
    }
}

function Find-NativeExe($root) {
    $preferred = Join-Path $root 'build\Release\jitsi-ndi-native.exe'
    if (Test-Path -LiteralPath $preferred) { return $preferred }
    $all = Get-ChildItem -LiteralPath $root -Recurse -File -Filter 'jitsi-ndi-native.exe' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\dist\\' } |
        Sort-Object LastWriteTime -Descending
    if ($all.Count -gt 0) { return $all[0].FullName }
    throw 'jitsi-ndi-native.exe not found. Build native first, for example: .\rebuild_with_dav1d_v21.ps1'
}

function Copy-RuntimeDlls($root, $stageRelease) {
    $patterns = @(
        'avcodec*.dll','avformat*.dll','avutil*.dll','swscale*.dll','swresample*.dll',
        'dav1d*.dll','libdav1d*.dll','vpx*.dll','aom*.dll','SvtAv1*.dll',
        'datachannel.dll','juice.dll','srtp2.dll','usrsctp.dll',
        'vcruntime140*.dll','msvcp140*.dll','concrt140.dll'
    )

    $searchRoots = @(
        (Join-Path $root 'build\Release'),
        (Join-Path $root 'build'),
        (Join-Path $root 'vcpkg_installed\x64-windows\bin'),
        (Join-Path $root 'build\vcpkg_installed\x64-windows\bin')
    ) | Where-Object { Test-Path -LiteralPath $_ }

    $copied = @{}
    foreach ($sr in $searchRoots) {
        foreach ($pat in $patterns) {
            Get-ChildItem -LiteralPath $sr -Recurse -File -Filter $pat -ErrorAction SilentlyContinue | ForEach-Object {
                $dst = Join-Path $stageRelease $_.Name
                Copy-Item -LiteralPath $_.FullName -Destination $dst -Force
                $copied[$_.Name] = $true
            }
        }
    }

    $ndiRoots = @(
        'C:\Program Files\NDI\NDI 6 Runtime\v6',
        'C:\Program Files\NDI\NDI 6 Tools\Runtime',
        'C:\Program Files\NDI\NDI 6 SDK\Bin\x64'
    )
    foreach ($nr in $ndiRoots) {
        $p = Join-Path $nr 'Processing.NDI.Lib.x64.dll'
        if (Test-Path -LiteralPath $p) {
            Copy-Item -LiteralPath $p -Destination (Join-Path $stageRelease 'Processing.NDI.Lib.x64.dll') -Force
            $copied['Processing.NDI.Lib.x64.dll'] = $true
            Log "Copied NDI x64 runtime: $p"
            break
        }
    }

    Log ("Runtime DLL names copied/confirmed: " + $copied.Count)
}

function Build-Launcher($stage) {
    $src = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

public static class Program {
    [STAThread]
    public static void Main() {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string ps1 = Path.Combine(dir, "JitsiNdiGui.ps1");
        if (!File.Exists(ps1)) {
            MessageBox.Show("JitsiNdiGui.ps1 not found next to launcher.", "Jitsi NDI", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }
        string releaseDir = Path.Combine(dir, "build", "Release");
        string oldPath = Environment.GetEnvironmentVariable("PATH") ?? "";
        Environment.SetEnvironmentVariable("PATH", releaseDir + ";" + dir + ";" + oldPath);
        var psi = new ProcessStartInfo();
        psi.FileName = "powershell.exe";
        psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + ps1 + "\"";
        psi.WorkingDirectory = dir;
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        try {
            Process.Start(psi);
        } catch (Exception ex) {
            MessageBox.Show(ex.ToString(), "Jitsi NDI launcher error", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
'@

    $cs = Join-Path $stage 'JitsiNDI_Launcher.cs'
    $exe = Join-Path $stage 'JitsiNDI.exe'
    [System.IO.File]::WriteAllText($cs, $src, [System.Text.Encoding]::UTF8)

    $cscCandidates = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )
    $csc = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $csc) { throw 'csc.exe not found. Cannot build JitsiNDI.exe launcher.' }

    & $csc /nologo /target:winexe "/out:$exe" "/reference:System.Windows.Forms.dll" $cs
    if ($LASTEXITCODE -ne 0) { throw 'csc failed while building launcher.' }
    if (-not (Test-Path -LiteralPath $exe)) { throw 'JitsiNDI.exe launcher was not created.' }
    Remove-Item -LiteralPath $cs -Force -ErrorAction SilentlyContinue
}

$root = Find-ProjectRoot
Set-Location -LiteralPath $root
Log "Project root: $root"

$nativeExe = Find-NativeExe $root
Log "Native exe: $nativeExe"

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$stage = Join-Path $dist ("JitsiNDI_Portable_v75_stable_" + $stamp)
$stageRelease = Join-Path $stage 'build\Release'
New-Item -ItemType Directory -Force -Path $stageRelease | Out-Null

Log "Portable stage: $stage"
Copy-DirContents (Join-Path $root 'build\Release') $stageRelease
Copy-Item -LiteralPath $nativeExe -Destination (Join-Path $stageRelease 'jitsi-ndi-native.exe') -Force

$guiPs1 = Join-Path $root 'JitsiNdiGui.ps1'
if (-not (Test-Path -LiteralPath $guiPs1)) { throw 'JitsiNdiGui.ps1 not found in project root.' }
Copy-Item -LiteralPath $guiPs1 -Destination (Join-Path $stage 'JitsiNdiGui.ps1') -Force

$guiDir = Join-Path $root 'gui'
if (Test-Path -LiteralPath $guiDir) {
    Copy-DirContents $guiDir (Join-Path $stage 'gui')
    Log "Copied gui folder"
}

New-Item -ItemType Directory -Force -Path (Join-Path $stage 'logs') | Out-Null

Copy-RuntimeDlls $root $stageRelease
Build-Launcher $stage
Log "JitsiNDI.exe launcher created"

$check = @'
$ErrorActionPreference = "Continue"
Write-Host "Jitsi NDI portable check"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$items = @(
    "JitsiNDI.exe",
    "JitsiNdiGui.ps1",
    "build\Release\jitsi-ndi-native.exe",
    "build\Release\Processing.NDI.Lib.x64.dll",
    "build\Release\avcodec-*.dll",
    "build\Release\avutil-*.dll",
    "build\Release\swscale-*.dll",
    "build\Release\swresample-*.dll"
)
foreach ($i in $items) {
    $p = Join-Path $root $i
    $ok = @(Get-ChildItem -Path $p -ErrorAction SilentlyContinue).Count -gt 0
    if ($ok) { Write-Host ("OK   " + $i) } else { Write-Host ("MISS " + $i) }
}
Write-Host ""
Write-Host "Run: JitsiNDI.exe"
'@
[System.IO.File]::WriteAllText((Join-Path $stage 'CHECK_PORTABLE.ps1'), $check, [System.Text.Encoding]::ASCII)

$readme = @'
JitsiNDI portable v75 stable package

Run:
  JitsiNDI.exe

Notes:
  - No cmd launcher is included.
  - PowerShell console should not be visible.
  - Native exe is located at build\Release\jitsi-ndi-native.exe.
  - Logs are written to logs folder by the GUI/native logic.
  - If something does not start, run:
      powershell -ExecutionPolicy Bypass -File .\CHECK_PORTABLE.ps1
'@
[System.IO.File]::WriteAllText((Join-Path $stage 'README_PORTABLE.txt'), $readme, [System.Text.Encoding]::ASCII)

# Ensure no cmd launcher.
Get-ChildItem -LiteralPath $stage -Filter '*.cmd' -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force

# Sanity
$must = @(
    (Join-Path $stage 'JitsiNDI.exe'),
    (Join-Path $stage 'JitsiNdiGui.ps1'),
    (Join-Path $stage 'build\Release\jitsi-ndi-native.exe')
)
foreach ($m in $must) {
    if (-not (Test-Path -LiteralPath $m)) { throw "Portable sanity failed: missing $m" }
}
if (Test-Path -LiteralPath (Join-Path $stage 'build\Release\jitsi-ndi-natove.exe')) {
    throw 'Portable sanity failed: typo natove exists.'
}

$zip = Join-Path $dist ("JitsiNDI_Portable_v75_stable_" + $stamp + ".zip")
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
Log "Portable zip created: $zip"
