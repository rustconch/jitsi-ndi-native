jitsi-ndi-native v22 1080p quality patch

What it changes:
- Requests 1080p from Jitsi Videobridge instead of 720p via ReceiverVideoConstraints.
- Raises assumedBandwidthBps from 20 Mbps to 60 Mbps.
- Keeps video constraints refreshed for longer after join/reconnect/forwarded-source changes.
- Sets fallback/status pattern defaults to 1920x1080.

Important:
- This requests 1080p; it cannot create real 1080p if the remote participant is only sending 720p.
- For real 1080p, the camera/source and meet.jit.si/JVB must provide a 1080p layer.

Apply from repository root:

cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_native_1080p_quality_v22.zip .
powershell -ExecutionPolicy Bypass -File .\patch_1080p_quality_v22.ps1
.\build\Release\jitsi-ndi-native.exe --room 6767676766767penxyi

Check logs for:
NativeWebRTCAnswerer: requesting 1080p video constraints
EndpointStats ... maxEnabledResolution ... 1080
