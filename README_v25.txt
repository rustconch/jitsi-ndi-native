v25 rescue patch

What it fixes:
- Rolls back the risky v24 NativeWebRTCAnswerer/router changes using the .bak_v24_* files created by v24.
- Adds ACK + source map update for Jingle source-add/source-remove IQs.
- Prevents direct P2P endpoint transport-info candidates from being injected into the active focus/JVB PeerConnection.
- Keeps dav1d AV1 decoding and removes fake 1920x1080 decoder upscaling if it is still present.

Run from repository root:

cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_native_rescue_sourceadd_transport_v25_flat.zip .
powershell -ExecutionPolicy Bypass -File .\patch_rescue_sourceadd_transport_v25.ps1
.\build\Release\jitsi-ndi-native.exe --room 6767676766767penxyi

Important log checks:
- MEDIA EVENT: Jingle source-add detected; updating source map and ACKing.
- MEDIA EVENT: ignoring non-focus/P2P transport-info ...
- Runtime stats must no longer stay at audio RTP packets=0 video RTP packets=0.
- FfmpegMediaDecoder: using AV1 decoder libdav1d.
