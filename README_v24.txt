Jitsi NDI native v24 quality/stutter patch

What it changes:
1. Reverts v23 forced 1920x1080 upscale in FfmpegMediaDecoder.cpp.
   This was making NDI look worse when the real incoming stream was 720p/540p.
2. Keeps asking Jitsi Videobridge for real 1080p, but NDI no longer fakes it.
3. Moves decoding and NDI sending outside the router's global lock, reducing stalls/backlog.
4. Logs actual NDI output size.

Important:
If the log says NDI video frame sent: 1280x720 or 960x540, then the native receiver is not receiving 1080p from Jitsi/JVB. In that case the NDI output cannot become real 1080p without upscaling.

Run from repository root:
  cd D:\MEDIA\Desktop\jitsi-ndi-native
  powershell -ExecutionPolicy Bypass -File .\patch_1080p_quality_revert_stutter_v24.ps1
  .\build\Release\jitsi-ndi-native.exe --room 6767676766767penxyi
