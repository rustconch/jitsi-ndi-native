v26 equal 1080p speakers patch

Goal:
- Do not prioritize only the dominant speaker.
- Ask Jitsi Videobridge to treat every real participant video source as selected and on-stage.
- Give every real participant source the same 1080p / 30 fps ReceiverVideoConstraints.
- Do not touch RTP, AV1 assembler, decoder, or NDI sender. This keeps the currently working media path from v25 intact.

Run from repository root:

cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_native_equal_1080p_speakers_v26_flat.zip .
powershell -ExecutionPolicy Bypass -File .\patch_equal_1080p_speakers_v26.ps1
.\build\Release\jitsi-ndi-native.exe --room 6767676766767penxyi

Expected log checks:
- NativeWebRTCAnswerer: requesting equal 1080p/30fps constraints, realSources=2
- ReceiverVideoConstraints/equal-1080p/...
- NDI video frame sent: ... 1920x1080 for each real participant, if Jitsi/JVB can supply 1080p for that participant.

Important:
- This cannot invent true 1080p if a participant's browser/camera/Jitsi sender is only publishing 720p.
- If a participant remains 1280x720, the useful next check is whether that participant itself can send 1080p in the normal Jitsi client.
- If quality gets unstable, run rollback_v26.ps1 and rebuild.

Rollback:

powershell -ExecutionPolicy Bypass -File .\rollback_v26.ps1
cmake --build build --config Release
