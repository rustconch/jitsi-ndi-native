$ErrorActionPreference = 'Stop'

function Fail($msg) {
  Write-Host "[v26][ERROR] $msg" -ForegroundColor Red
  exit 1
}

function Backup-File($path, $stamp) {
  if (Test-Path $path) {
    Copy-Item $path "$path.bak_v26_$stamp" -Force
    Write-Host "[v26] Backup: $path.bak_v26_$stamp"
  }
}

$root = (Get-Location).Path
Write-Host "[v26] Repository root: $root"

$native = Join-Path $root 'src\NativeWebRTCAnswerer.cpp'
if (!(Test-Path $native)) { Fail "src\NativeWebRTCAnswerer.cpp not found. Run this script from repository root." }

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
Backup-File $native $stamp

$src = Get-Content $native -Raw -Encoding UTF8
$orig = $src

# Remove an older v26 helper if the patch is run twice.
$src = [regex]::Replace(
  $src,
  '(?s)\r?\nstd::vector<std::string>\s+normalizeVideoSourceNamesForConstraints\s*\(const\s+std::vector<std::string>&\s+sourceNames\)\s*\{.*?\n\}\s*(?=\r?\nstd::string\s+makeReceiverVideoConstraintsMessage)',
  "`r`n"
)

# Equal-quality source-name constraints for all real speaker video sources.
$newMake = @'
std::vector<std::string> normalizeVideoSourceNamesForConstraints(const std::vector<std::string>& sourceNames) {
    std::vector<std::string> out;

    for (const auto& name : sourceNames) {
        if (name.empty()) {
            continue;
        }

        // Do not spend the high-quality budget on the JVB mixed placeholder.
        // We want real per-participant camera sources like 2eba7589-v0.
        if (name.size() >= 4 && name.compare(0, 4, "jvb-") == 0) {
            continue;
        }

        bool alreadyPresent = false;
        for (const auto& existing : out) {
            if (existing == name) {
                alreadyPresent = true;
                break;
            }
        }

        if (!alreadyPresent) {
            out.push_back(name);
        }
    }

    return out;
}

std::string makeReceiverVideoConstraintsMessage(
    const std::vector<std::string>& sourceNames,
    int maxHeight
) {
    /*
        Equal speaker quality mode:
        - Every real source is both selected and on-stage.
        - Every real source gets the same maxHeight/maxFrameRate.
        - lastN is the exact real source count, so the bridge forwards all known NDI speakers.
        - defaultConstraints also stays high so newly added real sources are not immediately capped low.
    */
    const std::vector<std::string> realSources = normalizeVideoSourceNamesForConstraints(sourceNames);
    const int lastN = realSources.empty() ? -1 : static_cast<int>(realSources.size());

    std::ostringstream out;

    out << "{";
    out << "\"colibriClass\":\"ReceiverVideoConstraints\",";
    out << "\"lastN\":" << lastN << ",";
    out << "\"assumedBandwidthBps\":100000000,";
    out << "\"selectedSources\":" << jsonStringArray(realSources) << ",";
    out << "\"onStageSources\":" << jsonStringArray(realSources) << ",";
    out << "\"defaultConstraints\":{\"maxHeight\":" << maxHeight << ",\"maxFrameRate\":30.0},";
    out << "\"constraints\":{";

    for (std::size_t i = 0; i < realSources.size(); ++i) {
        if (i > 0) {
            out << ",";
        }

        out
            << "\""
            << escapeJsonString(realSources[i])
            << "\":{\"maxHeight\":"
            << maxHeight
            << ",\"maxFrameRate\":30.0}";
    }

    out << "}";
    out << "}";

    return out.str();
}
'@

$makePattern = '(?s)std::string\s+makeReceiverVideoConstraintsMessage\s*\(\s*const\s+std::vector<std::string>&\s+sourceNames\s*,\s*int\s+maxHeight\s*\)\s*\{.*?\n\}\s*(?=\r?\nvoid\s+sendReceiverVideoConstraints)'
$src2 = [regex]::Replace($src, $makePattern, $newMake)
if ($src2 -eq $src) {
  Fail "Could not patch makeReceiverVideoConstraintsMessage. NativeWebRTCAnswerer.cpp layout is different."
}
$src = $src2

$newSend = @'
void sendReceiverVideoConstraints(
    const std::shared_ptr<rtc::DataChannel>& channel,
    const std::vector<std::string>& sourceNames,
    const std::string& reason
) {
    const std::vector<std::string> realSources = normalizeVideoSourceNamesForConstraints(sourceNames);

    if (realSources.empty()) {
        Logger::warn(
            "NativeWebRTCAnswerer: equal 1080p constraints skipped because real video sources list is empty, reason=",
            reason
        );
        return;
    }

    Logger::info(
        "NativeWebRTCAnswerer: requesting equal 1080p/30fps constraints, realSources=",
        realSources.size(),
        " reason=",
        reason
    );

    sendBridgeMessage(
        channel,
        makeReceiverVideoConstraintsMessage(realSources, 1080),
        "ReceiverVideoConstraints/equal-1080p/" + reason
    );
}
'@

$sendPattern = '(?s)void\s+sendReceiverVideoConstraints\s*\(\s*const\s+std::shared_ptr<rtc::DataChannel>&\s+channel\s*,\s*const\s+std::vector<std::string>&\s+sourceNames\s*,\s*const\s+std::string&\s+reason\s*\)\s*\{.*?\n\}\s*(?=\r?\nvoid\s+sendReceiverAudioSubscriptionAll|\r?\nvoid\s+scheduleRepeatedAudioSubscriptionRefresh|\r?\nvoid\s+scheduleRepeatedVideoConstraintRefresh)'
$src2 = [regex]::Replace($src, $sendPattern, $newSend)
if ($src2 -eq $src) {
  Fail "Could not patch sendReceiverVideoConstraints. NativeWebRTCAnswerer.cpp layout is different."
}
$src = $src2

# Make refreshes steady but not spammy. This helps JVB keep all speaker layers requested after source-add/ForwardedSources changes.
$delayPattern = '(?s)const\s+int\s+delaysMs\[\]\s*=\s*\{\s*(?:\d+\s*,\s*)+\d+\s*\};'
$delayReplacement = @'
const int delaysMs[] = {
            1000,
            3000,
            7000,
            15000,
            30000,
            60000
        };
'@
$delayRegex = New-Object System.Text.RegularExpressions.Regex($delayPattern)
$src = $delayRegex.Replace($src, $delayReplacement, 1)

if ($src -ne $orig) {
  Set-Content $native $src -Encoding UTF8
  Write-Host "[v26] Patched NativeWebRTCAnswerer.cpp: equal 1080p/30fps constraints for all real speaker sources."
} else {
  Write-Host "[v26] NativeWebRTCAnswerer.cpp already looked patched; no changes made."
}

Write-Host "[v26] Building Release..."
cmake --build build --config Release
if ($LASTEXITCODE -ne 0) { Fail "Build failed" }

$copyScript = Join-Path $root 'copy_runtime_dlls_v21.ps1'
if (Test-Path $copyScript) {
  Write-Host "[v26] Running existing runtime DLL copier..."
  powershell -ExecutionPolicy Bypass -File $copyScript
} else {
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
    Write-Host "[v26] Copying DLLs from $bin"
    Copy-Item "$bin\*.dll" $dst -Force -ErrorAction SilentlyContinue
  }

  $ndiDll = Get-ChildItem "C:\Program Files", "C:\Program Files (x86)" -Recurse -Filter "Processing.NDI.Lib.x64.dll" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($ndiDll) { Copy-Item $ndiDll.FullName $dst -Force }
}

Write-Host ""
Write-Host "[v26] Done." -ForegroundColor Green
Write-Host "Run:"
Write-Host "  .\build\Release\jitsi-ndi-native.exe --room 6767676766767penxyi"
Write-Host ""
Write-Host "Expected log checks:"
Write-Host "  1) NativeWebRTCAnswerer: requesting equal 1080p/30fps constraints, realSources=2"
Write-Host "  2) ReceiverVideoConstraints/equal-1080p/..."
Write-Host "  3) NDI video frame sent: ... 1920x1080 for each real participant if Jitsi/JVB can supply 1080p for them"
Write-Host "  4) No long Runtime stats period stuck at audio RTP packets=0 video RTP packets=0"
