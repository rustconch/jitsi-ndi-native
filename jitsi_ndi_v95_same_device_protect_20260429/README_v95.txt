v95 same-device protect

Why this patch exists:
- The latest log strongly suggests the unstable participant may be the browser user running on the same PC as jitsi-ndi-native.
- That PC has to encode camera/screen for Jitsi while also receiving, AV1-decoding, and sending multiple NDI outputs.
- Audio can stay fine while video freezes because video decode/NDI/capture pressure is much heavier.

Changes:
- Keeps screen-share/demonstration as separate NDI sources.
- Keeps screen-share requested at 1080p / 30fps. It does NOT reduce screen-share to 15 fps.
- Keeps ordinary cameras requested at 1080p / 30fps.
- If one endpoint has both camera (-v0) and screen/another video source (-v1), only that endpoint camera is requested at 720p / 30fps.
  This is meant to protect the same-device speaker without degrading other speakers.
- ReceiverVideoConstraints still uses empty selectedSources/onStageSources and no legacy LastNChangedEvent.
- Tighter per-camera RTP queue and faster source-local AV1 decoder reset for camera stalls.
- Oversized decoded frames are clamped before NDI to <=1920x1080, preserving aspect ratio. This protects cases where screen share arrives as 2880x1800 despite 1080p constraints.
- NDI sources are kept alive; no global reconnect is forced.

Apply:
cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_v95_same_device_protect_20260429.zip .
.\jitsi_ndi_v95_same_device_protect_20260429\apply_v95_same_device_protect.ps1
.\rebuild_with_dav1d_v21.ps1

Useful log markers:
NativeWebRTCAnswerer: v95 AV1 receive enabled
ReceiverVideoConstraints/v95-same-device-protect-cap6000kbps-screen1080-cameraadaptive30-local-smooth
protectedCameraSources=1
PerParticipantNdiRouter: v95 clamped oversized decoded frame before NDI
PerParticipantNdiRouter: v95 source-local AV1 decoder soft reset
