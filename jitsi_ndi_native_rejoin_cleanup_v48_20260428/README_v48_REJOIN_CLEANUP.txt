v48 rejoin cleanup patch

Purpose:
- Keep the v45/v46 fix that prevents P2P session-terminate from killing the main JVB session.
- Remove v47 metadata-only NDI pre-creation, which caused extra NDI inputs such as jvb video, camera/video placeholders, and sources with no media.
- Drop JVB/mixed placeholder RTP for both audio and video.
- Stop creating ssrc-* NDI placeholder inputs once the real Jitsi source map is known.
- Prefer the participant display name stored from presence when creating camera/screen NDI names.
- If a pipeline was created before the nick became known, recycle it once when the nick arrives so NDI source names are rebuilt.
- ACK source-add before local source-map/bridge updates to reduce rejoin race conditions.
- Remove v47 delayed retry bursts; keep only immediate receiver constraint updates.

Apply:
cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_native_rejoin_cleanup_v48_20260428.zip .
.\jitsi_ndi_native_rejoin_cleanup_v48_20260428\apply_rejoin_cleanup_v48.ps1
.\rebuild_with_dav1d_v21.ps1

Expected log lines:
MEDIA EVENT: Jingle source-add detected; ACKing first, then updating source map.
NativeWebRTCAnswerer: v48 stable rejoin mode; selected-only video; endpoint-only audio; no NDI pre-create; no delayed retry bursts
PerParticipantNdiRouter: dropping JVB/mixed placeholder RTP ...
PerParticipantNdiRouter: dropping unknown SSRC ... not creating ssrc-* NDI placeholder

Rollback:
.\jitsi_ndi_native_rejoin_cleanup_v48_20260428\restore_latest_rejoin_cleanup_v48_backup.ps1
.\rebuild_with_dav1d_v21.ps1
