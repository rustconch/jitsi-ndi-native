Jitsi NDI Native v72c stability optimization patch

This is the same conservative v72 stability patch, with repo-root detection fixed for Windows PowerShell.

Changes are native-only:
- reduce hot-path video/audio logging;
- trim decoded video bursts to newest frame for lower live latency;
- use SWS_FAST_BILINEAR for FFmpeg conversion.

Apply:
  cd D:\MEDIA\Desktop\jitsi-ndi-native
  Expand-Archive -Force .\jitsi_ndi_native_stability_opt_v72c_fix_20260429.zip .
  .\jitsi_ndi_native_stability_opt_v72c_fix_20260429\apply_stability_opt_v72c.ps1
  .\rebuild_with_dav1d_v21.ps1

Restore:
  .\jitsi_ndi_native_stability_opt_v72c_fix_20260429\restore_latest_stability_opt_v72c_backup.ps1
  .\rebuild_with_dav1d_v21.ps1
