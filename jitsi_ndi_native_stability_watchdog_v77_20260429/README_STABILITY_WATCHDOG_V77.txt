STABILITY_WATCHDOG_V77

Purpose:
- Fix NDI output freezes caused by dead WebRTC PeerConnection.
- The patch does not touch NDI routing, RTP parsing, decoders, audio code, GUI, or display-name logic.
- It only changes src/main.cpp runtime loop.

What it does:
- Keeps logging Runtime stats every 10 seconds.
- Tracks audio/video RTP packet counters.
- If RTP counters have moved at least once, then stop growing for more than 25 seconds, the app reconnects the Jitsi/XMPP session automatically.
- Uses a 45 second cooldown and 45 second post-reconnect grace period to avoid reconnect storms.

Apply:
  cd D:\MEDIA\Desktop\jitsi-ndi-native
  Expand-Archive -Force .\jitsi_ndi_native_stability_watchdog_v77_20260429.zip .
  .\jitsi_ndi_native_stability_watchdog_v77_20260429\apply_stability_watchdog_v77.ps1

Build:
  cmake --build build-ndi --config Release

Restore:
  .\jitsi_ndi_native_stability_watchdog_v77_20260429\restore_latest_stability_watchdog_v77_backup.ps1

Expected new log lines after a freeze:
  StabilityWatchdog: RTP counters stalled for 26s; reconnecting Jitsi session, attempt=1
  NativeWebRTCAnswerer: resetting previous PeerConnection
  StabilityWatchdog: reconnect started; waiting for fresh Jitsi media
