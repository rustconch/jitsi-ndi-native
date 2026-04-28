# jitsi-ndi-native quality v42: stable selected-only 1080p

This patch changes only:

- `src/NativeWebRTCAnswerer.cpp`

It is a stability fix after v41 all-on-stage could freeze the bridge/datachannel when multiple participants had camera + screen-share streams.

## Behavior

- Keeps `lastN = -1`.
- Keeps all real video sources in `selectedSources`.
- Requests `1080p / 30fps` per source.
- Keeps `assumedBandwidthBps = 250000000`.
- Sets `onStageSources = []` intentionally.
- Keeps repeated video refresh loops disabled.
- Does not modify GUI, NDI sender, audio decoder, video decoder, CMake, or DLL files.

## Apply

```powershell
cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_native_stable_selected_quality_v42_20260428.zip .
.\jitsi_ndi_native_stable_selected_quality_v42_20260428\apply_quality_v42.ps1
.\rebuild_with_dav1d_v21.ps1
```

## Expected log lines

```text
v42 stable selected-only quality mode; all-on-stage disabled; repeated bridge refresh loops disabled
requesting v42 stable selected-only 1080p/30fps constraints
ReceiverVideoConstraints/v42-stable-selected-only-1080p30
```

## Restore

```powershell
.\jitsi_ndi_native_stable_selected_quality_v42_20260428\restore_latest_quality_v42_backup.ps1
.\rebuild_with_dav1d_v21.ps1
```
