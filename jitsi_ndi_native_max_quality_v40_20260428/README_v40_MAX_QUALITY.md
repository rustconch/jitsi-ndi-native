# jitsi-ndi-native v40 max-quality patch

This patch changes only native quality/output files:

- `src/NativeWebRTCAnswerer.cpp`
- `src/NDISender.cpp`

It does not change GUI, signaling room parsing, participant routing, CMake, DLL files, or build scripts.

## What it does

1. Requests a more aggressive Jitsi bridge allocation:
   - `lastN = -1`
   - every real video source in `selectedSources`
   - every real video source in `onStageSources`
   - `defaultConstraints.maxHeight = 2160`
   - per-source `maxHeight = 2160`
   - `maxFrameRate = 60.0`
   - `assumedBandwidthBps = 1000000000`
   - faster repeated refresh of the constraints during startup

2. Forces decoded NDI output to at least a 1920x1080 canvas:
   - 960x540 -> 1920x1080
   - 1280x720 -> 1920x1080
   - non-16:9 video is aspect-fit with black padding
   - frames already Full HD or larger are not downscaled

Important: the NDI upscale makes the NDI source Full HD, but it cannot invent real detail if Jitsi/JVB only sends 540p.

## Apply

```powershell
cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_native_max_quality_v40_20260428.zip .
.\jitsi_ndi_native_max_quality_v40_20260428\apply_quality_v40.ps1
.\rebuild_with_dav1d_v21.ps1
```

Alternative rebuild:

```powershell
.\jitsi_ndi_native_max_quality_v40_20260428\rebuild_after_quality_v40.ps1
```

## Expected log markers

```text
requesting all-on-stage MAX 2160p/60fps constraints
ReceiverVideoConstraints/all-on-stage-2160p60
NDI video frame sent: ... 1920x1080 upscaled-from=960x540
NDI video frame sent: ... 1920x1080 upscaled-from=1280x720
```

## Restore

```powershell
.\jitsi_ndi_native_max_quality_v40_20260428\restore_latest_quality_v40_backup.ps1
.\rebuild_with_dav1d_v21.ps1
```
