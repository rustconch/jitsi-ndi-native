$ErrorActionPreference = 'Stop'

function Fail($msg) {
  Write-Host "[v24][ERROR] $msg" -ForegroundColor Red
  exit 1
}

function Backup-File($path, $stamp) {
  if (Test-Path $path) {
    Copy-Item $path "$path.bak_v24_$stamp" -Force
    Write-Host "[v24] Backup: $path.bak_v24_$stamp"
  }
}

$root = (Get-Location).Path
Write-Host "[v24] Repository root: $root"

$native = Join-Path $root 'src\NativeWebRTCAnswerer.cpp'
$routerCpp = Join-Path $root 'src\PerParticipantNdiRouter.cpp'
$routerH = Join-Path $root 'src\PerParticipantNdiRouter.h'
$decoder = Join-Path $root 'src\FfmpegMediaDecoder.cpp'
$ndi = Join-Path $root 'src\NDISender.cpp'
$apph = Join-Path $root 'src\AppConfig.h'

foreach ($f in @($native, $routerCpp, $routerH, $decoder, $ndi)) {
  if (!(Test-Path $f)) { Fail "$f not found. Run from repository root." }
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
foreach ($f in @($native, $routerCpp, $routerH, $decoder, $ndi, $apph)) { Backup-File $f $stamp }

# -----------------------------------------------------------------------------
# 1. Undo v23 forced 1920x1080 scaler.
#    NDI must output the real decoded size. Upscaling 540/720 to 1080 only makes
#    the picture softer/pixelated and does not add real detail.
# -----------------------------------------------------------------------------
$dec = Get-Content $decoder -Raw -Encoding UTF8
$decOrig = $dec

# Remove constants inserted by v23 if present.
$dec = $dec -replace '(?m)^\s*constexpr\s+int\s+kJnnNdiOutWidth\s*=\s*1920;\s*\r?\n\s*constexpr\s+int\s+kJnnNdiOutHeight\s*=\s*1080;\s*\r?\n\s*\r?\n', ''

# sws_getContext destination should be source width/height, not forced 1920x1080.
$dec = $dec -replace 'kJnnNdiOutWidth\s*,\s*kJnnNdiOutHeight\s*,\s*AV_PIX_FMT_BGRA', 'w, h, AV_PIX_FMT_BGRA'

# Frame metadata/buffer size back to actual decoded dimensions.
$dec = $dec -replace 'f\.width\s*=\s*kJnnNdiOutWidth;', 'f.width = w;'
$dec = $dec -replace 'f\.height\s*=\s*kJnnNdiOutHeight;', 'f.height = h;'
$dec = $dec -replace 'f\.stride\s*=\s*kJnnNdiOutWidth\s*\*\s*4;', 'f.stride = w * 4;'
$dec = $dec -replace 'f\.bgra\.resize\(static_cast<std::size_t>\(f\.stride\)\s*\*\s*kJnnNdiOutHeight\);', 'f.bgra.resize(static_cast<std::size_t>(f.stride) * h);'

if ($dec -ne $decOrig) {
  Set-Content $decoder $dec -Encoding UTF8
  Write-Host "[v24] Patched FfmpegMediaDecoder.cpp: removed forced 1080 upscale; NDI will use real decoded frame size."
} else {
  Write-Host "[v24] FfmpegMediaDecoder.cpp: no forced v23 upscale found."
}

# -----------------------------------------------------------------------------
# 2. Keep asking JVB for 1080p, but do not fake 1080 in the decoder.
# -----------------------------------------------------------------------------
$src = Get-Content $native -Raw -Encoding UTF8
$srcOrig = $src

$src = $src -replace 'makeReceiverVideoConstraintsMessage\(sourceNames,\s*720\)', 'makeReceiverVideoConstraintsMessage(sourceNames, 1080)'
$src = $src -replace '"assumedBandwidthBps":\s*20000000', '"assumedBandwidthBps":100000000'
$src = $src -replace '"assumedBandwidthBps":\s*60000000', '"assumedBandwidthBps":100000000'
$src = $src -replace '\\"assumedBandwidthBps\\":20000000', '\"assumedBandwidthBps\":100000000'
$src = $src -replace '\\"assumedBandwidthBps\\":60000000', '\"assumedBandwidthBps\":100000000'

# If v23 added a maxFrameRate key, keep it. If not present, add it gently.
$src = $src.Replace(
  'out << "\"defaultConstraints\":{\"maxHeight\":" << maxHeight << "},";',
  'out << "\"defaultConstraints\":{\"maxHeight\":" << maxHeight << ",\"maxFrameRate\":30.0},";'
)
$src = $src -replace '<<\s*"\}:";', '<< "}";'

# Make refresh persistent again, but not too aggressive.
$src = $src -replace 'const int delaysMs\[\]\s*=\s*\{\s*3000,\s*10000,\s*30000,\s*60000\s*\};', 'const int delaysMs[] = { 1000, 3000, 6000, 10000, 20000, 45000, 60000 };'
$src = $src -replace 'const int delaysMs\[\]\s*=\s*\{\s*250,\s*750,\s*1500,\s*3000,\s*6000,\s*10000,\s*15000,\s*20000\s*\};', 'const int delaysMs[] = { 1000, 3000, 6000, 10000, 20000, 45000, 60000 };'

if ($src -notmatch 'requesting real-source 1080p') {
  $oldSend = @'
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
  $newSend = @'
void sendReceiverVideoConstraints(
    const std::shared_ptr<rtc::DataChannel>& channel,
    const std::vector<std::string>& sourceNames,
    const std::string& reason
) {
    Logger::info(
        "NativeWebRTCAnswerer: requesting real-source 1080p video constraints, sources=",
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
  if ($src.Contains($oldSend)) {
    $src = $src.Replace($oldSend, $newSend)
  } else {
    # v23 already has a log function; just update the marker text.
    $src = $src -replace 'NativeWebRTCAnswerer: requesting 1080p/30fps video constraints, sources=', 'NativeWebRTCAnswerer: requesting real-source 1080p video constraints, sources='
    $src = $src -replace 'NativeWebRTCAnswerer: requesting 1080p video constraints, sources=', 'NativeWebRTCAnswerer: requesting real-source 1080p video constraints, sources='
  }
}

if ($src -ne $srcOrig) {
  Set-Content $native $src -Encoding UTF8
  Write-Host "[v24] Patched NativeWebRTCAnswerer.cpp: real 1080p constraints + persistent refresh."
} else {
  Write-Host "[v24] NativeWebRTCAnswerer.cpp: no textual changes needed."
}

# -----------------------------------------------------------------------------
# 3. Do not decode/convert/send NDI while holding the router global mutex.
#    The old code serialized all participants and NDI sending in one lock. That
#    can create lag/backlog and visible breakup even when Jitsi itself is OK.
# -----------------------------------------------------------------------------
$h = Get-Content $routerH -Raw -Encoding UTF8
$hOrig = $h
if ($h -notmatch 'mediaMutex') {
  $h = $h.Replace(
    '        std::unique_ptr<NDISender> ndi;' + "`r`n" + '        Vp8RtpDepacketizer vp8;',
    '        std::unique_ptr<NDISender> ndi;' + "`r`n" + '        std::mutex mediaMutex;' + "`r`n" + '        Vp8RtpDepacketizer vp8;'
  )
  $h = $h.Replace(
    '        std::unique_ptr<NDISender> ndi;' + "`n" + '        Vp8RtpDepacketizer vp8;',
    '        std::unique_ptr<NDISender> ndi;' + "`n" + '        std::mutex mediaMutex;' + "`n" + '        Vp8RtpDepacketizer vp8;'
  )
}
if ($h -ne $hOrig) {
  Set-Content $routerH $h -Encoding UTF8
  Write-Host "[v24] Patched PerParticipantNdiRouter.h: added per-participant media mutex."
} else {
  Write-Host "[v24] PerParticipantNdiRouter.h: media mutex already present or no change needed."
}

$cpp = Get-Content $routerCpp -Raw -Encoding UTF8
$cppOrig = $cpp
$newHandleRtp = @'
void PerParticipantNdiRouter::handleRtp(
    const std::string& mid,
    const std::uint8_t* data,
    std::size_t size
) {
    const auto rtp = RtpPacket::parse(data, size);

    if (!rtp.valid || rtp.payloadSize == 0) {
        return;
    }

    const std::uint8_t payloadType = readRtpPayloadType(data, size);

    auto source = sourceMap_.lookup(rtp.ssrc);

    if (!source) {
        ++unknownSsrcPackets_;

        if ((unknownSsrcPackets_ % 500) == 0) {
            Logger::warn(
                "PerParticipantNdiRouter: unknown SSRC ",
                RtpPacket::ssrcHex(rtp.ssrc),
                " mid=",
                mid,
                " pt=",
                static_cast<int>(payloadType)
            );
        }

        return;
    }

    const std::string media = !source->media.empty() ? source->media : mid;

    ParticipantPipeline* pipeline = nullptr;
    std::string endpointId;
    std::uint64_t packetCount = 0;
    bool acceptedOpus = false;
    bool acceptedAv1 = false;
    bool acceptedVp8 = false;

    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto& p = pipelineForLocked(*source);
        pipeline = &p;
        endpointId = p.endpointId;

        if (media == "audio" || mid == "audio") {
            ++p.audioPackets;
            packetCount = p.audioPackets;
            acceptedOpus = isAcceptedOpusPayloadTypeLocked(rtp.payloadType);

            if (!acceptedOpus) {
                const auto dropped = ++droppedNonOpusAudioPackets_;
                if (dropped == 1 || (dropped % 200) == 0) {
                    Logger::warn(
                        "PerParticipantNdiRouter: dropping non-Opus audio RTP endpoint=",
                        endpointId,
                        " ssrc=",
                        RtpPacket::ssrcHex(rtp.ssrc),
                        " pt=",
                        static_cast<int>(rtp.payloadType),
                        " opusPts=",
                        payloadSetToString(opusPayloadTypes_),
                        " dropped=",
                        dropped
                    );
                }
                return;
            }

            ++routedAudioPackets_;
        } else if (media == "video" || mid == "video") {
            ++p.videoPackets;
            packetCount = p.videoPackets;
            acceptedAv1 = isAcceptedAv1PayloadTypeLocked(rtp.payloadType);
            acceptedVp8 = isAcceptedVp8PayloadTypeLocked(rtp.payloadType);

            if (!acceptedAv1 && !acceptedVp8) {
                const std::string dropKey =
                    endpointId + ":ssrc-" + RtpPacket::ssrcHex(rtp.ssrc) + ":pt-" + std::to_string(payloadType);
                const auto dropped = ++g_droppedUnsupportedVideoPackets[dropKey];
                if (dropped == 1 || (dropped % 300) == 0) {
                    Logger::warn(
                        "PerParticipantNdiRouter: dropping unsupported non-AV1/non-VP8 video RTP endpoint=",
                        endpointId,
                        " ssrc=",
                        RtpPacket::ssrcHex(rtp.ssrc),
                        " pt=",
                        static_cast<int>(payloadType),
                        " av1Pts=",
                        payloadSetToString(av1PayloadTypes_),
                        " vp8Pts=",
                        payloadSetToString(vp8PayloadTypes_),
                        " dropped=",
                        dropped
                    );
                }
                return;
            }

            ++routedVideoPackets_;
        } else {
            return;
        }
    }

    if (!pipeline || !pipeline->ndi) {
        return;
    }

    if (media == "audio" || mid == "audio") {
        std::lock_guard<std::mutex> mediaLock(pipeline->mediaMutex);

        for (const auto& decoded : pipeline->audioDecoder.decodeRtpPayload(
                 rtp.payload,
                 rtp.payloadSize,
                 rtp.timestamp
             )) {
            pipeline->ndi->sendAudioFrame(decoded);
        }

        if ((packetCount % 500) == 0) {
            Logger::info(
                "PerParticipantNdiRouter: audio packets endpoint=",
                endpointId,
                " count=",
                packetCount,
                " pt=",
                static_cast<int>(rtp.payloadType)
            );
        }

        return;
    }

    if (media == "video" || mid == "video") {
        if (packetCount <= 3 || (packetCount % 300) == 0) {
            Logger::info(
                "PerParticipantNdiRouter: video RTP endpoint=",
                endpointId,
                " pt=",
                static_cast<int>(rtp.payloadType),
                " marker=",
                static_cast<int>(rtp.marker),
                " payloadBytes=",
                rtp.payloadSize,
                " ssrc=",
                rtp.ssrc
            );
        }

        std::lock_guard<std::mutex> mediaLock(pipeline->mediaMutex);

        if (acceptedAv1) {
            const auto frames = pipeline->av1.pushRtp(rtp);
            for (const auto& encoded : frames) {
                for (const auto& decoded : pipeline->av1Decoder.decode(encoded)) {
                    pipeline->ndi->sendVideoFrame(decoded, 30, 1);
                }
            }
            if ((packetCount % 300) == 0 || !frames.empty()) {
                Logger::info(
                    "PerParticipantNdiRouter: AV1 video packets endpoint=",
                    endpointId,
                    " count=",
                    packetCount,
                    " producedFrames=",
                    frames.size()
                );
            }
            return;
        }

        if (acceptedVp8) {
            auto encoded = pipeline->vp8.push(rtp);
            if (encoded) {
                for (const auto& decoded : pipeline->videoDecoder.decode(*encoded)) {
                    pipeline->ndi->sendVideoFrame(decoded, 30, 1);
                }
            }
            if ((packetCount % 300) == 0) {
                Logger::info(
                    "PerParticipantNdiRouter: VP8 video packets endpoint=",
                    endpointId,
                    " count=",
                    packetCount,
                    " pt=",
                    static_cast<int>(payloadType)
                );
            }
            return;
        }
    }
}
'@

$pattern = '(?s)void\s+PerParticipantNdiRouter::handleRtp\s*\(.*?\n\}\s*$'
$cpp2 = [regex]::Replace($cpp, $pattern, $newHandleRtp)
if ($cpp2 -eq $cpp) {
  Fail "Could not replace PerParticipantNdiRouter::handleRtp. File layout is different."
}
Set-Content $routerCpp $cpp2 -Encoding UTF8
Write-Host "[v24] Patched PerParticipantNdiRouter.cpp: moved decode/NDI send outside global lock."

# -----------------------------------------------------------------------------
# 4. Keep real NDI dimension logs, but do not claim NDI is 1080 unless it really is.
# -----------------------------------------------------------------------------
$ndiSrc = Get-Content $ndi -Raw -Encoding UTF8
$ndiOrig = $ndiSrc
$needle = @'
    NDIlib_send_send_video_v2(static_cast<NDIlib_send_instance_t>(ndiSend_), &video);
#else
'@
$replacement = @'
    NDIlib_send_send_video_v2(static_cast<NDIlib_send_instance_t>(ndiSend_), &video);
    if ((sentFrames_ % 300) == 0) {
        Logger::info("NDI video frame sent: ", sourceName_, " ", frame.width, "x", frame.height);
    }
#else
'@
if ($ndiSrc.Contains($needle) -and ($ndiSrc -notmatch 'NDI video frame sent')) {
  $ndiSrc = $ndiSrc.Replace($needle, $replacement)
}
if ($ndiSrc -ne $ndiOrig) {
  Set-Content $ndi $ndiSrc -Encoding UTF8
  Write-Host "[v24] Patched NDISender.cpp: logs real NDI video dimensions."
}

# AppConfig fallback can stay 1080, but this only affects status/test pattern.
if (Test-Path $apph) {
  $cfg = Get-Content $apph -Raw -Encoding UTF8
  $cfgOrig = $cfg
  $cfg = $cfg -replace 'int\s+width\s*=\s*1280\s*;', 'int width = 1920;'
  $cfg = $cfg -replace 'int\s+height\s*=\s*720\s*;', 'int height = 1080;'
  if ($cfg -ne $cfgOrig) {
    Set-Content $apph $cfg -Encoding UTF8
    Write-Host "[v24] Patched AppConfig.h fallback/status size to 1920x1080."
  }
}

Write-Host "[v24] Building Release..."
cmake --build build --config Release
if ($LASTEXITCODE -ne 0) { Fail "Build failed" }

$copyScript = Join-Path $root 'copy_runtime_dlls_v21.ps1'
if (Test-Path $copyScript) {
  Write-Host "[v24] Running existing v21 runtime DLL copier..."
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
    Write-Host "[v24] Copying DLLs from $bin"
    Copy-Item "$bin\*.dll" $dst -Force -ErrorAction SilentlyContinue
  }

  $ndiDll = Get-ChildItem "C:\Program Files", "C:\Program Files (x86)" -Recurse -Filter "Processing.NDI.Lib.x64.dll" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($ndiDll) { Copy-Item $ndiDll.FullName $dst -Force }
}

Write-Host ""
Write-Host "[v24] Done." -ForegroundColor Green
Write-Host "Run:"
Write-Host "  .\build\Release\jitsi-ndi-native.exe --room 6767676766767penxyi"
Write-Host ""
Write-Host "Expected checks:"
Write-Host "  1) Logs must say: using AV1 decoder libdav1d"
Write-Host "  2) Logs must say: requesting real-source 1080p video constraints"
Write-Host "  3) NDI video frame sent shows the real source size. If it is 1280x720 or 960x540, Jitsi/JVB is not forwarding 1080 to this receiver yet."
