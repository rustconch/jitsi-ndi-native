v18 restores AV1 path and removes the VP8-only experiment.

Why:
- The VP8-only patch changed local Jingle/session-accept to VP8, but JVB still sent AV1 RTP PT=41.
- Current failure is in AV1 decode: FFmpeg has no libdav1d decoder and the native AV1 fallback selects/fails hardware pixel format.

Apply:
  cd D:\MEDIA\Desktop\jitsi-ndi-native
  Expand-Archive -Force .\jitsi_ndi_native_restore_av1_dav1d_v18.zip .
  powershell -ExecutionPolicy Bypass -File .\patch_restore_av1_dav1d_v18.ps1
  cmake --build build --config Release
  powershell -ExecutionPolicy Bypass -File .\copy_runtime_dlls_v18.ps1
  .\build\Release\jitsi-ndi-native.exe --room 6767676766767penxyi

If log says "libdav1d decoder is not present":
  powershell -ExecutionPolicy Bypass -File .\install_ffmpeg_dav1d_v18.ps1
  cmake --build build --config Release
  powershell -ExecutionPolicy Bypass -File .\copy_runtime_dlls_v18.ps1
  .\build\Release\jitsi-ndi-native.exe --room 6767676766767penxyi

Good log:
  FfmpegMediaDecoder: using AV1 decoder libdav1d
  video RTP endpoint=... pt=41
  AV1 video packets ... producedFrames=1
No repeated "Your platform doesn't support hardware accelerated AV1 decoding".
