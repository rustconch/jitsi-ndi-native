jitsi-ndi-native v87 receive bitrate cap

Purpose:
- Keep v86 desktop AV1 recovery.
- Keep screen-share / desktop as separate NDI sources.
- Keep screen-share at 1080p / 30 fps. This patch does not restore 15 fps.
- Add a JVB receive-side video bitrate hint/cap via ReceiverVideoConstraints assumedBandwidthBps=6700000.
- Keep cameras at 720p / 30 fps to reduce decode and NDI sender pressure.

Expected log line:
NativeWebRTCAnswerer: v87 receive bitrate cap enabled; video cap 6.7Mbps, screen-share 1080p/30fps, camera 720p/30fps, AV1-safe RTP queue

Apply:
cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_v87_receive_bitrate_cap_20260429.zip .
.\jitsi_ndi_v87_receive_bitrate_cap_20260429\apply_v87_receive_bitrate_cap.ps1
.\rebuild_with_dav1d_v21.ps1
