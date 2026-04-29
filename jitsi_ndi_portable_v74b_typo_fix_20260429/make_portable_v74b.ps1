$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "[v74b] $msg" }
function Resolve-FullPath($p) { return (Resolve-Path -LiteralPath $p).Path }

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Resolve-FullPath (Join-Path $scriptRoot '..')
Set-Location -LiteralPath $projectRoot

$nativeRel = 'build\Release\jitsi-ndi-native.exe'
$nativeExe = Join-Path $projectRoot $nativeRel
$wrongNativeRel = 'build\Release\jitsi-ndi-natove.exe'
$wrongNativeExe = Join-Path $projectRoot $wrongNativeRel
$guiSrc = Join-Path $projectRoot 'JitsiNdiGui.ps1'

if (-not (Test-Path -LiteralPath $nativeExe)) {
    Write-Host ''
    Write-Host '[v74b][ERROR] Native exe was not found at the expected path:' -ForegroundColor Red
    Write-Host "  $nativeExe" -ForegroundColor Red
    if (Test-Path -LiteralPath $wrongNativeExe) {
        Write-Host ''
        Write-Host '[v74b][ERROR] Found typo-named exe instead:' -ForegroundColor Yellow
        Write-Host "  $wrongNativeExe" -ForegroundColor Yellow
        Write-Host 'Rename it to jitsi-ndi-native.exe or rebuild native.' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host 'Try rebuilding first:' -ForegroundColor Yellow
    Write-Host '  .\rebuild_with_dav1d_v21.ps1' -ForegroundColor Yellow
    throw 'jitsi-ndi-native.exe not found'
}

if (-not (Test-Path -LiteralPath $guiSrc)) {
    throw "JitsiNdiGui.ps1 not found: $guiSrc"
}

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$distDir = Join-Path $projectRoot 'dist'
New-Item -ItemType Directory -Force -Path $distDir | Out-Null
$stage = Join-Path $distDir "JitsiNDI_Portable_v74b_$timestamp"
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'logs') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'build\Release') | Out-Null

Write-Step "Project root: $projectRoot"
Write-Step "Portable stage: $stage"

# Copy GUI and remove known typo if it exists anywhere in the script.
Copy-Item -LiteralPath $guiSrc -Destination (Join-Path $stage 'JitsiNdiGui.ps1') -Force
$portableGui = Join-Path $stage 'JitsiNdiGui.ps1'
$guiText = [System.IO.File]::ReadAllText($portableGui, [System.Text.Encoding]::UTF8)
$guiText = $guiText.Replace('jitsi-ndi-natove.exe', 'jitsi-ndi-native.exe')
$guiText = $guiText.Replace('jitsi_ndi_natove.exe', 'jitsi_ndi_native.exe')
[System.IO.File]::WriteAllText($portableGui, $guiText, (New-Object System.Text.UTF8Encoding($false)))

# Copy the full Release folder. This is safer than guessing individual DLLs.
$releaseSrc = Join-Path $projectRoot 'build\Release'
Write-Step 'Copying build\Release...'
Copy-Item -LiteralPath (Join-Path $releaseSrc '*') -Destination (Join-Path $stage 'build\Release') -Recurse -Force

# Copy visual assets / fonts folder if present. Do not bundle anything that is not already in the user's project.
$guiFolder = Join-Path $projectRoot 'gui'
if (Test-Path -LiteralPath $guiFolder) {
    Write-Step 'Copying gui folder...'
    Copy-Item -LiteralPath $guiFolder -Destination (Join-Path $stage 'gui') -Recurse -Force
}

# Collect common runtime DLLs from known local build/vcpkg locations.
$runtimeDirs = @(
    (Join-Path $projectRoot 'vcpkg_installed\x64-windows\bin'),
    (Join-Path $projectRoot 'build\vcpkg_installed\x64-windows\bin'),
    (Join-Path $projectRoot 'build\_deps'),
    (Join-Path $projectRoot 'build'),
    (Join-Path $projectRoot 'build\Release')
) | Where-Object { Test-Path -LiteralPath $_ }

$patterns = @(
    '*.dll',
    'avcodec*.dll','avutil*.dll','swscale*.dll','swresample*.dll',
    'dav1d*.dll','libdav1d*.dll','vpx*.dll','aom*.dll','SvtAv1*.dll',
    'vcruntime140*.dll','msvcp140*.dll','concrt140*.dll'
)

$releaseDst = Join-Path $stage 'build\Release'
$copied = @{}
foreach ($dir in $runtimeDirs) {
    foreach ($pat in $patterns) {
        Get-ChildItem -LiteralPath $dir -Filter $pat -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            $name = $_.Name.ToLowerInvariant()
            if (-not $copied.ContainsKey($name)) {
                Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $releaseDst $_.Name) -Force -ErrorAction SilentlyContinue
                $copied[$name] = $true
            }
        }
    }
}
Write-Step ("Runtime DLLs copied/confirmed: " + $copied.Count)

# NDI runtime DLL search.
$ndiNames = @('Processing.NDI.Lib.x64.dll')
$ndiSearchRoots = @(
    $projectRoot,
    (Join-Path $projectRoot 'build'),
    (Join-Path $projectRoot 'build\Release'),
    'C:\Program Files\NDI',
    'C:\Program Files\NDI\NDI 6 SDK',
    'C:\Program Files\NDI\NDI 5 SDK',
    'C:\Program Files (x86)\NDI',
    'C:\Program Files\NewTek',
    'C:\Program Files (x86)\NewTek'
) | Where-Object { Test-Path -LiteralPath $_ }

foreach ($ndiName in $ndiNames) {
    if (-not (Test-Path -LiteralPath (Join-Path $releaseDst $ndiName))) {
        $foundNdi = $null
        foreach ($root in $ndiSearchRoots) {
            $foundNdi = Get-ChildItem -LiteralPath $root -Filter $ndiName -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($foundNdi) { break }
        }
        if ($foundNdi) {
            Copy-Item -LiteralPath $foundNdi.FullName -Destination (Join-Path $releaseDst $ndiName) -Force
            Write-Step "NDI runtime copied: $($foundNdi.FullName)"
        } else {
            Write-Host '[v74b][WARN] Processing.NDI.Lib.x64.dll was not found. Portable may require NDI Runtime on target PC.' -ForegroundColor Yellow
        }
    }
}

# Final typo scan/fix in portable text scripts.
Get-ChildItem -LiteralPath $stage -Include '*.ps1','*.txt','*.json','*.config' -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        $t = [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8)
        if ($t.Contains('jitsi-ndi-natove')) {
            $t = $t.Replace('jitsi-ndi-natove', 'jitsi-ndi-native')
            [System.IO.File]::WriteAllText($_.FullName, $t, (New-Object System.Text.UTF8Encoding($false)))
        }
    } catch {}
}

# Create Windows GUI launcher exe. It opens only the PowerShell GUI without a visible console.
$launcherSrc = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

public static class Program {
    [STAThread]
    public static void Main() {
        string baseDir = AppDomain.CurrentDomain.BaseDirectory;
        string gui = Path.Combine(baseDir, "JitsiNdiGui.ps1");
        string native = Path.Combine(baseDir, "build", "Release", "jitsi-ndi-native.exe");
        string typoNative = Path.Combine(baseDir, "build", "Release", "jitsi-ndi-natove.exe");

        if (!File.Exists(gui)) {
            MessageBox.Show("JitsiNdiGui.ps1 not found:\n" + gui, "Jitsi NDI", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }
        if (!File.Exists(native)) {
            string extra = File.Exists(typoNative) ? "\n\nTypo-named exe exists, but expected jitsi-ndi-native.exe:\n" + typoNative : "";
            MessageBox.Show("jitsi-ndi-native.exe not found:\n" + native + extra, "Jitsi NDI", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        string windir = Environment.GetEnvironmentVariable("WINDIR") ?? "C:\\Windows";
        string ps = Path.Combine(windir, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        if (!File.Exists(ps)) ps = "powershell.exe";

        var psi = new ProcessStartInfo();
        psi.FileName = ps;
        psi.WorkingDirectory = baseDir;
        psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + gui + "\"";
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WindowStyle = ProcessWindowStyle.Hidden;
        try {
            Process.Start(psi);
        } catch (Exception ex) {
            MessageBox.Show("Failed to start GUI:\n" + ex.Message, "Jitsi NDI", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
'@
$launcherCs = Join-Path $stage 'JitsiNDI_Launcher.cs'
[System.IO.File]::WriteAllText($launcherCs, $launcherSrc, (New-Object System.Text.UTF8Encoding($false)))
$launcherExe = Join-Path $stage 'JitsiNDI.exe'
try {
    Add-Type -TypeDefinition $launcherSrc -ReferencedAssemblies 'System.Windows.Forms.dll','System.Drawing.dll' -OutputAssembly $launcherExe -OutputType WindowsApplication
    Remove-Item -LiteralPath $launcherCs -Force -ErrorAction SilentlyContinue
    Write-Step 'JitsiNDI.exe launcher created.'
} catch {
    Write-Host '[v74b][ERROR] Failed to build JitsiNDI.exe launcher.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    throw
}

# Check script for target machine.
$check = @'
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$release = Join-Path $root 'build\Release'
function Check($label, $path) {
    if (Test-Path -LiteralPath $path) { Write-Host ("OK   " + $label) -ForegroundColor Green }
    else { Write-Host ("MISS " + $label + " -> " + $path) -ForegroundColor Red }
}
Write-Host 'Jitsi NDI portable check v74b'
Write-Host "Root: $root"
Check 'JitsiNDI.exe' (Join-Path $root 'JitsiNDI.exe')
Check 'JitsiNdiGui.ps1' (Join-Path $root 'JitsiNdiGui.ps1')
Check 'build\Release\jitsi-ndi-native.exe' (Join-Path $release 'jitsi-ndi-native.exe')
$wrong = Join-Path $release 'jitsi-ndi-natove.exe'
if (Test-Path -LiteralPath $wrong) { Write-Host "TYPO FOUND: $wrong" -ForegroundColor Red }
Check 'Processing.NDI.Lib.x64.dll' (Join-Path $release 'Processing.NDI.Lib.x64.dll')
$dlls = Get-ChildItem -LiteralPath $release -Filter '*.dll' -File -ErrorAction SilentlyContinue
Write-Host ("DLL count in build\Release: " + ($dlls.Count))
Write-Host ''
Write-Host 'Video-related DLLs:'
$dlls | Where-Object { $_.Name -match 'avcodec|avutil|swscale|swresample|dav1d|vpx|aom|SvtAv1|vcruntime|msvcp' } | Sort-Object Name | ForEach-Object { Write-Host ('  ' + $_.Name) }
Write-Host ''
Write-Host 'Typo scan:'
$hits = Get-ChildItem -LiteralPath $root -Include '*.ps1','*.txt','*.json','*.config','*.cs' -File -Recurse -ErrorAction SilentlyContinue | Select-String -Pattern 'jitsi-ndi-natove' -SimpleMatch -ErrorAction SilentlyContinue
if ($hits) { $hits | ForEach-Object { Write-Host ("TYPO REF: " + $_.Path + ':' + $_.LineNumber) -ForegroundColor Red } } else { Write-Host 'OK   no jitsi-ndi-natove references found' -ForegroundColor Green }
'@
[System.IO.File]::WriteAllText((Join-Path $stage 'CHECK_PORTABLE.ps1'), $check, (New-Object System.Text.UTF8Encoding($false)))

$readme = @'
Jitsi NDI Portable v74b

Run:
  JitsiNDI.exe

There is no CMD launcher in this package.
The launcher opens only the GUI and does not show a separate PowerShell console.

Important expected native path:
  build\Release\jitsi-ndi-native.exe

If something fails, run:
  powershell -ExecutionPolicy Bypass -File .\CHECK_PORTABLE.ps1

Logs are saved in:
  logs
'@
[System.IO.File]::WriteAllText((Join-Path $stage 'README_PORTABLE.txt'), $readme, (New-Object System.Text.UTF8Encoding($false)))

# Safety: ensure typo file name does not exist in stage.
$stageWrong = Join-Path $stage 'build\Release\jitsi-ndi-natove.exe'
if (Test-Path -LiteralPath $stageWrong) {
    Remove-Item -LiteralPath $stageWrong -Force
}
if (-not (Test-Path -LiteralPath (Join-Path $stage 'build\Release\jitsi-ndi-native.exe'))) {
    throw 'Portable sanity check failed: jitsi-ndi-native.exe missing in stage.'
}

$zipPath = Join-Path $distDir ("JitsiNDI_Portable_v74b_$timestamp.zip")
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Write-Step 'Creating portable zip...'
Compress-Archive -LiteralPath (Join-Path $stage '*') -DestinationPath $zipPath -Force
Write-Host ''
Write-Host '[v74b] Portable archive created:' -ForegroundColor Green
Write-Host "  $zipPath" -ForegroundColor Green
Write-Host ''
Write-Host 'On another PC: unzip and run JitsiNDI.exe' -ForegroundColor Green
