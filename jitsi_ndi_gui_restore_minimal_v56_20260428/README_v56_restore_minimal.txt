v56 restore minimal safe

Purpose:
- undo the native nick/resource change from v55;
- install a minimal GUI that starts native with --room only;
- remove NDI scanning/dashboard/watchdog/buttons from GUI.

Apply:
  cd D:\MEDIA\Desktop\jitsi-ndi-native
  Expand-Archive -Force .\jitsi_ndi_gui_restore_minimal_v56_20260428.zip .
  .\jitsi_ndi_gui_restore_minimal_v56_20260428\apply_restore_minimal_v56.ps1
  .\rebuild_with_dav1d_v21.ps1

Run:
  powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1

Rollback v56:
  .\jitsi_ndi_gui_restore_minimal_v56_20260428\restore_latest_restore_minimal_v56_backup.ps1
  .\rebuild_with_dav1d_v21.ps1
