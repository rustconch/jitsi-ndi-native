jitsi-ndi-native v23 1080p stability patch

What it changes:
- Keeps AV1/libdav1d path intact.
- Requests 1080p at 30 fps from Jitsi Videobridge.
- Raises assumedBandwidthBps to 100 Mbps in ReceiverVideoConstraints.
- Reduces early duplicate video-constraint refreshes to avoid layer churn.
- Forces decoded video frames to 1920x1080 before NDI, so the NDI source itself is 1080p.
- Adds real NDI frame dimension logs.

Apply from repository root:

cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_native_1080p_stability_v23.zip .
powershell -ExecutionPolicy Bypass -File .\patch_1080p_stability_v23.ps1
.\build\Release\jitsi-ndi-native.exe --room 6767676766767penxyi

After launch, check for:
- NativeWebRTCAnswerer: requesting 1080p/30fps video constraints
- NDI video frame sent: ... 1920x1080
- EndpointStats ... maxEnabledResolution ... 1080

Important:
If EndpointStats still says maxEnabledResolution 720, meet.jit.si or the remote sender is not providing a real 1080p layer. In that case v23 still makes NDI output 1920x1080, but the visual detail is upscaled from the lower incoming stream.
