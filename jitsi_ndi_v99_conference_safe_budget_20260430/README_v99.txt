jitsi-ndi-native v99 conference-safe budget

Goal:
- Keep the v98 NDI stability improvements, but stop stressing the live Jitsi conference control plane.
- Do not reduce camera/screen-share resolution or fps. Requests remain 1080p / 30 fps.

Changes:
- ReceiverVideoConstraints assumedBandwidthBps changed from v98's 250 Mbps test value to a realistic 20 Mbps observer budget.
  This is not a maxHeight/fps downgrade; it prevents JVB from treating the technical receiver as an unlimited high-priority video sink.
- selectedSources and onStageSources stay empty.
- legacy LastNChangedEvent is still not sent.
- v98 per-source AV1 decoder threading and warm/cold source-local re-prime are kept.

Expected log markers:
- NativeWebRTCAnswerer: v99 AV1 receive enabled
- ReceiverVideoConstraints/v99-conference-safe-20mbps-1080p30-local-smooth
- v99Worker=1

Install:
1. Extract this archive into D:\MEDIA\Desktop\jitsi-ndi-native
2. Run .\jitsi_ndi_v99_conference_safe_budget_20260430\apply_v99_conference_safe_budget.ps1
3. Rebuild with .\rebuild_with_dav1d_v21.ps1
