jitsi-ndi-native v91 immediate WebRTC reconnect

What this patch keeps from v90:
- AV1 receive path stays enabled.
- Screen share remains a separate NDI source.
- Screen share request stays 1080p / 30 fps.
- Camera request stays 720p / 30 fps.
- Receive bitrate cap stays 6.7 Mbps.
- Async NDI video queue and 1080p NDI frame cap stay enabled.
- Audio path is not changed.

What v91 adds:
- NativeWebRTCAnswerer now reports media-session failure when bridge datachannel closes or PeerConnection reaches failed/closed.
- Main watchdog consumes that signal and reconnects Jitsi/XMPP immediately instead of waiting for RTP counters to stall for 25 seconds.
- Intentional reset/disconnect is guarded by a PeerConnection generation counter so normal closes do not trigger another reconnect loop.

Expected log lines:
NativeWebRTCAnswerer: v91 AV1 receive enabled; 6.7Mbps cap, screen 1080p/30fps, camera 720p/30fps, async NDI queue, immediate WebRTC reconnect signal
NativeWebRTCAnswerer: bridge datachannel closed; v91 requesting immediate Jitsi reconnect
JitsiSignaling: v91 media recovery requested by NativeWebRTCAnswerer, reason=bridge-datachannel-closed
MediaRecoveryWatchdog: WebRTC bridge failed; reconnecting Jitsi session immediately
