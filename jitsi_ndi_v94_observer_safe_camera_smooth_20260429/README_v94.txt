v94 observer-safe camera smoothing patch

What changed from v93:
- Keeps v92/v93 global reconnect disabled.
- Does not send the legacy LastNChangedEvent anymore.
- ReceiverVideoConstraints now uses observer-safe mode: selectedSources and onStageSources are empty, while per-source constraints still request 1080p/30fps.
- Receive cap reduced from 6.7 Mbps to 6.0 Mbps to be less aggressive in the room.
- The conference request is patched to startSilent/startAudioMuted/startVideoMuted=true, so the native receiver behaves more like a quiet technical observer.
- Camera sources use a smaller per-source queue and drop stale queued RTP older than ~330 ms. Screen-share keeps a larger queue because it worked well in v93.
- Camera-local AV1 decoder soft reset reacts sooner than desktop reset and forces the cached AV1 sequence header to be prepended after a local decoder flush.
- FFmpeg log callback suppresses repeated transient libdav1d messages: "Error parsing OBU data" and "Error parsing frame header". Other FFmpeg messages still pass through.

Apply:
cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_v94_observer_safe_camera_smooth_20260429.zip .
.\jitsi_ndi_v94_observer_safe_camera_smooth_20260429\apply_v94_observer_safe_camera_smooth.ps1
.\rebuild_with_dav1d_v21.ps1

Watch for logs:
NativeWebRTCAnswerer: v94 AV1 receive enabled...
ReceiverVideoConstraints/v94-observer-safe-cap6000kbps-1080p30-local-smooth/...
PerParticipantNdiRouter: ... v94Worker=1
PerParticipantNdiRouter: v94 dropped stale queued video RTP ...
PerParticipantNdiRouter: v94 source-local AV1 decoder soft reset ...

Important test:
After the native app joins, check whether normal Jitsi participants still see each other's cameras and screen shares.
