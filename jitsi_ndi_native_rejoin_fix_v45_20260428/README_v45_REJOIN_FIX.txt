Jitsi NDI Native v45 rejoin fix

Scope:
- GUI is not changed.
- Quality settings are not changed.
- NDI sender and decoders are not changed.
- Only rejoin/session lifecycle parsing is changed.

Fixes:
1. Ignores P2P/non-active session-terminate messages.
   The log line "Turning off P2P session" from a participant must not reset the main JVB PeerConnection.
2. Fixes SourceInfo parsing.
   Nested JSON metadata keys like "muted" and "videoType" are no longer treated as endpoints.

Expected logs:
- MEDIA EVENT: ignoring non-active/P2P session-terminate ...
- No more display name changed for endpoint=muted

Apply:
cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_native_rejoin_fix_v45_20260428.zip .
.\jitsi_ndi_native_rejoin_fix_v45_20260428\apply_rejoin_fix_v45.ps1
.\rebuild_with_dav1d_v21.ps1

Rollback:
.\jitsi_ndi_native_rejoin_fix_v45_20260428\restore_latest_rejoin_fix_v45_backup.ps1
.\rebuild_with_dav1d_v21.ps1
