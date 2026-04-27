# jitsi-ndi-native v34 quality patch

This patch changes only one native file:

- src/NativeWebRTCAnswerer.cpp

It does not touch GUI, NDI sender, decoder, audio, Jingle parsing, CMake files, DLLs, or existing build output.

## Goal

Request equal high priority for all known Jitsi video sources/speakers through the bridge datachannel.

## What changed

- ReceiverVideoConstraints now uses lastN = -1.
- All real sources are placed into selectedSources.
- onStageSources is kept empty to avoid one-stage-speaker behavior.
- defaultConstraints and per-source constraints ask for 1080p / 30fps.
- LastNChangedEvent with lastN = -1 is also sent as a compatibility hint.
- VideoSourcesMap messages are parsed, so constraints can be sent for all mapped video sources, not only the sources already forwarded by the bridge.
- JVB placeholder sources are filtered out more broadly: names starting with "jvb" are ignored.

## Apply

From repo root:

```powershell
cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_native_equal_priority_quality_v34_20260428.zip .
.\jitsi_ndi_native_equal_priority_quality_v34_20260428\apply_quality_v34.ps1
```

## Rebuild

After applying, rebuild the native exe:

```powershell
.\rebuild_with_dav1d_v21.ps1
```

or:

```powershell
.\jitsi_ndi_native_equal_priority_quality_v34_20260428\rebuild_after_quality_v34.ps1
```

## Run

Run the app the same way as before. No new GUI changes are required.

## Rollback

```powershell
.\jitsi_ndi_native_equal_priority_quality_v34_20260428\restore_latest_quality_v34_backup.ps1
```

## Important notes

This requests higher quality from Jitsi Videobridge. It cannot force 1080p if:
- the sender is not actually sending 1080p,
- the Jitsi server caps receiver quality,
- the room/bandwidth/CPU is insufficient,
- browser/device simulcast layers do not include a 1080p layer.
