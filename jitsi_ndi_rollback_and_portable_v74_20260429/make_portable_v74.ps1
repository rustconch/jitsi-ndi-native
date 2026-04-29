$ErrorActionPreference = 'Stop'

function Find-RepoRoot {
    $d = Get-Item -LiteralPath (Get-Location).Path
    while ($null -ne $d) {
        $cmake = Join-Path $d.FullName 'CMakeLists.txt'
        $exe = Join-Path $d.FullName 'build\Release\jitsi-ndi-native.exe'
        if ((Test-Path -LiteralPath $cmake) -and (Test-Path -LiteralPath $exe)) {
            return $d.FullName
        }
        $d = $d.Parent
    }
    throw 'Repo root with build\Release\jitsi-ndi-native.exe not found. Build first.'
}

function Copy-IfExists($src, $dstDir) {
    if (Test-Path -LiteralPath $src) {
        New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
        Copy-Item -LiteralPath $src -Destination $dstDir -Force
        return $true
    }
    return $false
}

function Copy-DllsFromDir($srcDir, $dstDir) {
    if (-not (Test-Path -LiteralPath $srcDir)) { return 0 }
    $count = 0
    Get-ChildItem -LiteralPath $srcDir -Filter '*.dll' -File -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $dstDir -Force
        $count++
    }
    return $count
}

$root = Find-RepoRoot
Set-Location -LiteralPath $root
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$dist = Join-Path $root 'dist'
$portable = Join-Path $dist "JitsiNDI_Portable_v74_stable_$stamp"
$releaseSrc = Join-Path $root 'build\Release'
$releaseDst = Join-Path $portable 'build\Release'

New-Item -ItemType Directory -Force -Path $dist | Out-Null
if (Test-Path -LiteralPath $portable) { Remove-Item -LiteralPath $portable -Recurse -Force }
New-Item -ItemType Directory -Force -Path $releaseDst | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $portable 'logs') | Out-Null

Write-Host "[v74] Creating portable: $portable"
Copy-Item -LiteralPath (Join-Path $releaseSrc '*') -Destination $releaseDst -Recurse -Force

Copy-IfExists (Join-Path $root 'JitsiNdiGui.ps1') $portable | Out-Null
if (Test-Path -LiteralPath (Join-Path $root 'gui')) {
    Copy-Item -LiteralPath (Join-Path $root 'gui') -Destination (Join-Path $portable 'gui') -Recurse -Force
}

$extraDllDirs = @(
    (Join-Path $root 'vcpkg_installed\x64-windows\bin'),
    (Join-Path $root 'build\vcpkg_installed\x64-windows\bin'),
    (Join-Path $root 'build-ndi\Release')
)
$totalDlls = 0
foreach ($d in $extraDllDirs) { $totalDlls += Copy-DllsFromDir $d $releaseDst }
Write-Host "[v74] Extra DLLs copied: $totalDlls"

# NDI runtime DLL search.
$ndiName = 'Processing.NDI.Lib.x64.dll'
$ndiFound = $false
$ndiCandidates = @(
    (Join-Path $releaseSrc $ndiName),
    (Join-Path $root $ndiName),
    'C:\Program Files\NDI\NDI 6 SDK\Bin\x64\Processing.NDI.Lib.x64.dll',
    'C:\Program Files\NDI\NDI 5 SDK\Bin\x64\Processing.NDI.Lib.x64.dll',
    'C:\Program Files\NDI\NDI Runtime\v6\Processing.NDI.Lib.x64.dll',
    'C:\Program Files\NDI\NDI Runtime\v5\Processing.NDI.Lib.x64.dll'
)
foreach ($p in $ndiCandidates) {
    if (Copy-IfExists $p $releaseDst) { $ndiFound = $true; break }
}
if (-not $ndiFound) {
    foreach ($base in @('C:\Program Files\NDI', 'C:\Program Files (x86)\NDI')) {
        if (Test-Path -LiteralPath $base) {
            $found = Get-ChildItem -LiteralPath $base -Recurse -Filter $ndiName -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) {
                Copy-Item -LiteralPath $found.FullName -Destination $releaseDst -Force
                $ndiFound = $true
                break
            }
        }
    }
}
if ($ndiFound) { Write-Host '[v74] NDI DLL: OK' } else { Write-Host '[v74] NDI DLL: MISS. Install/copy NDI Runtime if needed.' }

# VC runtime DLLs from System32, if present.
$sys = Join-Path $env:WINDIR 'System32'
foreach ($name in @('vcruntime140.dll','vcruntime140_1.dll','msvcp140.dll','concrt140.dll')) {
    Copy-IfExists (Join-Path $sys $name) $releaseDst | Out-Null
}

# Portable env file: GUI can import it if needed, but launcher also starts in portable root.
@"
# Portable environment helper
`$portableRoot = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$nativeDir = Join-Path `$portableRoot 'build\Release'
`$env:PATH = `$nativeDir + ';' + `$env:PATH
"@ | Set-Content -LiteralPath (Join-Path $portable 'portable_env.ps1') -Encoding ASCII

# Check script.
@'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$release = Join-Path $root 'build\Release'
$items = @(
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
foreach ($i in $items) {
    $found = Get-ChildItem -Path $release -Filter $i -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { Write-Host ('OK   ' + $i + ' -> ' + $found.Name) } else { Write-Host ('MISS ' + $i) }
}
Write-Host ''
Write-Host 'Run JitsiNDI.exe to start the GUI.'
'@ | Set-Content -LiteralPath (Join-Path $portable 'CHECK_PORTABLE.ps1') -Encoding ASCII

# Build Windows GUI launcher exe. No CMD launcher is created.
$launcherCs = Join-Path $portable 'JitsiNDI_launcher.cs'
$launcherExe = Join-Path $portable 'JitsiNDI.exe'
@'
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string ps1 = Path.Combine(dir, "JitsiNdiGui.ps1");
        if (!File.Exists(ps1))
        {
            MessageBox.Show("JitsiNdiGui.ps1 not found next to JitsiNDI.exe", "JitsiNDI", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        string system32 = Environment.GetFolderPath(Environment.SpecialFolder.System);
        string powershell = Path.Combine(system32, "WindowsPowerShell\\v1.0\\powershell.exe");
        if (!File.Exists(powershell)) powershell = "powershell.exe";

        var psi = new ProcessStartInfo();
        psi.FileName = powershell;
        psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + ps1 + "\"";
        psi.WorkingDirectory = dir;
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WindowStyle = ProcessWindowStyle.Hidden;
        string nativeDir = Path.Combine(dir, "build", "Release");
        string oldPath = Environment.GetEnvironmentVariable("PATH") ?? "";
        psi.EnvironmentVariables["PATH"] = nativeDir + ";" + oldPath;

        try { Process.Start(psi); }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "JitsiNDI start failed", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
'@ | Set-Content -LiteralPath $launcherCs -Encoding ASCII

$cscCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$csc = $null
foreach ($c in $cscCandidates) { if (Test-Path -LiteralPath $c) { $csc = $c; break } }
if (-not $csc) { throw 'csc.exe not found. Cannot build JitsiNDI.exe launcher.' }
& $csc /nologo /target:winexe /out:$launcherExe /reference:System.Windows.Forms.dll $launcherCs
if ($LASTEXITCODE -ne 0) { throw 'Failed to build JitsiNDI.exe launcher.' }
Remove-Item -LiteralPath $launcherCs -Force

# README ASCII only.
@'
JitsiNDI Portable v74 stable

Start:
  JitsiNDI.exe

There is no CMD launcher. PowerShell window is hidden.
Logs are written to the logs folder by the GUI/native scripts.

If something does not start, run:
  powershell -ExecutionPolicy Bypass -File .\CHECK_PORTABLE.ps1
'@ | Set-Content -LiteralPath (Join-Path $portable 'README_PORTABLE.txt') -Encoding ASCII

$zip = $portable + '.zip'
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -LiteralPath (Join-Path $portable '*') -DestinationPath $zip -Force
Write-Host "[v74] Done: $zip"
