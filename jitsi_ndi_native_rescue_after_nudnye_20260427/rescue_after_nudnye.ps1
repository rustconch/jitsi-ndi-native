$ErrorActionPreference = 'Stop'

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Text
    )
    $resolved = (Resolve-Path $Path).Path
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($resolved, $Text, $enc)
}

$root = (Get-Location).Path
$ndiFile = Join-Path $root 'src\NDISender.cpp'
$routerFile = Join-Path $root 'src\PerParticipantNdiRouter.cpp'

if (!(Test-Path $ndiFile)) { throw "Missing file: $ndiFile" }
if (!(Test-Path $routerFile)) { throw "Missing file: $routerFile" }

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupDir = Join-Path $root "_jnn_rescue_backup_$stamp"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
Copy-Item -Force $ndiFile (Join-Path $backupDir 'NDISender.cpp')
Copy-Item -Force $routerFile (Join-Path $backupDir 'PerParticipantNdiRouter.cpp')

Write-Host "Backup created: $backupDir"

# 1) Revert the experimental NDI runtime refcount patch from NDISender.cpp.
$ndi = [System.IO.File]::ReadAllText($ndiFile)
$beforeNdi = $ndi

# Remove the extra include if it exists.
$ndi = [regex]::Replace($ndi, '(?m)^\s*#include\s+<mutex>\s*\r?\n', '')

# Remove the helper namespace inserted by the previous patch, if present.
$runtimeBlockPattern = '(?s)\r?\n\s*namespace\s*\{\s*std::mutex\s+g_ndiRuntimeMutex;\s*int\s+g_ndiRuntimeUsers\s*=\s*0;\s*bool\s+acquireNdiRuntime\s*\(\s*\)\s*\{.*?\}\s*void\s+releaseNdiRuntime\s*\(\s*\)\s*\{.*?\}\s*\}\s*//\s*namespace\s*\r?\n'
$ndi = [regex]::Replace($ndi, $runtimeBlockPattern, "`r`n")

# Put direct NDI init/destroy calls back.
$ndi = $ndi.Replace('if (!acquireNdiRuntime())', 'if (!NDIlib_initialize())')
$ndi = $ndi.Replace('releaseNdiRuntime();', 'NDIlib_destroy();')

if ($ndi -ne $beforeNdi) {
    Write-Utf8NoBom -Path $ndiFile -Text $ndi
    Write-Host 'NDISender.cpp: reverted experimental NDI runtime refcount changes.'
} else {
    Write-Host 'NDISender.cpp: no refcount changes found; left as-is.'
}

# 2) Keep only the safe AV1 syntax fix in PerParticipantNdiRouter.cpp.
$router = [System.IO.File]::ReadAllText($routerFile)
$beforeRouter = $router

$badAv1Pattern = 'if\s*\(\(p\.videoPackets\s*%\s*300\)\s*==\s*0\)\s*//\s*PATCH_V10_AUDIO_PLANAR_CLOCK:\s*throttle\s+AV1\s+frame\s+logs;\s+do\s+not\s+spam\s+console\s+every\s+frame\s*\{'
$goodAv1Line = "// PATCH_V10_AUDIO_PLANAR_CLOCK: throttle AV1 frame logs; do not spam console every frame.`r`n  if ((p.videoPackets % 300) == 0) {"
$router = [regex]::Replace($router, $badAv1Pattern, $goodAv1Line)

if ($router -ne $beforeRouter) {
    Write-Utf8NoBom -Path $routerFile -Text $router
    Write-Host 'PerParticipantNdiRouter.cpp: fixed AV1 log if-line.'
} else {
    Write-Host 'PerParticipantNdiRouter.cpp: broken AV1 if-line was not found; left as-is.'
}

Write-Host ''
Write-Host 'Sanity check:'
Select-String -Path $ndiFile -Pattern 'acquireNdiRuntime|releaseNdiRuntime|g_ndiRuntime|#include <mutex>' -SimpleMatch -ErrorAction SilentlyContinue | ForEach-Object { $_.Line }
Select-String -Path $routerFile -Pattern 'PATCH_V10_AUDIO_PLANAR_CLOCK|if ((p.videoPackets % 300) == 0)' -SimpleMatch -Context 1,1 | ForEach-Object { $_.ToString() }

Write-Host ''
Write-Host 'Now run: cmake --build build --config Release'
