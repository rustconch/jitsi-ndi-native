$ErrorActionPreference = 'Stop'

function Write-Step($msg) {
    Write-Host "[v73] $msg"
}

function Get-FullPath([string]$path) {
    return [System.IO.Path]::GetFullPath($path)
}

function Find-ProjectRoot {
    $starts = New-Object System.Collections.Generic.List[string]
    try { $starts.Add((Get-Location).Path) } catch {}
    try { $starts.Add((Split-Path -Parent $PSScriptRoot)) } catch {}
    try { $starts.Add($PSScriptRoot) } catch {}

    foreach ($start in $starts) {
        if ([string]::IsNullOrWhiteSpace($start)) { continue }
        $dir = New-Object System.IO.DirectoryInfo((Get-FullPath $start))
        for ($i = 0; $i -lt 8 -and $null -ne $dir; $i++) {
            $gui = Join-Path $dir.FullName 'JitsiNdiGui.ps1'
            $native = Join-Path $dir.FullName 'build\Release\jitsi-ndi-native.exe'
            $cmake = Join-Path $dir.FullName 'CMakeLists.txt'
            if ((Test-Path -LiteralPath $gui) -and (Test-Path -LiteralPath $native) -and (Test-Path -LiteralPath $cmake)) {
                return $dir.FullName
            }
            $dir = $dir.Parent
        }
    }
    throw 'Project root not found. Run this script from the jitsi-ndi-native repo root after building Release.'
}

function Copy-DirRobust([string]$src, [string]$dst) {
    if (-not (Test-Path -LiteralPath $src)) { return }
    if (-not (Test-Path -LiteralPath $dst)) { New-Item -ItemType Directory -Force -Path $dst | Out-Null }
    $robocopy = Join-Path $env:WINDIR 'System32\robocopy.exe'
    if (Test-Path -LiteralPath $robocopy) {
        & $robocopy $src $dst /E /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -gt 7) { throw "robocopy failed from $src to $dst with code $LASTEXITCODE" }
    } else {
        Copy-Item -LiteralPath (Join-Path $src '*') -Destination $dst -Recurse -Force
    }
}

function Copy-FileIfExists([string]$src, [string]$dstDir) {
    if ([string]::IsNullOrWhiteSpace($src)) { return }
    if (Test-Path -LiteralPath $src) {
        if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
        Copy-Item -LiteralPath $src -Destination (Join-Path $dstDir ([System.IO.Path]::GetFileName($src))) -Force
    }
}

function Copy-AllDllsFrom([string]$srcRoot, [string]$dstDir) {
    if (-not (Test-Path -LiteralPath $srcRoot)) { return 0 }
    $count = 0
    Get-ChildItem -LiteralPath $srcRoot -Recurse -File -Filter '*.dll' -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-FileIfExists $_.FullName $dstDir
        $count++
    }
    return $count
}

function Find-NdiDll([string]$projectRoot) {
    $known = @(
        (Join-Path $projectRoot 'build\Release\Processing.NDI.Lib.x64.dll'),
        (Join-Path $projectRoot 'Processing.NDI.Lib.x64.dll'),
        (Join-Path $env:ProgramFiles 'NDI\NDI 6 SDK\Bin\x64\Processing.NDI.Lib.x64.dll'),
        (Join-Path $env:ProgramFiles 'NDI\NDI 6 Runtime\Bin\x64\Processing.NDI.Lib.x64.dll'),
        (Join-Path $env:ProgramFiles 'NewTek\NDI 6 Runtime\Bin\x64\Processing.NDI.Lib.x64.dll'),
        (Join-Path ${env:ProgramFiles(x86)} 'NDI\NDI 6 SDK\Bin\x64\Processing.NDI.Lib.x64.dll'),
        (Join-Path ${env:ProgramFiles(x86)} 'NDI\NDI 6 Runtime\Bin\x64\Processing.NDI.Lib.x64.dll')
    )
    foreach ($p in $known) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }

    $searchRoots = @(
        (Join-Path $env:ProgramFiles 'NDI'),
        (Join-Path $env:ProgramFiles 'NewTek'),
        $projectRoot
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    foreach ($r in $searchRoots) {
        $hit = Get-ChildItem -LiteralPath $r -Recurse -File -Filter 'Processing.NDI.Lib.x64.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Write-Utf8NoBom([string]$path, [string]$text) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $text, $enc)
}

function Compile-Launcher([string]$stageRoot) {
    $src = Join-Path $stageRoot 'JitsiNDILauncher.cs'
    $exe = Join-Path $stageRoot 'JitsiNDI.exe'
    $code = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        try
        {
            string dir = AppDomain.CurrentDomain.BaseDirectory;
            string ps1 = Path.Combine(dir, "JitsiNdiGui.ps1");
            if (!File.Exists(ps1))
            {
                MessageBox.Show("JitsiNdiGui.ps1 was not found next to JitsiNDI.exe.", "Jitsi NDI", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
            if (!File.Exists(ps))
            {
                ps = "powershell.exe";
            }

            var psi = new ProcessStartInfo();
            psi.FileName = ps;
            psi.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + ps1 + "\"";
            psi.WorkingDirectory = dir;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WindowStyle = ProcessWindowStyle.Hidden;
            Process.Start(psi);
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.ToString(), "Jitsi NDI launcher error", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
'@
    Write-Utf8NoBom $src $code

    $cscCandidates = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )
    $csc = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $csc) { throw 'csc.exe was not found. Install/enable .NET Framework 4.x developer tools or Visual Studio Build Tools.' }

    & $csc /nologo /target:winexe /platform:x64 /out:$exe /reference:System.Windows.Forms.dll $src
    if (-not (Test-Path -LiteralPath $exe)) { throw 'Failed to build JitsiNDI.exe launcher.' }
    Remove-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
}

$root = Find-ProjectRoot
Write-Step "Project root: $root"

$releaseSrc = Join-Path $root 'build\Release'
$nativeExe = Join-Path $releaseSrc 'jitsi-ndi-native.exe'
$guiSrc = Join-Path $root 'JitsiNdiGui.ps1'

if (-not (Test-Path -LiteralPath $nativeExe)) { throw "Native exe not found: $nativeExe" }
if (-not (Test-Path -LiteralPath $guiSrc)) { throw "GUI script not found: $guiSrc" }

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$dist = Join-Path $root 'dist'
$name = "JitsiNDI_Portable_v73_$stamp"
$stage = Join-Path $dist $name
$stageRelease = Join-Path $stage 'build\Release'

New-Item -ItemType Directory -Force -Path $dist | Out-Null
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
New-Item -ItemType Directory -Force -Path $stageRelease | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'logs') | Out-Null

Write-Step 'Copying GUI...'
Copy-Item -LiteralPath $guiSrc -Destination (Join-Path $stage 'JitsiNdiGui.ps1') -Force

# Inject a tiny portable bootstrap at the top. It only helps DLL search and does not change GUI features.
$portableGui = Join-Path $stage 'JitsiNdiGui.ps1'
$guiText = [System.IO.File]::ReadAllText($portableGui, [System.Text.Encoding]::UTF8)
$bootstrap = @'
# Portable bootstrap injected by v73 packager. Keeps runtime DLLs local to this folder.
try {
    $script:PortableRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    $script:PortableReleaseDir = Join-Path $script:PortableRoot "build\Release"
    if (Test-Path -LiteralPath $script:PortableReleaseDir) {
        $env:PATH = $script:PortableReleaseDir + ";" + $env:PATH
    }
} catch {}

'@
if ($guiText -notmatch 'Portable bootstrap injected by v73 packager') {
    Write-Utf8NoBom $portableGui ($bootstrap + $guiText)
}

$guiFolder = Join-Path $root 'gui'
if (Test-Path -LiteralPath $guiFolder) {
    Write-Step 'Copying local gui assets folder...'
    Copy-DirRobust $guiFolder (Join-Path $stage 'gui')
}

Write-Step 'Copying full build\\Release...'
Copy-DirRobust $releaseSrc $stageRelease

Write-Step 'Collecting DLL dependencies...'
$dllRoots = @(
    (Join-Path $root 'vcpkg_installed'),
    (Join-Path $root 'build\vcpkg_installed'),
    (Join-Path $root 'build'),
    (Join-Path $root 'build-ndi'),
    (Join-Path $root 'out')
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
$totalDlls = 0
foreach ($dr in $dllRoots) {
    $totalDlls += Copy-AllDllsFrom $dr $stageRelease
}
Write-Step "Runtime DLL scan copied/updated $totalDlls DLL references."

$ndi = Find-NdiDll $root
if ($ndi) {
    Write-Step "NDI runtime DLL: $ndi"
    Copy-FileIfExists $ndi $stageRelease
} else {
    Write-Host '[v73][WARN] Processing.NDI.Lib.x64.dll was not found. Install NDI Runtime/SDK on this PC and rerun packager.' -ForegroundColor Yellow
}

Write-Step 'Copying VC++ runtime DLLs if available...'
$sys = Join-Path $env:WINDIR 'System32'
@('vcruntime140.dll','vcruntime140_1.dll','msvcp140.dll','concrt140.dll') | ForEach-Object {
    Copy-FileIfExists (Join-Path $sys $_) $stageRelease
}

Write-Step 'Building JitsiNDI.exe launcher...'
Compile-Launcher $stage

$check = @'
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$release = Join-Path $root 'build\Release'
function Check($name, $path) {
    if (Test-Path -LiteralPath $path) { Write-Host ("OK   " + $name) -ForegroundColor Green }
    else { Write-Host ("MISS " + $name + " -> " + $path) -ForegroundColor Red }
}
Write-Host 'Jitsi NDI portable check'
Write-Host ('Root: ' + $root)
Check 'JitsiNDI.exe' (Join-Path $root 'JitsiNDI.exe')
Check 'JitsiNdiGui.ps1' (Join-Path $root 'JitsiNdiGui.ps1')
Check 'jitsi-ndi-native.exe' (Join-Path $release 'jitsi-ndi-native.exe')
Check 'Processing.NDI.Lib.x64.dll' (Join-Path $release 'Processing.NDI.Lib.x64.dll')
Check 'vcruntime140.dll' (Join-Path $release 'vcruntime140.dll')
Check 'vcruntime140_1.dll' (Join-Path $release 'vcruntime140_1.dll')
Check 'msvcp140.dll' (Join-Path $release 'msvcp140.dll')
Write-Host ''
Write-Host 'Video/runtime DLLs found:'
Get-ChildItem -LiteralPath $release -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^(avcodec|avutil|swscale|swresample|dav1d|libdav1d|vpx|aom|SvtAv1|datachannel|juice|srtp|usrsctp).*\.dll$' } |
    Sort-Object Name |
    Select-Object -ExpandProperty Name
Write-Host ''
Write-Host 'Main launch file: JitsiNDI.exe'
'@
Write-Utf8NoBom (Join-Path $stage 'CHECK_PORTABLE.ps1') $check

$readme = @'
Jitsi NDI Portable v73

Main launch file:
  JitsiNDI.exe

Do not use CMD for normal startup. The EXE starts the PowerShell GUI without showing a PowerShell console window.

Included:
  - JitsiNdiGui.ps1
  - build\Release\jitsi-ndi-native.exe
  - build\Release runtime DLLs, including NDI/FFmpeg/dav1d when found
  - gui folder if it existed in the project root
  - logs folder
  - CHECK_PORTABLE.ps1

If NDI/video does not appear on another computer, run:
  powershell -ExecutionPolicy Bypass -File .\CHECK_PORTABLE.ps1

Then check the latest file in logs.
'@
Write-Utf8NoBom (Join-Path $stage 'README_PORTABLE.txt') $readme

Write-Step 'Creating zip archive...'
$zip = Join-Path $dist ($name + '.zip')
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -LiteralPath (Join-Path $stage '*') -DestinationPath $zip -Force

Write-Host ''
Write-Host '[v73] Portable archive created:' -ForegroundColor Green
Write-Host $zip -ForegroundColor Green
Write-Host ''
Write-Host '[v73] Main launch file inside portable: JitsiNDI.exe' -ForegroundColor Green
