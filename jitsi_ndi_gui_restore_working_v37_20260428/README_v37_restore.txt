Jitsi NDI GUI restore working v37

This patch changes only JitsiNdiGui.ps1.
Native/WebRTC/Jitsi/NDI/CMake/build files are not changed.

Important:
- v36 could reuse JitsiNdiGui.settings.json and a wrong exe path.
- This restore disables that settings file and returns GUI launch logic to v33-style baseline.

Apply from repo root:
cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_gui_restore_working_v37_20260428.zip .
.\jitsi_ndi_gui_restore_working_v37_20260428\apply_gui_restore_working_v37.ps1

Run:
powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1

If NDI still shows only placeholder, click Exe... and select the exact working rebuilt exe, usually:
D:\MEDIA\Desktop\jitsi-ndi-native\build-ndi\Release\jitsi-ndi-native.exe

Rollback:
.\jitsi_ndi_gui_restore_working_v37_20260428\restore_latest_gui_backup_v37.ps1
