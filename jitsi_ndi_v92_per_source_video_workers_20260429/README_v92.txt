v92 per-source video workers

Purpose:
- Do NOT reconnect the whole Jitsi/WebRTC session when one video source misbehaves.
- Keep screen shares separate NDI sources.
- Keep screen shares at 1080p / 30 fps.
- Keep cameras at 720p / 30 fps.
- Keep AV1 receive and existing 6.7 Mbps receive cap.
- Keep audio path unchanged.

Changes:
- Removes v91 immediate global reconnect behavior.
- Disables the main global reconnect watchdog loop.
- Adds one source-local video worker queue per NDI video pipeline.
- Heavy/broken camera or screen source can drop/recover locally without blocking the other NDI sources.

Expected startup log:
NativeWebRTCAnswerer: v92 AV1 receive enabled; 6.7Mbps cap, screen 1080p/30fps, camera 720p/30fps, async NDI queue; global reconnect disabled
v92: global reconnect watchdog disabled; recovery is source-local via per-source video workers
PerParticipantNdiRouter: v92 per-source video worker started endpoint=...

Apply:
cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_v92_per_source_video_workers_20260429.zip .
.\jitsi_ndi_v92_per_source_video_workers_20260429\apply_v92_per_source_video_workers.ps1
.\rebuild_with_dav1d_v21.ps1
