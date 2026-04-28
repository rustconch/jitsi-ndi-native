jitsi-ndi-native v49 rejoin renegotiate patch

Purpose:
- Fix rejoined participant source not appearing in NDI after Jitsi source-add.
- Keep v48 cleanup: no NDI pre-create, no jvb/ssrc placeholder sources.
- Add remote SDP source-add update in NativeWebRTCAnswerer.

Why:
- Jitsi source-add announces new SSRCs after participant rejoin.
- Receiver constraints alone can make ForwardedSources list the new source,
  but the native PeerConnection may not deliver RTP for SSRCs that were not
  present in the remote SDP-like offer.
- v49 injects source-add SSRC lines into the stored remote offer and calls
  setRemoteDescription + setLocalDescription, similar to how Jitsi clients
  update remote descriptions on source-add.

Expected log lines:
- NativeWebRTCAnswerer: v49 source-add remote SDP update mode enabled
- NativeWebRTCAnswerer: applying v49 remote SDP source-add update; addedSsrcs=...
- NativeWebRTCAnswerer: updating receiver subscriptions from source update...

Apply:
  .\jitsi_ndi_native_rejoin_renegotiate_v49_20260428\apply_rejoin_renegotiate_v49.ps1
  .\rebuild_with_dav1d_v21.ps1

Rollback:
  .\jitsi_ndi_native_rejoin_renegotiate_v49_20260428\restore_latest_rejoin_renegotiate_v49_backup.ps1
  .\rebuild_with_dav1d_v21.ps1
