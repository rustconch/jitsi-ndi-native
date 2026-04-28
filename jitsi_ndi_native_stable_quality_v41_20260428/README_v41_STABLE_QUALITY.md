# jitsi-ndi-native quality v41 stable

This patch is a stability rollback from v40.

It keeps the useful quality request from v35:

- lastN = -1
- all real video sources in selectedSources
- all real video sources in onStageSources
- maxHeight = 1080
- maxFrameRate = 30
- assumedBandwidthBps = 250000000

It removes the risky v40 behavior:

- no 2160p/60 request
- no assumed bandwidth 1 Gbps
- no forced NDI 1920x1080 upscale/canvas
- no repeated bridge refresh loops after datachannel open

Changed files:

- src/NativeWebRTCAnswerer.cpp
- src/NDISender.cpp

Apply:

```powershell
cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_native_stable_quality_v41_20260428.zip .
.\jitsi_ndi_native_stable_quality_v41_20260428\apply_quality_v41.ps1
.\rebuild_with_dav1d_v21.ps1
```

Expected log markers:

- `v41 stable quality mode; repeated bridge refresh loops disabled`
- `ReceiverVideoConstraints/v41-stable-all-on-stage-1080p30`
- `requesting v41 stable all-on-stage 1080p/30fps constraints`

Rollback:

```powershell
.\jitsi_ndi_native_stable_quality_v41_20260428\restore_latest_quality_v41_backup.ps1
.\rebuild_with_dav1d_v21.ps1
```
