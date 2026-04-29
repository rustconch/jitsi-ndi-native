v93 camera1080 local smooth patch

Apply from repo root:
  Expand-Archive -Force .\jitsi_ndi_v93_camera1080_local_smooth_20260429.zip .
  .\jitsi_ndi_v93_camera1080_local_smooth_20260429\apply_v93_camera1080_local_smooth.ps1
  .\rebuild_with_dav1d_v21.ps1

What changed from v92:
  - Keeps v92 as the base: per-source video workers stay enabled.
  - Does NOT re-enable global WebRTC/Jitsi reconnect.
  - Screen-share/desktop sources remain separate NDI sources at 1080p / 30 fps.
  - Camera sources are requested at 1080p / 30 fps again.
  - The 6.7 Mbps receive-side cap remains.
  - Adds conservative source-local AV1 decoder soft reset:
      if one source keeps receiving AV1 temporal units but produces no decoded frames
      for about 1.5 seconds, only that source's FFmpeg AV1 decoder is flushed.
      Other NDI sources and audio are not touched.

Useful log markers:
  - NativeWebRTCAnswerer: v93 AV1 receive enabled...
  - ReceiverVideoConstraints/v93-cap6700kbps-screen1080p30-camera1080p30-local-smooth/...
  - PerParticipantNdiRouter: AV1 video packets ... decodedFrames=... v93Worker=1
  - PerParticipantNdiRouter: v93 source-local AV1 decoder soft reset ...

Rollback:
  .\jitsi_ndi_v93_camera1080_local_smooth_20260429\restore_latest_v93_camera1080_local_smooth_backup.ps1
  .\rebuild_with_dav1d_v21.ps1
