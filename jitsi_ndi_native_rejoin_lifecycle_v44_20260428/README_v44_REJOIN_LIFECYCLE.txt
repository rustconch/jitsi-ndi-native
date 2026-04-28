v44 rejoin lifecycle patch

Goal:
- Keep v43/v42 media quality/stability behavior.
- Fix stale NDI/source mappings after participant reconnect, leave/rejoin, source-remove, and display name changes.

Changes:
- Cleans stale participant pipelines when MUC presence type='unavailable' is received.
- Stops old video NDI senders on Jingle source-remove so source-add can recreate clean decoders/NDI senders.
- Updates display-name mapping for existing SSRC entries.
- If a participant changes display name, recycles only that participant's NDI pipelines so new NDI sources use the new label.
- On Jingle source-add, updates JVB receiver constraints/subscriptions with merged known video/audio sources.

Files changed:
- src/JitsiSourceMap.cpp
- src/JitsiSourceMap.h
- src/PerParticipantNdiRouter.cpp
- src/PerParticipantNdiRouter.h
- src/NativeWebRTCAnswerer.cpp
- src/NativeWebRTCAnswerer.h
- src/JitsiSignaling.cpp

Apply:
cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_native_rejoin_lifecycle_v44_20260428.zip .
.\jitsi_ndi_native_rejoin_lifecycle_v44_20260428\apply_rejoin_lifecycle_v44.ps1
.\rebuild_with_dav1d_v21.ps1

Expected log lines:
MEDIA EVENT: participant unavailable; cleaning stale NDI/source mappings.
PerParticipantNdiRouter: removing endpoint NDI pipeline ... reason=presence-unavailable
PerParticipantNdiRouter: removing stale NDI pipeline ... reason=source-remove
PerParticipantNdiRouter: display name changed ... recycling NDI pipelines
NativeWebRTCAnswerer: updating receiver subscriptions from Jingle source update

Rollback:
.\jitsi_ndi_native_rejoin_lifecycle_v44_20260428\restore_latest_rejoin_lifecycle_v44_backup.ps1
.\rebuild_with_dav1d_v21.ps1
