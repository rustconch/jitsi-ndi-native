Jitsi NDI Native v76 TURN/UDP stability patch

Your log shows WebRTC PeerConnection failed/closed after several minutes:
PeerConnection state=4, state=5, bridge datachannel closed, remote tracks closed.
This is not an NDI freeze and not a decoder freeze: RTP counters stop because the WebRTC transport dies.

v76 passes Jitsi meet.jit.si TURN/UDP credentials from room_metadata to libdatachannel instead of using only STUN.
TURNS/TLS remains skipped, but TURN/UDP may improve long-running NAT/network stability.

Files changed:
- src/JitsiSignaling.cpp
- src/NativeWebRTCAnswerer.cpp

Apply:
  cd D:\MEDIA\Desktop\jitsi-ndi-native
  Expand-Archive -Force .\jitsi_ndi_native_turn_udp_stability_v76_20260429.zip .
  .\jitsi_ndi_native_turn_udp_stability_v76_20260429\apply_turn_udp_stability_v76.ps1
  .\rebuild_with_dav1d_v21.ps1

Restore:
  .\jitsi_ndi_native_turn_udp_stability_v76_20260429\restore_latest_turn_udp_stability_v76_backup.ps1
  .\rebuild_with_dav1d_v21.ps1

Expected new log lines:
  Jitsi TURN/UDP metadata parsed and passed to libdatachannel
  Jitsi ICE server: turn:***@meet-jit-si-turnrelay.jitsi.net:443?transport=udp
  Jitsi ICE server: stun:meet-jit-si-turnrelay.jitsi.net:443

If PeerConnection state=4/5 still happens, the next step is controlled reconnect, not more NDI/decoder tuning.
