Jitsi NDI Native v72 stability optimization patch
=================================================

Scope:
- Native-only stability/latency optimization.
- Does not touch GUI.
- Does not touch Jitsi signaling logic, room join, nick, source mapping, rejoin handling, or NDI source naming.
- Requires native rebuild after applying.

Main changes:
1) Reduces high-frequency native logging in hot media paths.
   The old AV1 path could write a log line for nearly every produced frame/source.
   With 4 NDI sources this can create periodic file I/O stalls and visible latency growth.

2) Adds live-output burst trimming for video decode.
   If the decoder releases multiple frames after a temporary stall, v72 sends only the newest decoded frame.
   This prevents short overloads from accumulating into long NDI delay.

3) Uses SWS_FAST_BILINEAR for FFmpeg YUV->BGRA conversion.
   There is no resize, so this is a low-risk CPU reduction.

Apply:
  cd D:\MEDIA\Desktop\jitsi-ndi-native
  Expand-Archive -Force .\jitsi_ndi_native_stability_opt_v72_20260429.zip .
  .\jitsi_ndi_native_stability_opt_v72_20260429\apply_stability_opt_v72.ps1
  .\rebuild_with_dav1d_v21.ps1

Restore:
  .\jitsi_ndi_native_stability_opt_v72_20260429\restore_latest_stability_opt_v72_backup.ps1
  .\rebuild_with_dav1d_v21.ps1

Test recommendation:
- Run the same 10 minute stress test with 4 NDI sources.
- Watch whether NDI delay still grows and whether it normalizes faster.
- If anything gets worse, restore immediately.
