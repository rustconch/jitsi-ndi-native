$ErrorActionPreference = 'Stop'

$Root = (Get-Location).Path
$Main = Join-Path $Root 'src\main.cpp'

if (-not (Test-Path $Main)) {
    throw "Cannot find src\main.cpp. Run this script from the jitsi-ndi-native project root."
}

$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$BackupDir = Join-Path $Root ".jnn_patch_backups\stability_watchdog_v77_$Stamp"
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
Copy-Item $Main (Join-Path $BackupDir 'main.cpp') -Force

$content = [System.IO.File]::ReadAllText($Main)

if ($content.Contains('STABILITY_WATCHDOG_V77')) {
    Write-Host 'STABILITY_WATCHDOG_V77 is already applied.'
    Write-Host "Backup still created at: $BackupDir"
    exit 0
}

$pattern = @'
auto\s+lastLog\s*=\s*std::chrono::steady_clock::now\(\);\s*while\s*\(g_running\)\s*\{\s*const\s+auto\s+now\s*=\s*std::chrono::steady_clock::now\(\);\s*if\s*\(now\s*-\s*lastLog\s*>\s*std::chrono::seconds\(10\)\)\s*\{\s*Logger::info\(\s*"Runtime stats: audio RTP packets=",\s*signaling\.audioPackets\(\),\s*" video RTP packets=",\s*signaling\.videoPackets\(\)\s*\);\s*lastLog\s*=\s*now;\s*\}\s*std::this_thread::sleep_for\(std::chrono::milliseconds\(250\)\);\s*\}\s*signaling\.disconnect\(\);
'@

$replacement = @'
auto lastLog = std::chrono::steady_clock::now();

// STABILITY_WATCHDOG_V77:
// If WebRTC dies, the NDI senders keep their last frames while RTP counters stop.
// Reconnect the Jitsi/XMPP session when audio/video RTP counters stay frozen.
auto lastPacketProgress = std::chrono::steady_clock::now();
auto lastReconnectAttempt = std::chrono::steady_clock::now() - std::chrono::minutes(5);
auto reconnectGraceUntil = std::chrono::steady_clock::now() + std::chrono::seconds(45);

std::uint64_t lastAudioPackets = signaling.audioPackets();
std::uint64_t lastVideoPackets = signaling.videoPackets();
bool sawRtpOnce = (lastAudioPackets != 0 || lastVideoPackets != 0);
int reconnectAttempt = 0;

while (g_running) {
    const auto now = std::chrono::steady_clock::now();
    const auto audioNow = signaling.audioPackets();
    const auto videoNow = signaling.videoPackets();

    const bool packetsMoved =
        (audioNow != lastAudioPackets) ||
        (videoNow != lastVideoPackets);

    if (packetsMoved) {
        lastAudioPackets = audioNow;
        lastVideoPackets = videoNow;
        lastPacketProgress = now;
        sawRtpOnce = true;
        reconnectAttempt = 0;
        reconnectGraceUntil = now;
    }

    if (now - lastLog > std::chrono::seconds(10)) {
        Logger::info(
            "Runtime stats: audio RTP packets=", audioNow,
            " video RTP packets=", videoNow
        );
        lastLog = now;
    }

    const auto stalledFor = std::chrono::duration_cast<std::chrono::seconds>(
        now - lastPacketProgress
    ).count();

    const bool mayReconnect =
        sawRtpOnce &&
        now >= reconnectGraceUntil &&
        (now - lastPacketProgress > std::chrono::seconds(25)) &&
        (now - lastReconnectAttempt > std::chrono::seconds(45));

    if (mayReconnect) {
        ++reconnectAttempt;
        lastReconnectAttempt = now;
        reconnectGraceUntil = now + std::chrono::seconds(45);

        Logger::warn(
            "StabilityWatchdog: RTP counters stalled for ",
            stalledFor,
            "s; reconnecting Jitsi session, attempt=",
            reconnectAttempt
        );

        signaling.disconnect();

        if (!g_running) {
            break;
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(1500));

        if (!signaling.connect()) {
            Logger::error("StabilityWatchdog: reconnect failed; will retry after cooldown");
        } else {
            Logger::info("StabilityWatchdog: reconnect started; waiting for fresh Jitsi media");
        }

        lastAudioPackets = signaling.audioPackets();
        lastVideoPackets = signaling.videoPackets();
        lastPacketProgress = std::chrono::steady_clock::now();
    }

    std::this_thread::sleep_for(std::chrono::milliseconds(250));
}

signaling.disconnect();
'@

$newContent = [System.Text.RegularExpressions.Regex]::Replace(
    $content,
    $pattern,
    [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $replacement },
    1
)

if ($newContent -eq $content) {
    throw "Patch anchor not found in src\main.cpp. The file layout may differ. Send src\main.cpp and I will adjust the patch. Backup: $BackupDir"
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($Main, $newContent, $utf8NoBom)

Write-Host 'Applied STABILITY_WATCHDOG_V77 to src\main.cpp'
Write-Host "Backup: $BackupDir"
Write-Host ''
Write-Host 'Now rebuild, for example:'
Write-Host '  cmake --build build-ndi --config Release'
