Jitsi NDI Native GUI v55 minimal nick/link

Purpose:
- Remove NDI scan/dashboard/watchdog/table/CSV functions from GUI.
- Keep only: Jitsi link, display nick, Start, Stop, log file.
- Fix native nickname handling: --nick is display-only; MUC resource stays technical (jitsi-ndi-native).

Apply:
  cd D:\MEDIA\Desktop\jitsi-ndi-native
  Expand-Archive -Force .\jitsi_ndi_gui_minimal_nick_link_v55_20260428.zip .
  .\jitsi_ndi_gui_minimal_nick_link_v55_20260428pply_gui_minimal_nick_link_v55.ps1
  .ebuild_with_dav1d_v21.ps1

Run:
  powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1

Notes:
- Link and nick changes apply only after Stop -> Start.
- GUI passes only --room and optionally --nick.
- GUI does not pass quality/width/height/ndi-name.
- GUI no longer scans current logs for NDI names.

Restore:
  .\jitsi_ndi_gui_minimal_nick_link_v55_20260428estore_latest_gui_minimal_nick_link_v55_backup.ps1
  .ebuild_with_dav1d_v21.ps1
