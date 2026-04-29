v96 rollback-stable from v94

Purpose:
- v95 made things worse: both screen-share streams broke and the local-PC speaker camera froze.
- This patch removes the risky v95 behavior and returns to the better v94 behavior.

Removed from v95:
- no same-device 720p camera cap;
- no forced decoded-frame resize/clamp before NDI;
- no overly aggressive camera/desktop AV1 decoder reset thresholds;
- no tighter v95 queues.

Kept from the good builds:
- screen-share remains a separate NDI source;
- screen-share remains 1080p / 30 fps request;
- cameras remain 1080p / 30 fps request;
- total receive cap remains 6.0 Mbps;
- observer-safe selectedSources/onStageSources remain empty;
- old LastNChangedEvent is not sent;
- source-local AV1 recovery remains, but with v94 conservative thresholds;
- silent/muted Jitsi join patch is preserved.

Apply:
cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_v96_rollback_stable_v94_20260429.zip .
.\jitsi_ndi_v96_rollback_stable_v94_20260429\apply_v96_rollback_stable_v94.ps1
.\rebuild_with_dav1d_v21.ps1

Expected log markers:
NativeWebRTCAnswerer: v96 AV1 receive enabled
ReceiverVideoConstraints/v96-observer-safe-cap6000kbps-1080p30-local-smooth
PerParticipantNdiRouter: v96 per-source video worker started
