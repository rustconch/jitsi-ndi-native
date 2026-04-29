$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Log($msg) { Write-Host "[v74e] $msg" }

function Find-ProjectRoot {
    $d = Get-Item -LiteralPath $PSScriptRoot
    for ($i = 0; $i -lt 8 -and $null -ne $d; $i++) {
        $p = $d.FullName
        if ((Test-Path -LiteralPath (Join-Path $p 'JitsiNdiGui.ps1')) -and (Test-Path -LiteralPath (Join-Path $p 'build'))) {
            return $p
        }
        if ((Test-Path -LiteralPath (Join-Path $p 'CMakeLists.txt')) -and (Test-Path -LiteralPath (Join-Path $p 'src'))) {
            return $p
        }
        $d = $d.Parent
    }
    throw 'Project root not found. Run this script from inside the jitsi-ndi-native repository.'
}

function Ensure-Dir($path) {
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
    }
}

function Copy-DirectoryContents($sourceDir, $destDir) {
    Ensure-Dir $destDir
    if (-not (Test-Path -LiteralPath $sourceDir)) { return }
    Get-ChildItem -LiteralPath $sourceDir -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $destDir -Recurse -Force
    }
}

function Copy-FirstFilesByPattern($scanDirs, $patterns, $destDir) {
    $copied = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($dir in $scanDirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($pattern in $patterns) {
            Get-ChildItem -LiteralPath $dir -Recurse -File -Filter $pattern -ErrorAction SilentlyContinue | ForEach-Object {
                $name = $_.Name.ToLowerInvariant()
                if ($copied.Contains($name)) { return }
                $dst = Join-Path $destDir $_.Name
                if (-not (Test-Path -LiteralPath $dst)) {
                    Copy-Item -LiteralPath $_.FullName -Destination $dst -Force
                }
                [void]$copied.Add($name)
            }
        }
    }
    return $copied.Count
}

function Find-NativeExe($root) {
    $preferred = Join-Path $root 'build\Release\jitsi-ndi-native.exe'
    if (Test-Path -LiteralPath $preferred) { return $preferred }

    $found = Get-ChildItem -LiteralPath $root -Recurse -File -Filter 'jitsi-ndi-native.exe' -ErrorAction SilentlyContinue |
        Sort-Object @{ Expression = { if ($_.FullName -like '*\build\Release\*') { 0 } else { 1 } } }, @{ Expression = 'LastWriteTime'; Descending = $true } |
        Select-Object -First 1

    if ($null -eq $found) {
        throw 'jitsi-ndi-native.exe not found. Build the native app first, for example: .\rebuild_with_dav1d_v21.ps1'
    }
    return $found.FullName
}

function Compile-Launcher($stageRoot) {
    $launcherExe = Join-Path $stageRoot 'JitsiNDI.exe'
    $launcherCs = Join-Path $stageRoot '_JitsiNDI_Launcher.cs'

    $source = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            string gui = Path.Combine(baseDir, "JitsiNdiGui.ps1");
            string native = Path.Combine(baseDir, "build", "Release", "jitsi-ndi-native.exe");

            if (!File.Exists(gui))
            {
                MessageBox.Show("JitsiNdiGui.ps1 not found next to JitsiNDI.exe", "Jitsi NDI", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 2;
            }

            if (!File.Exists(native))
            {
                MessageBox.Show("Native executable not found:\n" + native, "Jitsi NDI", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 3;
            }

            string path = Environment.GetEnvironmentVariable("PATH") ?? "";
            string releaseDir = Path.GetDirectoryName(native) ?? baseDir;
            Environment.SetEnvironmentVariable("PATH", releaseDir + Path.PathSeparator + baseDir + Path.PathSeparator + path);

            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = "powershell.exe";
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + gui + "\"";
            psi.WorkingDirectory = baseDir;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            Process.Start(psi);
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.ToString(), "Jitsi NDI launcher error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
'@

    Set-Content -LiteralPath $launcherCs -Value $source -Encoding UTF8

    $compiled = $false
    $compileErrors = New-Object System.Collections.Generic.List[string]

    try {
        Add-Type -AssemblyName Microsoft.CSharp -ErrorAction Stop
        $provider = New-Object Microsoft.CSharp.CSharpCodeProvider
        $params = New-Object System.CodeDom.Compiler.CompilerParameters
        $params.GenerateExecutable = $true
        $params.GenerateInMemory = $false
        $params.OutputAssembly = $launcherExe
        $params.CompilerOptions = '/target:winexe /optimize+'
        [void]$params.ReferencedAssemblies.Add('System.dll')
        [void]$params.ReferencedAssemblies.Add('System.Windows.Forms.dll')
        $results = $provider.CompileAssemblyFromSource($params, $source)
        if ($results.Errors.HasErrors) {
            $errText = ($results.Errors | ForEach-Object { $_.ToString() }) -join "`n"
            $compileErrors.Add("CodeDom: $errText")
        } elseif (Test-Path -LiteralPath $launcherExe) {
            $compiled = $true
            Log 'Launcher compiled with CodeDom.'
        }
    } catch {
        $compileErrors.Add('CodeDom exception: ' + $_.Exception.Message)
    }

    if (-not $compiled) {
        $cscCandidates = @(
            (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
            (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
        )
        $vsRoots = @(
            'C:\Program Files\Microsoft Visual Studio\2022',
            'C:\Program Files (x86)\Microsoft Visual Studio\2022'
        )
        foreach ($vs in $vsRoots) {
            if (Test-Path -LiteralPath $vs) {
                Get-ChildItem -LiteralPath $vs -Recurse -File -Filter 'csc.exe' -ErrorAction SilentlyContinue | ForEach-Object {
                    $script:cscCandidates += $_.FullName
                }
            }
        }

        foreach ($csc in ($cscCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)) {
            Log "Trying csc: $csc"
            $args = @(
                '/nologo',
                '/target:winexe',
                '/optimize+',
                "/out:$launcherExe",
                '/reference:System.dll',
                '/reference:System.Windows.Forms.dll',
                $launcherCs
            )
            & $csc @args
            if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $launcherExe)) {
                $compiled = $true
                Log 'Launcher compiled with csc.'
                break
            }
        }
    }

    if (-not (Test-Path -LiteralPath $launcherExe)) {
        $msg = 'Failed to compile JitsiNDI.exe launcher.'
        if ($compileErrors.Count -gt 0) { $msg += "`n" + ($compileErrors -join "`n") }
        throw $msg
    }

    Remove-Item -LiteralPath $launcherCs -Force -ErrorAction SilentlyContinue
    return $launcherExe
}

$root = Find-ProjectRoot
$root = (Resolve-Path -LiteralPath $root).ProviderPath
Log "Project root: $root"

$nativeExe = Find-NativeExe $root
Log "Native exe: $nativeExe"

$guiPs1 = Join-Path $root 'JitsiNdiGui.ps1'
if (-not (Test-Path -LiteralPath $guiPs1)) { throw 'JitsiNdiGui.ps1 not found in project root.' }

$dist = Join-Path $root 'dist'
Ensure-Dir $dist
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$stage = Join-Path $dist "JitsiNDI_Portable_v74e_$stamp"
$stageRelease = Join-Path $stage 'build\Release'
Ensure-Dir $stageRelease
Ensure-Dir (Join-Path $stage 'logs')

Log "Portable stage: $stage"

$releaseDir = Join-Path $root 'build\Release'
if (Test-Path -LiteralPath $releaseDir) {
    Log 'Copying full build\Release...'
    Copy-DirectoryContents $releaseDir $stageRelease
} else {
    Log 'build\Release does not exist; using found native exe folder only.'
}

# Force native exe into the exact portable path expected by GUI/launcher.
Copy-Item -LiteralPath $nativeExe -Destination (Join-Path $stageRelease 'jitsi-ndi-native.exe') -Force
Log 'Native exe force-copied.'

Copy-Item -LiteralPath $guiPs1 -Destination (Join-Path $stage 'JitsiNdiGui.ps1') -Force
Log 'Copied JitsiNdiGui.ps1.'

$guiFolder = Join-Path $root 'gui'
if (Test-Path -LiteralPath $guiFolder) {
    Copy-Item -LiteralPath $guiFolder -Destination (Join-Path $stage 'gui') -Recurse -Force
    Log 'Copied gui folder.'
}

$scanDirs = @(
    $releaseDir,
    (Join-Path $root 'build'),
    (Join-Path $root 'vcpkg_installed\x64-windows\bin'),
    (Join-Path $root 'build\vcpkg_installed\x64-windows\bin')
)

$dllPatterns = @(
    'avcodec*.dll','avformat*.dll','avutil*.dll','swscale*.dll','swresample*.dll',
    'dav1d*.dll','libdav1d*.dll','vpx*.dll','aom*.dll','SvtAv1*.dll',
    'datachannel.dll','rtc.dll','juice.dll','srtp*.dll','usrsctp*.dll',
    'ssl*.dll','crypto*.dll','zlib*.dll','zstd*.dll','bz2*.dll','lzma*.dll','iconv*.dll','libwinpthread*.dll',
    'vcruntime140.dll','vcruntime140_1.dll','msvcp140.dll','concrt140.dll','vcomp140.dll'
)
$copiedCount = Copy-FirstFilesByPattern $scanDirs $dllPatterns $stageRelease
Log "Runtime DLL names copied/confirmed: $copiedCount"

# NDI runtime: copy x64 only into build\Release. x86 is not needed for this x64 build.
$ndiSearchRoots = @(
    $releaseDir,
    (Join-Path $root 'build'),
    'C:\Program Files\NDI',
    'C:\Program Files (x86)\NDI'
)
$ndiFound = $false
foreach ($ndiRoot in $ndiSearchRoots) {
    if (-not (Test-Path -LiteralPath $ndiRoot)) { continue }
    Get-ChildItem -LiteralPath $ndiRoot -Recurse -File -Filter 'Processing.NDI.Lib.x64.dll' -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $stageRelease 'Processing.NDI.Lib.x64.dll') -Force
        Log "Copied NDI runtime: $($_.FullName)"
        $script:ndiFound = $true
    }
    if ($ndiFound) { break }
}
if (-not $ndiFound) { Log 'WARNING: Processing.NDI.Lib.x64.dll was not found. Portable may require NDI Runtime installed.' }

# Portable checker.
$check = @'
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$release = Join-Path $root 'build\Release'
Write-Host 'Jitsi NDI Portable check'
Write-Host "Root: $root"
$items = @(
    (Join-Path $root 'JitsiNDI.exe'),
    (Join-Path $root 'JitsiNdiGui.ps1'),
    (Join-Path $release 'jitsi-ndi-native.exe'),
    (Join-Path $release 'Processing.NDI.Lib.x64.dll')
)
foreach ($p in $items) {
    if (Test-Path -LiteralPath $p) { Write-Host "OK   $p" } else { Write-Host "MISS $p" }
}
Write-Host ''
Write-Host 'Runtime DLL count in build\Release:'
(Get-ChildItem -LiteralPath $release -File -Filter '*.dll' -ErrorAction SilentlyContinue | Measure-Object).Count
Write-Host ''
Write-Host 'Native exe quick version/path:'
Get-Item -LiteralPath (Join-Path $release 'jitsi-ndi-native.exe') -ErrorAction SilentlyContinue | Format-List FullName,Length,LastWriteTime
'@
Set-Content -LiteralPath (Join-Path $stage 'CHECK_PORTABLE.ps1') -Value $check -Encoding UTF8

$launcher = Compile-Launcher $stage
Log "Launcher created: $launcher"

# Sanity checks.
$must = @(
    (Join-Path $stage 'JitsiNDI.exe'),
    (Join-Path $stage 'JitsiNdiGui.ps1'),
    (Join-Path $stageRelease 'jitsi-ndi-native.exe')
)
foreach ($p in $must) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Portable sanity failed: missing $p" }
}

# Make sure typo does not exist in generated text files.
Get-ChildItem -LiteralPath $stage -Recurse -File -Include '*.ps1','*.txt','*.config','*.json' -ErrorAction SilentlyContinue | ForEach-Object {
    $txt = [System.IO.File]::ReadAllText($_.FullName)
    if ($txt -match 'natove') { throw "Portable sanity failed: typo natove found in $($_.FullName)" }
}

$zip = Join-Path $dist "JitsiNDI_Portable_v74e_$stamp.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
Log "Portable ZIP created: $zip"
Log 'Run on another PC by opening JitsiNDI.exe only.'
