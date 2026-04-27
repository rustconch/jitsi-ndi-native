jitsi-ndi-native v27 - separate screen-share NDI sources

What this patch does:
- Splits camera and desktop/screen-share from the same participant into separate NDI sources.
- Uses Jitsi source names as video pipeline keys, e.g.:
  - 13578e8f-v0 camera
  - 13578e8f-v1 screen
  - 2eba7589-v0 camera
- Keeps participant audio attached to the camera source, not to the screen-share source.
- Keeps the v26 equal 1080p constraints untouched.
- Does not change RTP receive, AV1 depacketizer, FFmpeg decoders, or NDI send functions except for separating pipeline ownership.

Install:
  cd D:\MEDIA\Desktop\jitsi-ndi-native
  Expand-Archive -Force .\jitsi_ndi_native_separate_screenshare_sources_v27_flat.zip .
  powershell -ExecutionPolicy Bypass -File .\patch_separate_screenshare_sources_v27.ps1
  .uild\Release\jitsi-ndi-native.exe --room 6767676766767penxyi

Expected logs:
  created NDI participant source: JitsiNativeNDI - 13578e8f-v0 camera endpoint=13578e8f-v0
  created NDI participant source: JitsiNativeNDI - 13578e8f-v1 screen endpoint=13578e8f-v1
  video RTP endpoint=13578e8f-v1 source=13578e8f-v1 type=desktop

Rollback:
  powershell -ExecutionPolicy Bypass -File .ollback_v27.ps1
