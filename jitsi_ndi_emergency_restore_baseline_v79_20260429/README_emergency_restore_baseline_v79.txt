jitsi-ndi-native emergency restore baseline v79

Purpose:
- Remove the experimental v77/v78/v78a/v78b stability layer from runtime/signaling.
- Restore the working baseline behavior: no automatic full reconnect, no soft refresh loop, no recoveryHints path.
- Keep the existing media router/AV1 assembler/decoders/NDI files untouched.

Files restored:
- src/main.cpp: restored to the pre-watchdog backup main.cpp.bak_v59b_20260428_172430 from the user's source archive.
- src/NativeWebRTCAnswerer.cpp/.h: restored from the user's uploaded source archive before v78 changes.
- src/JitsiSignaling.cpp/.h: restored from the user's uploaded source archive before v78 changes.

Apply:
  cd D:\MEDIA\Desktop\jitsi-ndi-native
  Expand-Archive -Force .\jitsi_ndi_emergency_restore_baseline_v79_20260429.zip .
  .\jitsi_ndi_emergency_restore_baseline_v79_20260429\apply_emergency_restore_baseline_v79.ps1
  .\rebuild_with_dav1d_v21.ps1

Restore previous state if needed:
  .\jitsi_ndi_emergency_restore_baseline_v79_20260429\restore_latest_emergency_restore_baseline_v79_backup.ps1
  .\rebuild_with_dav1d_v21.ps1

Expected result:
- No log lines with STABILITY_WATCHDOG_V77, v78, v78a, v78b, recoveryHints, or soft refresh.
- The app should behave like the known working baseline again.
