$ErrorActionPreference = 'Stop'

function Fail($msg) {
  Write-Host "[v25][ERROR] $msg" -ForegroundColor Red
  exit 1
}

function Backup-File($path, $stamp) {
  if (Test-Path $path) {
    Copy-Item $path "$path.bak_v25_$stamp" -Force
    Write-Host "[v25] Backup: $path.bak_v25_$stamp"
  }
}

function Restore-LatestV24Backup($path) {
  if (!(Test-Path $path)) { return $false }
  $dir = Split-Path -Parent $path
  $leaf = Split-Path -Leaf $path
  $bak = Get-ChildItem -Path $dir -Filter "$leaf.bak_v24_*" -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

  if ($bak) {
    Copy-Item $bak.FullName $path -Force
    Write-Host "[v25] Restored pre-v24 file: $leaf <= $($bak.Name)" -ForegroundColor Yellow
    return $true
  }

  Write-Host "[v25] No v24 backup found for $leaf; leaving current file in place."
  return $false
}

$root = (Get-Location).Path
Write-Host "[v25] Repository root: $root"

$native = Join-Path $root 'src\NativeWebRTCAnswerer.cpp'
$routerCpp = Join-Path $root 'src\PerParticipantNdiRouter.cpp'
$routerH = Join-Path $root 'src\PerParticipantNdiRouter.h'
$jitsi = Join-Path $root 'src\JitsiSignaling.cpp'
$decoder = Join-Path $root 'src\FfmpegMediaDecoder.cpp'
$ndi = Join-Path $root 'src\NDISender.cpp'

foreach ($f in @($native, $routerCpp, $routerH, $jitsi)) {
  if (!(Test-Path $f)) { Fail "$f not found. Run from repository root." }
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
foreach ($f in @($native, $routerCpp, $routerH, $jitsi, $decoder, $ndi)) { Backup-File $f $stamp }

# -----------------------------------------------------------------------------
# 1) Roll back the risky v24 parts which changed the media path and constraints.
#    v24 made the PeerConnection/datachannel alive but media RTP stayed 0/0.
#    We restore NativeWebRTCAnswerer + router files to the state before v24.
#    We intentionally do NOT restore FfmpegMediaDecoder.cpp, so the v24 removal
#    of fake 1920x1080 upscaling can remain.
# -----------------------------------------------------------------------------
$restoredNative = Restore-LatestV24Backup $native
$restoredRouterCpp = Restore-LatestV24Backup $routerCpp
$restoredRouterH = Restore-LatestV24Backup $routerH

# Keep logs understandable if the restored native file was from v23.
if (Test-Path $native) {
  $src = Get-Content $native -Raw -Encoding UTF8
  $src2 = $src -replace 'NativeWebRTCAnswerer: requesting real-source 1080p video constraints, sources=', 'NativeWebRTCAnswerer: requesting 1080p video constraints, sources='
  if ($src2 -ne $src) {
    Set-Content $native $src2 -Encoding UTF8
    Write-Host "[v25] Normalized NativeWebRTCAnswerer constraint log text."
  }
}

# -----------------------------------------------------------------------------
# 2) Fix the actual breakage visible in the log:
#    focus first created a JVB session with only jvb-v0, then sent source-add.
#    The old code did not ACK/source-map source-add IQs, so JVB could keep media
#    download at zero even though datachannel statistics were alive.
# -----------------------------------------------------------------------------
$j = Get-Content $jitsi -Raw -Encoding UTF8
$jOrig = $j

# Replace transport-info handler so direct endpoint/P2P ICE candidates are ACKed
# but not injected into the active JVB PeerConnection.
$newTransportInfo = @'
void JitsiSignaling::handleJingleTransportInfo(const std::string& xml) {
    const std::string iqTag = findFirstTag(xml, "iq");
    const std::string from = xmlUnescape(attrValue(iqTag, "from"));
    const std::string id = attrValue(iqTag, "id");

    const std::string jingleTag = findFirstTag(xml, "jingle");
    const std::string sid = xmlUnescape(attrValue(jingleTag, "sid"));

    std::string activeFocusJid;
    std::string activeSid;

    {
        std::lock_guard<std::mutex> lock(mutex_);
        activeFocusJid = currentFocusJid_;
        activeSid = currentSid_;
    }

    if (!activeFocusJid.empty() && from != activeFocusJid) {
        Logger::warn(
            "MEDIA EVENT: ignoring non-focus/P2P transport-info from=",
            from,
            " sid=",
            sid.empty() ? "?" : sid,
            " activeFocus=",
            activeFocusJid
        );
        sendIqResult(from, id);
        return;
    }

    if (!activeSid.empty() && !sid.empty() && sid != activeSid) {
        Logger::warn(
            "MEDIA EVENT: ignoring transport-info for stale sid=",
            sid,
            " activeSid=",
            activeSid,
            " from=",
            from
        );
        sendIqResult(from, id);
        return;
    }

    LocalIceCandidate candidate;

    if (parseTransportInfoCandidate(xml, candidate)) {
        answerer_.addRemoteCandidate(candidate);
    } else {
        Logger::warn("MEDIA EVENT: transport-info detected but no candidate parsed");
    }

    sendIqResult(from, id);
}
'@

$transportPattern = '(?s)void\s+JitsiSignaling::handleJingleTransportInfo\s*\(const\s+std::string&\s+xml\)\s*\{.*?\n\}\s*(?=\r?\nvoid\s+JitsiSignaling::handleJingleTerminate)'
$j2 = [regex]::Replace($j, $transportPattern, $newTransportInfo)
if ($j2 -eq $j) {
  Fail "Could not patch handleJingleTransportInfo; JitsiSignaling.cpp layout is different."
}
$j = $j2

# Add explicit source-add/source-remove handling before session-initiate handling.
if ($j -notmatch 'MEDIA EVENT: Jingle source-add detected') {
  $sourceAddBlock = @'
    if (
        contains(xml, "urn:xmpp:jingle:1")
        && (
            containsAnyQuoteAttr(xml, "action", "source-add")
            || contains(xml, "source-add")
        )
    ) {
        const std::string to = extractIqAttr(xml, "from");
        const std::string id = extractIqAttr(xml, "id");

        Logger::info("MEDIA EVENT: Jingle source-add detected; updating source map and ACKing.");

        if (ndiRouter_) {
            ndiRouter_->updateSourcesFromJingleXml(xml);
        }

        sendIqResult(to, id);
        return;
    }

    if (
        contains(xml, "urn:xmpp:jingle:1")
        && (
            containsAnyQuoteAttr(xml, "action", "source-remove")
            || contains(xml, "source-remove")
        )
    ) {
        const std::string to = extractIqAttr(xml, "from");
        const std::string id = extractIqAttr(xml, "id");

        Logger::info("MEDIA EVENT: Jingle source-remove detected; updating source map and ACKing.");

        if (ndiRouter_) {
            ndiRouter_->removeSourcesFromJingleXml(xml);
        }

        sendIqResult(to, id);
        return;
    }

'@

  $marker = @'
    if (
        contains(xml, "urn:xmpp:jingle:1")
        && (
            containsAnyQuoteAttr(xml, "action", "session-initiate")
'@

  if ($j.Contains($marker)) {
    $j = $j.Replace($marker, $sourceAddBlock + $marker)
  } else {
    Fail "Could not insert source-add handler; session-initiate marker not found."
  }
}

if ($j -ne $jOrig) {
  Set-Content $jitsi $j -Encoding UTF8
  Write-Host "[v25] Patched JitsiSignaling.cpp: source-add/source-remove ACK + ignore P2P transport-info."
} else {
  Write-Host "[v25] JitsiSignaling.cpp already had v25 changes."
}

# -----------------------------------------------------------------------------
# 3) Safety: make sure v23 fake 1080 upscale is not active if v24 already removed it.
#    If the file still has kJnnNdiOutWidth, remove it again.
# -----------------------------------------------------------------------------
if (Test-Path $decoder) {
  $dec = Get-Content $decoder -Raw -Encoding UTF8
  $decOrig = $dec
  $dec = $dec -replace '(?m)^\s*constexpr\s+int\s+kJnnNdiOutWidth\s*=\s*1920;\s*\r?\n\s*constexpr\s+int\s+kJnnNdiOutHeight\s*=\s*1080;\s*\r?\n\s*\r?\n', ''
  $dec = $dec -replace 'kJnnNdiOutWidth\s*,\s*kJnnNdiOutHeight\s*,\s*AV_PIX_FMT_BGRA', 'w, h, AV_PIX_FMT_BGRA'
  $dec = $dec -replace 'f\.width\s*=\s*kJnnNdiOutWidth;', 'f.width = w;'
  $dec = $dec -replace 'f\.height\s*=\s*kJnnNdiOutHeight;', 'f.height = h;'
  $dec = $dec -replace 'f\.stride\s*=\s*kJnnNdiOutWidth\s*\*\s*4;', 'f.stride = w * 4;'
  $dec = $dec -replace 'f\.bgra\.resize\(static_cast<std::size_t>\(f\.stride\)\s*\*\s*kJnnNdiOutHeight\);', 'f.bgra.resize(static_cast<std::size_t>(f.stride) * h);'
  if ($dec -ne $decOrig) {
    Set-Content $decoder $dec -Encoding UTF8
    Write-Host "[v25] Removed fake 1920x1080 decoder upscale if it was still present."
  }
}

Write-Host "[v25] Building Release..."
cmake --build build --config Release
if ($LASTEXITCODE -ne 0) { Fail "Build failed" }

$copyScript = Join-Path $root 'copy_runtime_dlls_v21.ps1'
if (Test-Path $copyScript) {
  Write-Host "[v25] Running existing v21 runtime DLL copier..."
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
    Write-Host "[v25] Copying DLLs from $bin"
    Copy-Item "$bin\*.dll" $dst -Force -ErrorAction SilentlyContinue
  }

  $ndiDll = Get-ChildItem "C:\Program Files", "C:\Program Files (x86)" -Recurse -Filter "Processing.NDI.Lib.x64.dll" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($ndiDll) { Copy-Item $ndiDll.FullName $dst -Force }
}

Write-Host ""
Write-Host "[v25] Done." -ForegroundColor Green
Write-Host "Run:"
Write-Host "  .\build\Release\jitsi-ndi-native.exe --room 6767676766767penxyi"
Write-Host ""
Write-Host "Expected checks:"
Write-Host "  1) MEDIA EVENT: Jingle source-add detected; updating source map and ACKing."
Write-Host "  2) MEDIA EVENT: ignoring non-focus/P2P transport-info ..."
Write-Host "  3) Runtime stats must stop being audio RTP packets=0 video RTP packets=0 after media starts."
Write-Host "  4) FfmpegMediaDecoder: using AV1 decoder libdav1d"
