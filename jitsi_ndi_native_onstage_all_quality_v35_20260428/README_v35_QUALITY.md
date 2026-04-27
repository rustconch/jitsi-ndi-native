# Quality patch v35: all sources as on-stage

This patch changes only:

- `src/NativeWebRTCAnswerer.cpp`

It does not touch GUI, NDI sender, audio, decoders, CMake, DLLs, or build scripts.

## What changed compared with v34

v34 sent all real sources as `selectedSources`, but intentionally left `onStageSources` empty.
This v35 patch sends all real video sources as both:

- `selectedSources`
- `onStageSources`

The reason is that Jitsi Videobridge gives higher-resolution allocation priority to on-stage sources. `selectedSources` mainly moves sources to the top of the allocation order, while `onStageSources` is the stronger signal for high-resolution forwarding.

The message remains soft/fallback-safe: if Jitsi cannot actually forward 1080p for a source, it will still forward the best available layer.

## Apply

Run from repository root:

```powershell
cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_native_onstage_all_quality_v35_20260428.zip .
.\jitsi_ndi_native_onstage_all_quality_v35_20260428\apply_quality_v35.ps1
```

Then rebuild:

```powershell
.\rebuild_with_dav1d_v21.ps1
```

or:

```powershell
.\jitsi_ndi_native_onstage_all_quality_v35_20260428\rebuild_after_quality_v35.ps1
```

## Expected log lines

Look for:

```text
requesting all-on-stage 1080p/30fps constraints
ReceiverVideoConstraints/all-on-stage-1080p
onStageSources
```

## Rollback

```powershell
.\jitsi_ndi_native_onstage_all_quality_v35_20260428\restore_latest_quality_v35_backup.ps1
.\rebuild_with_dav1d_v21.ps1
```
