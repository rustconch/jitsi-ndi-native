$ErrorActionPreference = 'Stop'

function Fail($msg) {
  Write-Host "[v23][ERROR] $msg" -ForegroundColor Red
  exit 1
}

function Backup-File($path, $stamp) {
  if (Test-Path $path) {
    Copy-Item $path "$path.bak_v23_$stamp" -Force
    Write-Host "[v23] Backup: $path.bak_v23_$stamp"
  }
}

$root = (Get-Location).Path
Write-Host "[v23] Repository root: $root"

$native = Join-Path $root 'src\NativeWebRTCAnswerer.cpp'
$decoder = Join-Path $root 'src\FfmpegMediaDecoder.cpp'
$ndi = Join-Path $root 'src\NDISender.cpp'
$apph = Join-Path $root 'src\AppConfig.h'

if (!(Test-Path $native)) { Fail "src\NativeWebRTCAnswerer.cpp not found. Run from repository root." }
if (!(Test-Path $decoder)) { Fail "src\FfmpegMediaDecoder.cpp not found. Run from repository root." }
if (!(Test-Path $ndi)) { Fail "src\NDISender.cpp not found. Run from repository root." }

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
Backup-File $native $stamp
Backup-File $decoder $stamp
Backup-File $ndi $stamp
if (Test-Path $apph) { Backup-File $apph $stamp }

# -----------------------------
# 1. JVB receiver constraints: 1080p, 30 fps, higher assumed bandwidth.
# -----------------------------
$src = Get-Content $native -Raw -Encoding UTF8
$orig = $src

# Replace any previous v22/v21 bandwidth values.
$src = $src -replace '"assumedBandwidthBps":\s*20000000', '"assumedBandwidthBps":100000000'
$src = $src -replace '"assumedBandwidthBps":\s*60000000', '"assumedBandwidthBps":100000000'
$src = $src -replace '\\"assumedBandwidthBps\\":20000000', '\"assumedBandwidthBps\":100000000'
$src = $src -replace '\\"assumedBandwidthBps\\":60000000', '\"assumedBandwidthBps\":100000000'

# Force all generated ReceiverVideoConstraints calls to 1080.
$src = $src -replace 'makeReceiverVideoConstraintsMessage\(sourceNames,\s*720\)', 'makeReceiverVideoConstraintsMessage(sourceNames, 1080)'
$src = $src -replace 'makeReceiverVideoConstraintsMessage\(sourceNames,\s*1080\)', 'makeReceiverVideoConstraintsMessage(sourceNames, 1080)'

# Add maxFrameRate into JVB VideoConstraints JSON. Idempotent: skip if already added.
$src = $src.Replace(
  'out << "\"defaultConstraints\":{\"maxHeight\":" << maxHeight << "},";',
  'out << "\"defaultConstraints\":{\"maxHeight\":" << maxHeight << ",\"maxFrameRate\":30.0},";'
)
$src = $src.Replace(
  '<< "\":{\"maxHeight\":"' + "`r`n" + '            << maxHeight' + "`r`n" + '            << "}";',
  '<< "\":{\"maxHeight\":"' + "`r`n" + '            << maxHeight' + "`r`n" + '            << ",\"maxFrameRate\":30.0}";'
)
$src = $src.Replace(
  '<< "\":{\"maxHeight\":"' + "`n" + '            << maxHeight' + "`n" + '            << "}";',
  '<< "\":{\"maxHeight\":"' + "`n" + '            << maxHeight' + "`n" + '            << ",\"maxFrameRate\":30.0}";'
)

# Reduce duplicate early video-constraint refreshes. Open/ServerHello/ForwardedSources already send constraints.
# Too many immediate refreshes can cause layer churn while the bridge is still adapting.
$oldVideoDelaysV22 = @'
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
$newVideoDelays = @'
        const int delaysMs[] = {
            3000,
            10000,
            30000,
            60000
        };
'@
if ($src.Contains($oldVideoDelaysV22)) {
  $src = $src.Replace($oldVideoDelaysV22, $newVideoDelays)
}

$oldVideoDelaysOrig = @'
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
if ($src.Contains($oldVideoDelaysOrig)) {
  $src = $src.Replace($oldVideoDelaysOrig, $newVideoDelays)
}

# If v22 log marker is present, keep it; otherwise add a compact one.
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
        "NativeWebRTCAnswerer: requesting 1080p/30fps video constraints, sources=",
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

if ($src -ne $orig) {
  Set-Content $native $src -Encoding UTF8
  Write-Host "[v23] Patched NativeWebRTCAnswerer.cpp: 1080p/30fps constraints, 100 Mbps assumed bandwidth, calmer refresh."
} else {
  Write-Host "[v23] NativeWebRTCAnswerer.cpp already looked patched; no textual changes there."
}

# -----------------------------
# 2. Force decoded video frames to 1920x1080 before NDI.
# This makes the NDI output itself 1080p even if Jitsi sends 720p.
# -----------------------------
$dec = Get-Content $decoder -Raw -Encoding UTF8
$decOrig = $dec

if ($dec -notmatch 'kJnnNdiOutWidth') {
  $dec = $dec.Replace(
    '} // namespace' + "`r`n" + "`r`n" + 'struct FfmpegVp8Decoder::Impl',
    'constexpr int kJnnNdiOutWidth = 1920;' + "`r`n" + 'constexpr int kJnnNdiOutHeight = 1080;' + "`r`n" + "`r`n" + '} // namespace' + "`r`n" + "`r`n" + 'struct FfmpegVp8Decoder::Impl'
  )
  $dec = $dec.Replace(
    '} // namespace' + "`n" + "`n" + 'struct FfmpegVp8Decoder::Impl',
    'constexpr int kJnnNdiOutWidth = 1920;' + "`n" + 'constexpr int kJnnNdiOutHeight = 1080;' + "`n" + "`n" + '} // namespace' + "`n" + "`n" + 'struct FfmpegVp8Decoder::Impl'
  )
}

# Destination side of sws_getContext: source stays w/h, output becomes 1920x1080.
$dec = $dec.Replace(
  '                w, h, AV_PIX_FMT_BGRA,' + "`r`n" + '                SWS_BILINEAR, nullptr, nullptr, nullptr',
  '                kJnnNdiOutWidth, kJnnNdiOutHeight, AV_PIX_FMT_BGRA,' + "`r`n" + '                SWS_BILINEAR, nullptr, nullptr, nullptr'
)
$dec = $dec.Replace(
  '                w, h, AV_PIX_FMT_BGRA,' + "`n" + '                SWS_BILINEAR, nullptr, nullptr, nullptr',
  '                kJnnNdiOutWidth, kJnnNdiOutHeight, AV_PIX_FMT_BGRA,' + "`n" + '                SWS_BILINEAR, nullptr, nullptr, nullptr'
)

# Output frame metadata/buffer size for both VP8 and AV1 decode paths.
$oldFrameMeta = @'
        DecodedVideoFrameBGRA f;
        f.width = w;
        f.height = h;
        f.stride = w * 4;
        f.pts90k = impl_->frame->best_effort_timestamp;
        f.bgra.resize(static_cast<std::size_t>(f.stride) * h);
'@
$newFrameMeta = @'
        DecodedVideoFrameBGRA f;
        f.width = kJnnNdiOutWidth;
        f.height = kJnnNdiOutHeight;
        f.stride = kJnnNdiOutWidth * 4;
        f.pts90k = impl_->frame->best_effort_timestamp;
        f.bgra.resize(static_cast<std::size_t>(f.stride) * kJnnNdiOutHeight);
'@
$dec = $dec.Replace($oldFrameMeta, $newFrameMeta)

if ($dec -ne $decOrig) {
  Set-Content $decoder $dec -Encoding UTF8
  Write-Host "[v23] Patched FfmpegMediaDecoder.cpp: decoded video output is forced to 1920x1080 BGRA."
} else {
  Write-Host "[v23] FfmpegMediaDecoder.cpp already looked patched; no textual changes there."
}

# -----------------------------
# 3. Log actual NDI frame dimensions with real NDI too.
# -----------------------------
$ndiSrc = Get-Content $ndi -Raw -Encoding UTF8
$ndiOrig = $ndiSrc

$needleVideoSend = @'
    NDIlib_send_send_video_v2(static_cast<NDIlib_send_instance_t>(ndiSend_), &video);
#else
'@
$replacementVideoSend = @'
    NDIlib_send_send_video_v2(static_cast<NDIlib_send_instance_t>(ndiSend_), &video);
    if ((sentFrames_ % 300) == 0) {
        Logger::info("NDI video frame sent: ", sourceName_, " ", frame.width, "x", frame.height);
    }
#else
'@
if ($ndiSrc.Contains($needleVideoSend) -and ($ndiSrc -notmatch 'NDI video frame sent')) {
  $ndiSrc = $ndiSrc.Replace($needleVideoSend, $replacementVideoSend)
}

if ($ndiSrc -ne $ndiOrig) {
  Set-Content $ndi $ndiSrc -Encoding UTF8
  Write-Host "[v23] Patched NDISender.cpp: logs real NDI video frame dimensions."
} else {
  Write-Host "[v23] NDISender.cpp already looked patched; no textual changes there."
}

# Optional fallback/status size.
if (Test-Path $apph) {
  $h = Get-Content $apph -Raw -Encoding UTF8
  $hOrig = $h
  $h = $h -replace 'int\s+width\s*=\s*1280\s*;', 'int width = 1920;'
  $h = $h -replace 'int\s+height\s*=\s*720\s*;', 'int height = 1080;'
  if ($h -ne $hOrig) {
    Set-Content $apph $h -Encoding UTF8
    Write-Host "[v23] Patched AppConfig.h fallback/status size to 1920x1080."
  }
}

Write-Host "[v23] Building Release..."
cmake --build build --config Release
if ($LASTEXITCODE -ne 0) { Fail "Build failed" }

# Copy runtime DLLs again. Prefer existing v21 copier because it knows dav1d/ffmpeg runtime DLLs.
$copyScript = Join-Path $root 'copy_runtime_dlls_v21.ps1'
if (Test-Path $copyScript) {
  Write-Host "[v23] Running existing v21 runtime DLL copier..."
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
    Write-Host "[v23] Copying DLLs from $bin"
    Copy-Item "$bin\*.dll" $dst -Force -ErrorAction SilentlyContinue
  }

  $ndiDll = Get-ChildItem "C:\Program Files", "C:\Program Files (x86)" -Recurse -Filter "Processing.NDI.Lib.x64.dll" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($ndiDll) { Copy-Item $ndiDll.FullName $dst -Force }
}

Write-Host ""
Write-Host "[v23] Done." -ForegroundColor Green
Write-Host "Run:"
Write-Host "  .\build\Release\jitsi-ndi-native.exe --room 6767676766767penxyi"
Write-Host ""
Write-Host "Check logs for:"
Write-Host "  NativeWebRTCAnswerer: requesting 1080p/30fps video constraints"
Write-Host "  NDI video frame sent: ... 1920x1080"
Write-Host "  EndpointStats ... maxEnabledResolution ... 1080 if Jitsi/JVB actually provides 1080"
