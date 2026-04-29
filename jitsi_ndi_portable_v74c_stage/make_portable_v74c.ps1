$ErrorActionPreference = 'Stop'

function Resolve-DirString([string]$p) {
    return (Resolve-Path -LiteralPath $p).ProviderPath
}

function Find-ProjectRoot {
    $candidates = @()
    $candidates += (Get-Location).Path
    $candidates += (Split-Path -Parent $PSCommandPath)
    foreach ($s in $candidates) {
        if (-not $s) { continue }
        $dir = Get-Item -LiteralPath (Resolve-DirString $s)
        while ($null -ne $dir) {
            $cmake = Join-Path $dir.FullName 'CMakeLists.txt'
            $src = Join-Path $dir.FullName 'src'
            $gui = Join-Path $dir.FullName 'JitsiNdiGui.ps1'
            if ((Test-Path -LiteralPath $cmake) -and (Test-Path -LiteralPath $src) -and (Test-Path -LiteralPath $gui)) {
                return $dir.FullName
            }
            $dir = $dir.Parent
        }
    }
    throw 'Project root not found. Run this script from the jitsi-ndi-native repo root.'
}

function Copy-DllsFromDir([string]$from, [string]$to) {
    if (-not (Test-Path -LiteralPath $from)) { return 0 }
    $count = 0
    Get-ChildItem -LiteralPath $from -Filter '*.dll' -File -ErrorAction SilentlyContinue | ForEach-Object {
        $dst = Join-Path $to $_.Name
        Copy-Item -LiteralPath $_.FullName -Destination $dst -Force
        $count++
    }
    return $count
}

function Find-NdiDll([string]$root) {
    $names = @('Processing.NDI.Lib.x64.dll')
    foreach ($name in $names) {
        $direct = Get-ChildItem -LiteralPath $root -Recurse -Filter $name -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\dist\\' } |
            Select-Object -First 1
        if ($direct) { return $direct.FullName }
    }

    $paths = @(
        'C:\Program Files\NDI\NDI 6 SDK\Bin\x64',
        'C:\Program Files\NDI\NDI 5 SDK\Bin\x64',
        'C:\Program Files\NDI\NDI Runtime\v6',
        'C:\Program Files\NDI\NDI Runtime\v5',
        'C:\Program Files\NewTek\NDI 6 Runtime\v6',
        'C:\Program Files\NewTek\NDI 5 Runtime\v5'
    )
    foreach ($p in $paths) {
        foreach ($name in $names) {
            $f = Join-Path $p $name
            if (Test-Path -LiteralPath $f) { return $f }
        }
    }

    foreach ($base in @('C:\Program Files\NDI', 'C:\Program Files\NewTek')) {
        if (Test-Path -LiteralPath $base) {
            $hit = Get-ChildItem -LiteralPath $base -Recurse -Filter 'Processing.NDI.Lib.x64.dll' -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
    }
    return $null
}

function New-LauncherExe([string]$outExe) {
    $code = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

public static class JitsiNdiLauncher {
    [STAThread]
    public static void Main() {
        try {
            string dir = AppDomain.CurrentDomain.BaseDirectory;
            string script = Path.Combine(dir, "JitsiNdiGui.ps1");
            if (!File.Exists(script)) {
                MessageBox.Show("JitsiNdiGui.ps1 not found next to JitsiNDI.exe", "Jitsi NDI", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }
            string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
            if (!File.Exists(ps)) ps = "powershell.exe";

            var psi = new ProcessStartInfo();
            psi.FileName = ps;
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"";
            psi.WorkingDirectory = dir;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WindowStyle = ProcessWindowStyle.Hidden;
            Process.Start(psi);
        } catch (Exception ex) {
            MessageBox.Show(ex.ToString(), "Jitsi NDI launcher error", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
'@
    if (Test-Path -LiteralPath $outExe) { Remove-Item -LiteralPath $outExe -Force }
    Add-Type -TypeDefinition $code -Language CSharp -OutputAssembly $outExe -OutputType WindowsApplication -ReferencedAssemblies @('System.Windows.Forms.dll')
}

$root = Find-ProjectRoot
Write-Host "[v74c] Project root: $root"

$releaseDir = Join-Path $root 'build\Release'
$nativeExe = Join-Path $releaseDir 'jitsi-ndi-native.exe'

if (-not (Test-Path -LiteralPath $nativeExe)) {
    Write-Host "[v74c] build\Release\jitsi-ndi-native.exe not found, searching in build folders..."
    $hit = Get-ChildItem -LiteralPath $root -Recurse -Filter 'jitsi-ndi-native.exe' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\dist\\' -and $_.FullName -notmatch '\\.git\\' } |
        Sort-Object FullName |
        Select-Object -First 1
    if (-not $hit) {
        throw 'jitsi-ndi-native.exe not found. Build the project first: .\rebuild_with_dav1d_v21.ps1'
    }
    $releaseDir = $hit.DirectoryName
    $nativeExe = $hit.FullName
    Write-Host "[v74c] Using native exe from: $nativeExe"
}

$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$stage = Join-Path $dist "JitsiNDI_Portable_v74c_$stamp"
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

$stageRelease = Join-Path $stage 'build\Release'
New-Item -ItemType Directory -Force -Path $stageRelease | Out-Null

Write-Host "[v74c] Portable stage: $stage"
Write-Host "[v74c] Copying native release folder..."
Copy-Item -LiteralPath (Join-Path $releaseDir '*') -Destination $stageRelease -Recurse -Force

$guiSrc = Join-Path $root 'JitsiNdiGui.ps1'
Copy-Item -LiteralPath $guiSrc -Destination (Join-Path $stage 'JitsiNdiGui.ps1') -Force

$guiFolder = Join-Path $root 'gui'
if (Test-Path -LiteralPath $guiFolder) {
    Write-Host "[v74c] Copying gui folder..."
    Copy-Item -LiteralPath $guiFolder -Destination (Join-Path $stage 'gui') -Recurse -Force
}

New-Item -ItemType Directory -Force -Path (Join-Path $stage 'logs') | Out-Null

$dllDirs = @(
    $releaseDir,
    (Join-Path $root 'build\Release'),
    (Join-Path $root 'build\vcpkg_installed\x64-windows\bin'),
    (Join-Path $root 'vcpkg_installed\x64-windows\bin'),
    (Join-Path $root 'build\_deps\libdatachannel-build'),
    (Join-Path $root 'build\_deps\libdatachannel-build\Release')
) | Select-Object -Unique

$dllCount = 0
foreach ($d in $dllDirs) { $dllCount += Copy-DllsFromDir $d $stageRelease }

$ndi = Find-NdiDll $root
if ($ndi) {
    Copy-Item -LiteralPath $ndi -Destination (Join-Path $stageRelease 'Processing.NDI.Lib.x64.dll') -Force
    Write-Host "[v74c] NDI DLL copied: $ndi"
} else {
    Write-Host "[v74c] WARNING: Processing.NDI.Lib.x64.dll was not found. Portable may require NDI Runtime installed on target PC."
}

foreach ($vc in @('vcruntime140.dll','vcruntime140_1.dll','msvcp140.dll','concrt140.dll')) {
    $sys = Join-Path $env:WINDIR "System32\$vc"
    if (Test-Path -LiteralPath $sys) {
        Copy-Item -LiteralPath $sys -Destination (Join-Path $stageRelease $vc) -Force
    }
}

$launcher = Join-Path $stage 'JitsiNDI.exe'
New-LauncherExe $launcher
Write-Host "[v74c] JitsiNDI.exe launcher created."

$check = @'
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSCommandPath
function Check($label, $path) {
    if (Test-Path -LiteralPath $path) { Write-Host "OK   $label -> $path" -ForegroundColor Green }
    else { Write-Host "MISS $label -> $path" -ForegroundColor Red }
}
Check 'JitsiNDI.exe' (Join-Path $root 'JitsiNDI.exe')
Check 'JitsiNdiGui.ps1' (Join-Path $root 'JitsiNdiGui.ps1')
Check 'native exe' (Join-Path $root 'build\Release\jitsi-ndi-native.exe')
Check 'NDI runtime DLL' (Join-Path $root 'build\Release\Processing.NDI.Lib.x64.dll')
Check 'avcodec DLL' ((Get-ChildItem -LiteralPath (Join-Path $root 'build\Release') -Filter 'avcodec*.dll' -File -ErrorAction SilentlyContinue | Select-Object -First 1).FullName)
Check 'avutil DLL' ((Get-ChildItem -LiteralPath (Join-Path $root 'build\Release') -Filter 'avutil*.dll' -File -ErrorAction SilentlyContinue | Select-Object -First 1).FullName)
Check 'swscale DLL' ((Get-ChildItem -LiteralPath (Join-Path $root 'build\Release') -Filter 'swscale*.dll' -File -ErrorAction SilentlyContinue | Select-Object -First 1).FullName)
Check 'dav1d DLL' ((Get-ChildItem -LiteralPath (Join-Path $root 'build\Release') -Filter '*dav1d*.dll' -File -ErrorAction SilentlyContinue | Select-Object -First 1).FullName)
$bad = Get-ChildItem -LiteralPath $root -Recurse -Include '*.ps1','*.cmd','*.bat','*.txt','*.config' -File -ErrorAction SilentlyContinue | Select-String -Pattern 'natove' -SimpleMatch -ErrorAction SilentlyContinue
if ($bad) { Write-Host 'WARN natove typo found:' -ForegroundColor Yellow; $bad | ForEach-Object { Write-Host $_.Path ':' $_.LineNumber ':' $_.Line } } else { Write-Host 'OK   no natove typo found' -ForegroundColor Green }
'@
Set-Content -LiteralPath (Join-Path $stage 'CHECK_PORTABLE.ps1') -Value $check -Encoding ASCII

$readme = @'
Jitsi NDI Portable v74c

Run: JitsiNDI.exe

Expected native path:
build\Release\jitsi-ndi-native.exe

If something fails, run:
powershell -ExecutionPolicy Bypass -File .\CHECK_PORTABLE.ps1

This package intentionally has no START_*.cmd launcher. JitsiNDI.exe is the main launcher.
'@
Set-Content -LiteralPath (Join-Path $stage 'README_PORTABLE.txt') -Value $readme -Encoding ASCII

$stageNative = Join-Path $stage 'build\Release\jitsi-ndi-native.exe'
if (-not (Test-Path -LiteralPath $stageNative)) {
    throw "Portable sanity check failed: native exe missing at $stageNative"
}
if (Test-Path -LiteralPath (Join-Path $stage 'jitsi-ndi-natove.exe')) {
    throw 'Portable sanity check failed: natove typo file exists in stage root.'
}

Write-Host "[v74c] Runtime DLLs copied/confirmed: $dllCount"
Write-Host "[v74c] Sanity check OK: $stageNative"

$zip = Join-Path $dist "JitsiNDI_Portable_v74c_$stamp.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -LiteralPath (Join-Path $stage '*') -DestinationPath $zip -Force
Write-Host "[v74c] Portable ZIP created: $zip"
