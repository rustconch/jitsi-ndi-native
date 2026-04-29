jitsi-ndi-native fast recovery v78b safe rollback

Why this patch exists:
- v78a changed ReceiverVideoConstraints too much: selectedSources became empty and assumedBandwidthBps was capped.
- In testing this correlated with RTP sequence gaps and dav1d AV1 OBU parse errors.

What this patch changes:
- Restores the proven v42 video subscription shape:
  selectedSources = all real video sources
  onStageSources = empty
  assumedBandwidthBps = 250000000
  maxHeight = 1080, maxFrameRate = 30.0
- Keeps full reconnect disabled as the primary watchdog path.
- Makes soft refresh passive: WebRTC health hints are logged, but do not immediately resend constraints while RTP may still be flowing.
- Soft refresh now only happens after an actual RTP stall:
  video idle >= 12s, or audio+video idle >= 18s, with a 15s cooldown.
- Does not touch AV1 assembler, decoders, NDI routing, GUI, display name, or logging foundation.

Apply:
  cd D:\MEDIA\Desktop\jitsi-ndi-native
  Expand-Archive -Force .\jitsi_ndi_fast_recovery_v78b_safe_20260429.zip .
  .\jitsi_ndi_fast_recovery_v78b_safe_20260429\apply_fast_recovery_v78b_safe.ps1
  .\rebuild_with_dav1d_v21.ps1

Restore:
  .\jitsi_ndi_fast_recovery_v78b_safe_20260429\restore_latest_fast_recovery_v78b_safe_backup.ps1
  .\rebuild_with_dav1d_v21.ps1

Expected logs:
  NativeWebRTCAnswerer: requesting v78b restored v42 selected-only 1080p/30fps constraints
  StabilityWatchdog: WebRTC health hint received ... v78b will not refresh immediately while RTP may still be flowing
  StabilityWatchdog: v78b soft refresh, reason=video-rtp-stall-...
