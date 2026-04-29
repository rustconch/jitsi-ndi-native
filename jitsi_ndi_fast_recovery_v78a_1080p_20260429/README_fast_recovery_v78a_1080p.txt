jitsi-ndi-native fast recovery v78a

What this patch changes:
- Removes v77 full disconnect/connect as the primary watchdog recovery path.
- Adds a soft receiver refresh path that re-sends ReceiverVideoConstraints and ReceiverAudioSubscription without leaving the Jitsi room.
- Keeps the video request at 1080p/30; this revision does not lower the resolution setting.
- Raises recovery hints when PeerConnection becomes disconnected/failed/closed, bridge datachannel closes/errors, or remote tracks close.
- Keeps NDI/media routing, RTP parsing, decoders, GUI, display name, and logging foundation untouched.

Apply:
  cd D:\MEDIA\Desktop\jitsi-ndi-native
  Expand-Archive -Force .\jitsi_ndi_fast_recovery_v78a_1080p_20260429.zip .
  .\jitsi_ndi_fast_recovery_v78a_1080p_20260429\apply_fast_recovery_v78a_1080p.ps1
  .\rebuild_with_dav1d_v21.ps1

Restore:
  .\jitsi_ndi_fast_recovery_v78a_1080p_20260429\restore_latest_fast_recovery_v78a_1080p_backup.ps1
  .\rebuild_with_dav1d_v21.ps1

Important log lines to watch:
  NativeWebRTCAnswerer: requesting v78a stable all-sources 1080p/30fps constraints
  StabilityWatchdog: v78a soft refresh, reason=video-rtp-stall-...
  NativeWebRTCAnswerer: v78a soft refresh requested
  StabilityWatchdog: hard RTP stall detected ... v78a does not auto-disconnect
