# =============================================================================
# Jitsi NDI Native - Portable Packager v104 (flat layout + firewall + tray icon)
# =============================================================================
# Run from repository root after a successful cmake --build.
# Creates dist\JitsiNDI_Portable_v104_<timestamp>\ and a .zip next to it.
#
# Key improvements vs v68:
#   - FLAT layout: jitsi-ndi-native.exe + ALL DLLs in portable root (no build\Release subdir)
#   - JitsiNDI.exe stays running as a system-tray app while GUI is open
#     => icon visible in Task Manager, tray, everywhere
#   - First-run firewall setup dialog (one UAC prompt, never again)
#   - SETUP_FIREWALL.cmd for manual admin setup
# =============================================================================

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$m) Write-Host "[v104] $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "[v104] OK   $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "[v104] WARN $m" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Find-RepoRoot {
    $dirs = @((Get-Location).Path, (Split-Path -Parent $MyInvocation.ScriptName),
              (Split-Path -Parent (Split-Path -Parent $MyInvocation.ScriptName))) |
            Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
    foreach ($d in $dirs) {
        if ((Test-Path "$d\JitsiNdiGui.ps1") -and (Test-Path "$d\src")) { return (Resolve-Path $d).Path }
    }
    throw 'Repo root not found. Run from inside jitsi-ndi-native folder.'
}

function Find-NativeExe([string]$root) {
    $c = @("$root\build\Release\jitsi-ndi-native.exe",
           "$root\build-ndi\Release\jitsi-ndi-native.exe",
           "$root\build\RelWithDebInfo\jitsi-ndi-native.exe",
           "$root\build-ndi\RelWithDebInfo\jitsi-ndi-native.exe")
    foreach ($p in $c) { if (Test-Path $p) { return (Resolve-Path $p).Path } }
    throw 'jitsi-ndi-native.exe not found. Run cmake --build build --config Release first.'
}

function Copy-UniqueDll([string]$src, [string]$dstDir, [System.Collections.Generic.HashSet[string]]$seen) {
    if (-not (Test-Path $src)) { return }
    $n = Split-Path -Leaf $src
    if ($seen.Contains($n)) { return }
    $null = $seen.Add($n)
    Copy-Item -LiteralPath $src -Destination "$dstDir\$n" -Force
}

function Collect-Dlls([string]$root, [string]$nativeDir, [string]$outDir) {
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # build output first (highest priority)
    Get-ChildItem -LiteralPath $nativeDir -File -Filter '*.dll' -EA SilentlyContinue |
        ForEach-Object { Copy-UniqueDll $_.FullName $outDir $seen }

    # vcpkg bins
    @("$root\vcpkg_installed\x64-windows\bin",
      "$root\build\vcpkg_installed\x64-windows\bin",
      "$root\build-ndi\vcpkg_installed\x64-windows\bin") | ForEach-Object {
        if (Test-Path $_) {
            Get-ChildItem -LiteralPath $_ -File -Filter '*.dll' -EA SilentlyContinue |
                ForEach-Object { Copy-UniqueDll $_.FullName $outDir $seen }
        }
    }

    # all DLLs under build trees
    @('build','build-ndi') | ForEach-Object {
        $bd = "$root\$_"
        if (Test-Path $bd) {
            Get-ChildItem -LiteralPath $bd -Recurse -File -Filter '*.dll' -EA SilentlyContinue |
                Where-Object { $_.FullName -notmatch '\\dist\\|\\CMakeFiles\\' } |
                ForEach-Object { Copy-UniqueDll $_.FullName $outDir $seen }
        }
    }

    # VC++ runtime
    @('vcruntime140.dll','vcruntime140_1.dll','vcruntime140_threads.dll',
      'msvcp140.dll','msvcp140_1.dll','msvcp140_2.dll',
      'msvcp140_atomic_wait.dll','msvcp140_codecvt_ids.dll',
      'concrt140.dll','vcomp140.dll','vccorlib140.dll') | ForEach-Object {
        $n = $_
        @("$env:WINDIR\System32\$n","$env:WINDIR\SysWOW64\$n") | ForEach-Object {
            if (Test-Path $_) { Copy-UniqueDll $_ $outDir $seen }
        }
    }

    # NDI DLL
    $ndi = 'Processing.NDI.Lib.x64.dll'
    $ndiOk = $false
    @("$nativeDir\$ndi","$root\$ndi",
      "$env:ProgramFiles\NDI\NDI 6 Runtime\v6\$ndi",
      "$env:ProgramFiles\NDI\NDI 5 Runtime\v5\$ndi",
      "$env:ProgramFiles\NDI\NDI Runtime\$ndi",
      "$env:ProgramFiles\NewTek\NDI 5 Runtime\v5\$ndi",
      "$env:ProgramFiles\NewTek\NDI 4 Runtime\v4\$ndi") | ForEach-Object {
        if (-not $ndiOk -and $_ -and (Test-Path $_)) {
            Copy-UniqueDll $_ $outDir $seen
            Write-Ok "NDI DLL: $_"; $ndiOk = $true
        }
    }
    if (-not $ndiOk) {
        $f = Get-ChildItem -LiteralPath $root -Recurse -File -Filter $ndi -EA SilentlyContinue |
             Where-Object { $_.FullName -notmatch '\\dist\\' } | Select-Object -First 1
        if ($f) { Copy-UniqueDll $f.FullName $outDir $seen; Write-Ok "NDI DLL (repo): $($f.FullName)"; $ndiOk = $true }
    }
    if (-not $ndiOk) { Write-Warn "Processing.NDI.Lib.x64.dll NOT FOUND - NDI won't work without NDI Runtime installed." }

    return $seen.Count
}

function Patch-PortableGui([string]$guiPath) {
    $txt = Get-Content -LiteralPath $guiPath -Raw -Encoding UTF8
    $txt = $txt -replace '\$psi\.CreateNoWindow\s*=\s*\$false', '$psi.CreateNoWindow = $true'
    $txt = $txt -replace '\$psi\.CreateNoWindow\s*=\s*\$False', '$psi.CreateNoWindow = $true'
    $marker = '# V104_PATH_PATCH'
    $needle = '$psi.WorkingDirectory = Split-Path -Parent $exe'
    if ($txt.Contains($needle) -and -not $txt.Contains($marker)) {
        $patch = '$psi.WorkingDirectory = Split-Path -Parent $exe' + "`r`n" +
                 '        # V104_PATH_PATCH' + "`r`n" +
                 '        try {' + "`r`n" +
                 '            $portDir = Split-Path -Parent $exe' + "`r`n" +
                 '            $oldPath = $psi.EnvironmentVariables[''PATH'']' + "`r`n" +
                 '            if ([string]::IsNullOrWhiteSpace($oldPath)) { $oldPath = $env:PATH }' + "`r`n" +
                 '            $psi.EnvironmentVariables[''PATH''] = $portDir + '';'' + $oldPath' + "`r`n" +
                 '        } catch {}'
        $txt = $txt.Replace($needle, $patch)
    }
    Set-Content -LiteralPath $guiPath -Value $txt -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Build JitsiNDI.exe - C# launcher that lives in the system tray
# NOTE: the here-string closing '@ MUST be at column 0, no spaces before it.
# ---------------------------------------------------------------------------
function Build-Launcher([string]$outExe, [string]$iconSrc) {

$csCode = @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Windows.Forms;
using System.Threading;

namespace JitsiNDILauncher {
    static class Program {
        static NotifyIcon _tray;
        static Process _gui;

        [STAThread]
        static void Main() {
            bool isNew;
            var mtx = new Mutex(true, "JitsiNDI_Portable_v104", out isNew);
            if (!isNew) return;

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            string baseDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\', '/');

            // --- One-time firewall setup ---
            string marker = Path.Combine(baseDir, "firewall_configured.txt");
            if (!File.Exists(marker)) {
                var ans = MessageBox.Show(
                    "NDI sources need Windows Firewall access to appear on other PCs.\n\n" +
                    "Click YES to add firewall rules automatically (admin required).\n" +
                    "Click NO to skip (NDI may not be visible on other PCs).",
                    "Jitsi NDI - Firewall Setup",
                    MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                if (ans == DialogResult.Yes)
                    AddFirewallRules(Path.Combine(baseDir, "jitsi-ndi-native.exe"));
                try { File.WriteAllText(marker, DateTime.Now.ToString()); } catch { }
            }

            // --- Check GUI script ---
            string ps1 = Path.Combine(baseDir, "JitsiNdiGui.ps1");
            if (!File.Exists(ps1)) {
                MessageBox.Show("JitsiNdiGui.ps1 not found next to JitsiNDI.exe.\nPortable folder may be incomplete.",
                    "Jitsi NDI - Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            // --- Tray icon ---
            Icon ico = null;
            try {
                string icoFile = Path.Combine(baseDir, "gui", "icon.ico");
                if (File.Exists(icoFile)) ico = new Icon(icoFile);
            } catch { }
            if (ico == null) ico = SystemIcons.Application;

            _tray = new NotifyIcon { Icon = ico, Text = "Jitsi NDI", Visible = true };
            var menu = new ContextMenuStrip();
            menu.Items.Add("Show window", null, (s, e) => BringGui());
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Exit", null, (s, e) => Quit());
            _tray.ContextMenuStrip = menu;
            _tray.DoubleClick += (s, e) => BringGui();

            // --- Launch PowerShell GUI ---
            string ps = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                @"System32\WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(ps)) ps = "powershell.exe";

            var psi = new ProcessStartInfo {
                FileName = ps,
                Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + ps1 + "\"",
                WorkingDirectory = baseDir,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };

            try { _gui = Process.Start(psi); }
            catch (Exception ex) {
                _tray.Visible = false;
                MessageBox.Show("Failed to start Jitsi NDI GUI.\n\n" + ex.Message,
                    "Jitsi NDI - Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            // Poll: exit when PowerShell GUI is gone
            var t = new System.Windows.Forms.Timer { Interval = 2000 };
            t.Tick += (s, e) => { if (_gui == null || _gui.HasExited) Quit(); };
            t.Start();

            Application.Run();
            mtx.ReleaseMutex();
        }

        static void BringGui() {
            if (_gui == null || _gui.HasExited) return;
            try {
                IntPtr h = _gui.MainWindowHandle;
                if (h != IntPtr.Zero) SetForegroundWindow(h);
            } catch { }
        }

        static void Quit() {
            if (_tray != null) { _tray.Visible = false; _tray.Dispose(); _tray = null; }
            Application.Exit();
        }

        static void AddFirewallRules(string exe) {
            string[] rules = {
                "advfirewall firewall add rule name=\"Jitsi NDI Native IN\"  dir=in  action=allow program=\"" + exe + "\" enable=yes profile=any",
                "advfirewall firewall add rule name=\"Jitsi NDI Native OUT\" dir=out action=allow program=\"" + exe + "\" enable=yes profile=any"
            };
            foreach (var r in rules) {
                try {
                    var p = Process.Start(new ProcessStartInfo {
                        FileName = "netsh", Arguments = r,
                        Verb = "runas", UseShellExecute = true,
                        WindowStyle = ProcessWindowStyle.Hidden
                    });
                    if (p != null) p.WaitForExit(10000);
                } catch { }
            }
        }

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        static extern bool SetForegroundWindow(IntPtr hWnd);
    }
}
'@

    $tmpCs  = [IO.Path]::ChangeExtension($outExe, '.cs')
    [IO.File]::WriteAllText($tmpCs, $csCode, [System.Text.Encoding]::ASCII)

    $csc = @(
        "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
        "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $csc) {
        Write-Warn 'csc.exe not found - JitsiNDI.exe launcher will not be built (install .NET Framework build tools).'
        Remove-Item -Force $tmpCs -EA SilentlyContinue
        return $false
    }

    $icoArg = @()
    if ($iconSrc -and (Test-Path $iconSrc)) { $icoArg = @("/win32icon:`"$iconSrc`"") }
    $refs = @('/reference:System.Windows.Forms.dll', '/reference:System.Drawing.dll')

    $result = & $csc /nologo /target:winexe "/out:$outExe" @icoArg @refs $tmpCs 2>&1
    $ok = ($LASTEXITCODE -eq 0)
    Remove-Item -Force $tmpCs -EA SilentlyContinue
    if ($result) { Write-Step "csc output: $result" }
    if (-not $ok) { Write-Warn "csc.exe exited $LASTEXITCODE - launcher may not have been built." }
    return $ok
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
$root      = Find-RepoRoot
$guiSrc    = "$root\JitsiNdiGui.ps1"
$nativeExe = Find-NativeExe $root
$nativeDir = Split-Path -Parent $nativeExe
$iconSrc   = "$root\gui\icon.ico"

Write-Step "Repo root  : $root"
Write-Step "Native exe : $nativeExe"

$ts      = Get-Date -Format 'yyyyMMdd_HHmmss'
$stage   = "$root\dist\JitsiNDI_Portable_v104_$ts"
$zipPath = "$stage.zip"

if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force -Path $stage        | Out-Null
New-Item -ItemType Directory -Force -Path "$stage\logs" | Out-Null

# GUI (patched copy - original in repo is NEVER touched)
Write-Step 'Copying and patching GUI...'
Copy-Item -LiteralPath $guiSrc -Destination "$stage\JitsiNdiGui.ps1" -Force
Patch-PortableGui "$stage\JitsiNdiGui.ps1"

# Native exe (flat in root)
Write-Step 'Copying native exe...'
Copy-Item -LiteralPath $nativeExe -Destination "$stage\jitsi-ndi-native.exe" -Force

# DLLs (flat in root)
Write-Step 'Collecting DLLs...'
$n = Collect-Dlls $root $nativeDir $stage
Write-Ok "Copied $n DLLs to portable root."

# gui/ folder (fonts, icon)
if (Test-Path "$root\gui") {
    Write-Step 'Copying gui/ folder...'
    Copy-Item -Recurse -Force "$root\gui" "$stage\gui"
}

# Launcher exe
Write-Step 'Building JitsiNDI.exe (tray launcher)...'
$launcherOk = Build-Launcher "$stage\JitsiNDI.exe" $iconSrc
if ($launcherOk) { Write-Ok 'JitsiNDI.exe built with icon.' }

# SETUP_FIREWALL.cmd
Set-Content -LiteralPath "$stage\SETUP_FIREWALL.cmd" -Encoding ASCII -Value @'
@echo off
echo Jitsi NDI - Adding Windows Firewall rules (run as Administrator)
netsh advfirewall firewall add rule name="Jitsi NDI Native IN"  dir=in  action=allow program="%~dp0jitsi-ndi-native.exe" enable=yes profile=any
netsh advfirewall firewall add rule name="Jitsi NDI Native OUT" dir=out action=allow program="%~dp0jitsi-ndi-native.exe" enable=yes profile=any
echo Done.
pause
'@

# START_JITSI_NDI.cmd
Set-Content -LiteralPath "$stage\START_JITSI_NDI.cmd" -Encoding ASCII -Value ('@echo off' + "`r`n" + 'start "" "%~dp0JitsiNDI.exe"')

# CHECK_PORTABLE.ps1
Set-Content -LiteralPath "$stage\CHECK_PORTABLE.ps1" -Encoding UTF8 -Value @'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Write-Host "=== Jitsi NDI Portable v104 ===" -ForegroundColor Cyan
Write-Host "Root: $root"; Write-Host ""
$req = @('JitsiNDI.exe','JitsiNdiGui.ps1','jitsi-ndi-native.exe',
         'Processing.NDI.Lib.x64.dll','vcruntime140.dll','msvcp140.dll',
         'avcodec-62.dll','dav1d.dll','opus.dll','datachannel.dll')
$ok = $true
foreach ($f in $req) {
    $p = Join-Path $root $f
    if (Test-Path $p) { Write-Host "  OK   $f" -ForegroundColor Green }
    else { Write-Host "  MISS $f" -ForegroundColor Red; $ok = $false }
}
$dlls = (Get-ChildItem $root -Filter '*.dll' -EA SilentlyContinue).Count
Write-Host ""; Write-Host "Total DLLs: $dlls"
$fw = netsh advfirewall firewall show rule name="Jitsi NDI Native IN" 2>&1
Write-Host ""
if ($fw -match 'Jitsi NDI') { Write-Host "Firewall: rule found" -ForegroundColor Green }
else { Write-Host "Firewall: rule MISSING - run SETUP_FIREWALL.cmd as admin!" -ForegroundColor Yellow }
Write-Host ""
if ($ok) { Write-Host "All required files present." -ForegroundColor Green }
else { Write-Host "Some files missing - rebuild portable." -ForegroundColor Red }
'@

# README
Set-Content -LiteralPath "$stage\README_PORTABLE.txt" -Encoding UTF8 -Value @'
Jitsi NDI Native - Portable v104
=================================

LAUNCH:  JitsiNDI.exe

On first run you will be asked to allow Windows Firewall access.
Click YES (admin required, one-time only).
If you skipped it - run SETUP_FIREWALL.cmd as Administrator.

FILES:
  JitsiNDI.exe             - launcher (stays in tray while running)
  JitsiNdiGui.ps1          - GUI
  jitsi-ndi-native.exe     - native engine
  SETUP_FIREWALL.cmd       - firewall setup (run as Admin if needed)
  CHECK_PORTABLE.ps1       - diagnostics

NDI NOT VISIBLE ON OTHER PCs:
  1. Run SETUP_FIREWALL.cmd as Administrator
  2. All PCs must be on the same LAN (no VPN without multicast)
  3. Wait 10-15 seconds after connecting
  4. Refresh sources in NDI Studio Monitor

LOGS: logs\ folder next to JitsiNDI.exe
'@

# ZIP
Write-Step 'Creating ZIP...'
if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
Compress-Archive -Path "$stage\*" -DestinationPath $zipPath -Force

# Final report
Write-Host ""
Write-Host "=== Build report ===" -ForegroundColor Cyan
$req = @('JitsiNDI.exe','JitsiNdiGui.ps1','jitsi-ndi-native.exe',
         'Processing.NDI.Lib.x64.dll','vcruntime140.dll','msvcp140.dll',
         'avcodec-62.dll','dav1d.dll','opus.dll','datachannel.dll',
         'SETUP_FIREWALL.cmd','CHECK_PORTABLE.ps1')
foreach ($f in $req) {
    $p = "$stage\$f"
    if (Test-Path $p) { Write-Host "  OK   $f" -ForegroundColor Green }
    else              { Write-Host "  MISS $f" -ForegroundColor Red }
}
$dllCount = (Get-ChildItem $stage -Filter '*.dll' -EA SilentlyContinue).Count
Write-Host "  DLLs in root: $dllCount"
Write-Host ""
Write-Ok "Folder : $stage"
Write-Ok "Archive: $zipPath"
Write-Ok "Done."
