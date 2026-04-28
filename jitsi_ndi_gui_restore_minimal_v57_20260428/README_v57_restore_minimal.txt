jitsi-ndi-native GUI v57 minimal safe fix

This patch changes only JitsiNdiGui.ps1.
It fixes two v56 GUI runtime errors:
1) TextBox.PerformClick() does not exist in Windows Forms.
2) ProcessStartInfo.ArgumentList is not reliable in Windows PowerShell 5.1 / .NET Framework, so v57 uses ProcessStartInfo.Arguments.

No native files are changed. Rebuild is not required.
The GUI still launches native with --room only. It does not pass --nick, --quality, --width, --height, or --ndi-name.

Apply:
  cd D:\MEDIA\Desktop\jitsi-ndi-native
  Expand-Archive -Force .\jitsi_ndi_gui_restore_minimal_v57_20260428.zip .
  .\jitsi_ndi_gui_restore_minimal_v57_20260428\apply_restore_minimal_v57.ps1

Run:
  powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1

Rollback:
  .\jitsi_ndi_gui_restore_minimal_v57_20260428\restore_latest_restore_minimal_v57_backup.ps1
