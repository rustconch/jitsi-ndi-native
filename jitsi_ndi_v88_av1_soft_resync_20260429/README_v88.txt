jitsi-ndi-native v88 AV1 soft-resync patch

What this patch changes:
- Keeps screen-share sources separate.
- Keeps screen-share constraints at 1080p / 30fps.
- Keeps camera constraints at 720p / 30fps.
- Keeps total receive assumedBandwidthBps at 6700000.
- Changes AV1 RTP loss recovery: after an RTP gap, the assembler drops only a short dependent-frame window, then soft-resumes with the cached sequence header instead of waiting forever for a keyframe.

Why:
In the latest log one source reached: v86 dropping dependent AV1 temporal unit after RTP gap until keyframe arrives, dropped=1400. That means RTP continued, audio continued, but the NDI video source was frozen because the AV1 assembler waited indefinitely for a keyframe that JVB did not send quickly.

Apply:
  cd D:\MEDIA\Desktop\jitsi-ndi-native
  Expand-Archive -Force .\jitsi_ndi_v88_av1_soft_resync_20260429.zip .
  .\jitsi_ndi_v88_av1_soft_resync_20260429\apply_v88_av1_soft_resync.ps1
  .\rebuild_with_dav1d_v21.ps1

Expected startup log:
  NativeWebRTCAnswerer: v88 AV1 soft-resync enabled; video cap 6.7Mbps, screen-share 1080p/30fps, camera 720p/30fps, no infinite keyframe wait after RTP gap
