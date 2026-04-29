v86 desktop AV1 recovery patch

Changes:
- screen-share / desktop remains a separate NDI source
- screen-share / desktop remains 1080p / 30 fps
- camera constraints are capped at 720p / 30 fps to reduce total decode pressure
- v85a's very aggressive RTP queue is relaxed so individual AV1 RTP packets are not dropped so easily
- AV1 assembler now drops dependent inter-frames after an RTP sequence gap until the next keyframe, instead of feeding broken OBU data to dav1d

Apply:
  cd D:\MEDIA\Desktop\jitsi-ndi-native
  Expand-Archive -Force .\jitsi_ndi_v86_desktop_av1_recovery_20260429.zip .
  .\jitsi_ndi_v86_desktop_av1_recovery_20260429\apply_v86_desktop_av1_recovery.ps1
  .\rebuild_with_dav1d_v21.ps1
