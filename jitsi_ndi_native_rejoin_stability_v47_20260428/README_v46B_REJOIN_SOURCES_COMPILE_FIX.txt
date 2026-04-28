v46b rejoin source recovery

Goal:
- Keep the stable v42/v43 quality/audio behavior.
- Keep the v45 fix that ignores participant/P2P session-terminate.
- Fix the case where a participant rejoins or changes nick, the old conference keeps working, but the new speaker does not appear as a new NDI source.

Changes:
- Presence <SourceInfo> is now also fed to NativeWebRTCAnswerer receiver constraints.
- New source ids from SourceInfo such as endpoint-v0, endpoint-v1 and endpoint-a0 are merged into known sources.
- ForwardedSources/VideoSourcesMap responses no longer overwrite the constraints with only the currently forwarded old sources. They resend the full known-source set.
- If a source update arrives while bridge datachannel is temporarily unavailable, sources are still saved and will be used on the next open/ServerHello.
- Keeps the v45 SourceInfo safety fixes so keys like muted/videoType are not treated as endpoints.

Expected logs:
- NativeWebRTCAnswerer: updating receiver subscriptions from source update
- ReceiverVideoConstraints/v42-stable-selected-only-1080p30/source-update-known-sources
- ReceiverAudioSubscription/Include-endpoint-audio/source-update-known-sources
- ForwardedSources parsed count=...; sending known-source constraints total=...

Apply:
cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_native_rejoin_sources_v46bb_20260428.zip .
.\jitsi_ndi_native_rejoin_sources_v46bb_20260428\apply_rejoin_sources_v46bb.ps1
.\rebuild_with_dav1d_v21.ps1

Rollback:
.\jitsi_ndi_native_rejoin_sources_v46bb_20260428\restore_latest_rejoin_sources_v46bb_backup.ps1
.\rebuild_with_dav1d_v21.ps1
