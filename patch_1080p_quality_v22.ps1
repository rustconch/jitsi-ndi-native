$ErrorActionPreference = 'Stop'

function Fail($msg) {
  Write-Host "[v22][ERROR] $msg" -ForegroundColor Red
  exit 1
}

$root = (Get-Location).Path
Write-Host "[v22] Repository root: $root"

$native = Join-Path $root 'src\NativeWebRTCAnswerer.cpp'
$apph = Join-Path $root 'src\AppConfig.h'

if (!(Test-Path $native)) { Fail "src\NativeWebRTCAnswerer.cpp not found. Run this from D:\MEDIA\Desktop\jitsi-ndi-native" }

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
Copy-Item $native "$native.bak_v22_$stamp" -Force
Write-Host "[v22] Backup: $native.bak_v22_$stamp"

$src = Get-Content $native -Raw -Encoding UTF8
$orig = $src

# 1) Ask Jitsi Videobridge for 1080p instead of 720p.
# Existing code routes all ReceiverVideoConstraints through makeReceiverVideoConstraintsMessage(sourceNames, 720).
$src = $src -replace 'makeReceiverVideoConstraintsMessage\(sourceNames,\s*720\)', 'makeReceiverVideoConstraintsMessage(sourceNames, 1080)'

# 2) Give JVB a larger assumed receive bandwidth budget, so it does not choose low-quality layers too eagerly.
$src = $src -replace '"assumedBandwidthBps":\s*20000000', '"assumedBandwidthBps":60000000'
$src = $src -replace '\\"assumedBandwidthBps\\":20000000', '\"assumedBandwidthBps\":60000000'
$src = $src -replace 'out\s*<<\s*"\\"assumedBandwidthBps\\":20000000,";', 'out << "\"assumedBandwidthBps\":60000000,";'

# 3) Make repeated video constraint refresh a bit more persistent.
# This helps after JVB/source changes and prevents falling back to lower layers after reconnection/forwarded-source changes.
$oldVideoRefresh = @'
        const int delaysMs[] = {
            250,
            750,
            1500,
            3000,
            6000,
            10000,
            15000,
            20000
        };
'@
$newVideoRefresh = @'
        const int delaysMs[] = {
            250,
            750,
            1500,
            3000,
            6000,
            10000,
            15000,
            20000,
            30000,
            45000,
            60000
        };
'@
if ($src.Contains($oldVideoRefresh)) {
  $src = $src.Replace($oldVideoRefresh, $newVideoRefresh)
}

# 4) Add/refresh an explicit log marker near constraints sending, without spamming every packet.
# If the exact function body exists, add one clear log before the bridge message send.
$oldSendBlock = @'
void sendReceiverVideoConstraints(
    const std::shared_ptr<rtc::DataChannel>& channel,
    const std::vector<std::string>& sourceNames,
    const std::string& reason
) {
    sendBridgeMessage(
        channel,
        makeReceiverVideoConstraintsMessage(sourceNames, 1080),
        "ReceiverVideoConstraints/" + reason
    );
}
'@
$newSendBlock = @'
void sendReceiverVideoConstraints(
    const std::shared_ptr<rtc::DataChannel>& channel,
    const std::vector<std::string>& sourceNames,
    const std::string& reason
) {
    Logger::info(
        "NativeWebRTCAnswerer: requesting 1080p video constraints, sources=",
        sourceNames.size(),
        " reason=",
        reason
    );

    sendBridgeMessage(
        channel,
        makeReceiverVideoConstraintsMessage(sourceNames, 1080),
        "ReceiverVideoConstraints/" + reason
    );
}
'@
if ($src.Contains($oldSendBlock)) {
  $src = $src.Replace($oldSendBlock, $newSendBlock)
}

if ($src -eq $orig) {
  Fail "No changes were applied to NativeWebRTCAnswerer.cpp. The file layout is different than expected."
}

Set-Content $native $src -Encoding UTF8
Write-Host "[v22] Patched NativeWebRTCAnswerer.cpp: 1080p constraints + 60 Mbps assumed bandwidth."

# Optional: default test/status pattern to 1080 too. This does not affect received WebRTC quality,
# but keeps fallback/status output aligned with 1080p if no decoded media is available.
if (Test-Path $apph) {
  Copy-Item $apph "$apph.bak_v22_$stamp" -Force
  $h = Get-Content $apph -Raw -Encoding UTF8
  $h2 = $h -replace 'int\s+width\s*=\s*1280\s*;', 'int width = 1920;'
  $h2 = $h2 -replace 'int\s+height\s*=\s*720\s*;', 'int height = 1080;'
  if ($h2 -ne $h) {
    Set-Content $apph $h2 -Encoding UTF8
    Write-Host "[v22] Patched AppConfig.h default status size to 1920x1080."
  }
}

Write-Host "[v22] Building Release..."
cmake --build build --config Release
if ($LASTEXITCODE -ne 0) { Fail "Build failed" }

# Copy the runtime DLLs again, because rebuilt FFmpeg/libdav1d/datachannel must be next to exe.
$copyScript = Join-Path $root 'copy_runtime_dlls_v21.ps1'
if (Test-Path $copyScript) {
  Write-Host "[v22] Running existing v21 runtime DLL copier..."
  powershell -ExecutionPolicy Bypass -File $copyScript
} else {
  Write-Host "[v22] copy_runtime_dlls_v21.ps1 not found; copying common DLLs manually."
  $dst = Join-Path $root 'build\Release'
  if (Test-Path "$root\build\_deps\libdatachannel-build\Release\datachannel.dll") {
    Copy-Item "$root\build\_deps\libdatachannel-build\Release\datachannel.dll" $dst -Force
  }

  $vcpkgBins = @(
    "$env:VCPKG_ROOT\installed\x64-windows\bin",
    "D:\MEDIA\Desktop\vcpkg\installed\x64-windows\bin",
    "C:\vcpkg\installed\x64-windows\bin"
  ) | Where-Object { $_ -and (Test-Path $_) }

  foreach ($bin in $vcpkgBins) {
    Write-Host "[v22] Copying DLLs from $bin"
    Copy-Item "$bin\*.dll" $dst -Force -ErrorAction SilentlyContinue
  }

  $ndiDll = Get-ChildItem "C:\Program Files", "C:\Program Files (x86)" -Recurse -Filter "Processing.NDI.Lib.x64.dll" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($ndiDll) { Copy-Item $ndiDll.FullName $dst -Force }
}

Write-Host ""
Write-Host "[v22] Done. Run:" -ForegroundColor Green
Write-Host "  .\build\Release\jitsi-ndi-native.exe --room 6767676766767penxyi"
Write-Host ""
Write-Host "[v22] In logs check for:"
Write-Host "  NativeWebRTCAnswerer: requesting 1080p video constraints"
Write-Host "  maxEnabledResolution: 1080 in EndpointStats, if senders/JVB provide 1080"
Write-Host "  decoded/sent NDI frame dimensions should become 1920x1080 if remote camera/source publishes 1080p"
