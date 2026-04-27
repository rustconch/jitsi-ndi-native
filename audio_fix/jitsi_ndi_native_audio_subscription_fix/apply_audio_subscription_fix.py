from pathlib import Path
import re
import sys

ROOT = Path.cwd()
SRC = ROOT / "src" / "NativeWebRTCAnswerer.cpp"

if not SRC.exists():
    print(f"[AUDIO FIX] ERROR: not found: {SRC}")
    sys.exit(1)

text = SRC.read_text(encoding="utf-8", errors="replace")
orig = text

helper = r'''
void sendReceiverAudioSubscriptionAll(
    const std::shared_ptr<rtc::DataChannel>& channel,
    const std::string& reason
) {
    sendBridgeMessage(
        channel,
        "{\"colibriClass\":\"ReceiverAudioSubscription\",\"mode\":\"All\"}",
        "ReceiverAudioSubscription/" + reason
    );
}

void scheduleRepeatedAudioSubscriptionRefresh(
    const std::shared_ptr<rtc::DataChannel>& channel
) {
    if (!channel) {
        return;
    }

    std::thread([channel]() {
        const int delaysMs[] = {
            250,
            750,
            1500,
            3000,
            6000,
            10000,
            15000,
            20000,
            30000
        };

        for (const int delayMs : delaysMs) {
            std::this_thread::sleep_for(std::chrono::milliseconds(delayMs));
            sendReceiverAudioSubscriptionAll(channel, "refresh");
        }
    }).detach();
}
'''

if "sendReceiverAudioSubscriptionAll(" not in text:
    marker = "void scheduleRepeatedVideoConstraintRefresh("
    pos = text.find(marker)
    if pos < 0:
        print("[AUDIO FIX] ERROR: could not find scheduleRepeatedVideoConstraintRefresh() insertion point")
        sys.exit(1)
    text = text[:pos] + helper + "\n" + text[pos:]
    print("[AUDIO FIX] added audio subscription helper + repeated refresh")
else:
    print("[AUDIO FIX] audio subscription helper already present")

old_audio_send = '''            sendBridgeMessage(
                bridgeChannel,
                "{\\\"colibriClass\\\":\\\"ReceiverAudioSubscription\\\",\\\"mode\\\":\\\"All\\\"}",
                "ReceiverAudioSubscription"
            );'''

if old_audio_send in text:
    text = text.replace(old_audio_send, '            sendReceiverAudioSubscriptionAll(bridgeChannel, "open");')
    print("[AUDIO FIX] replaced one-shot ReceiverAudioSubscription with helper call")
elif 'sendReceiverAudioSubscriptionAll(bridgeChannel, "open")' in text:
    print("[AUDIO FIX] open audio subscription call already present")
else:
    # Best-effort regex for formatting variants.
    pattern = re.compile(
        r'sendBridgeMessage\(\s*bridgeChannel\s*,\s*"\{\\"colibriClass\\":\\"ReceiverAudioSubscription\\",\\"mode\\":\\"All\\"\}"\s*,\s*"ReceiverAudioSubscription"\s*\);',
        re.S,
    )
    text, n = pattern.subn('sendReceiverAudioSubscriptionAll(bridgeChannel, "open");', text, count=1)
    if n:
        print("[AUDIO FIX] replaced one-shot ReceiverAudioSubscription with helper call using regex")
    else:
        print("[AUDIO FIX] WARN: did not find original one-shot ReceiverAudioSubscription call")

video_refresh_block = '''            scheduleRepeatedVideoConstraintRefresh(
                bridgeChannel,
                latestForwardedSourcesMutex,
                latestForwardedSources,
                initialVideoSources
            );'''

if video_refresh_block in text and 'scheduleRepeatedAudioSubscriptionRefresh(bridgeChannel);' not in text:
    text = text.replace(
        video_refresh_block,
        video_refresh_block + '\n\n            scheduleRepeatedAudioSubscriptionRefresh(bridgeChannel);'
    )
    print("[AUDIO FIX] added repeated audio subscription refresh after video refresh")
elif 'scheduleRepeatedAudioSubscriptionRefresh(bridgeChannel);' in text:
    print("[AUDIO FIX] repeated audio subscription refresh already present")
else:
    print("[AUDIO FIX] WARN: could not find video refresh block to append audio refresh")

server_hello_block = '''                sendReceiverVideoConstraints(
                    bridgeChannel,
                    initialVideoSources,
                    "server-hello-sdp-sources"
                );

                return;'''

if server_hello_block in text and 'sendReceiverAudioSubscriptionAll(bridgeChannel, "server-hello");' not in text:
    text = text.replace(
        server_hello_block,
        '''                sendReceiverVideoConstraints(
                    bridgeChannel,
                    initialVideoSources,
                    "server-hello-sdp-sources"
                );

                sendReceiverAudioSubscriptionAll(bridgeChannel, "server-hello");

                return;'''
    )
    print("[AUDIO FIX] added audio subscription resend on ServerHello")
elif 'sendReceiverAudioSubscriptionAll(bridgeChannel, "server-hello");' in text:
    print("[AUDIO FIX] ServerHello audio resend already present")
else:
    print("[AUDIO FIX] WARN: could not patch ServerHello audio resend")

if text == orig:
    print("[AUDIO FIX] no changes made")
else:
    backup = SRC.with_suffix(SRC.suffix + ".bak_audio_subscription")
    if not backup.exists():
        backup.write_text(orig, encoding="utf-8")
        print(f"[AUDIO FIX] backup written: {backup}")
    SRC.write_text(text, encoding="utf-8")
    print(f"[AUDIO FIX] patched: {SRC}")

print("[AUDIO FIX] done")
print("[AUDIO FIX] now build:")
print("    cmake --build build --config Release")
print("[AUDIO FIX] then run with at least one browser participant UNMUTED and speaking")
