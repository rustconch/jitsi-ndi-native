Jitsi NDI GUI v62 clean visual patch

Changes only JitsiNdiGui.ps1.
Native/WebRTC/Jitsi/NDI code is not changed.
No rebuild is required.

Changes:
- removed extra explanatory UI text
- removed startup explanatory GUI log lines
- removed Exe... button
- removed Copy command button
- kept existing working launch logic: --room and optional --nick
- kept Open log and Logs folder buttons

Apply:
cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_gui_visual_v62_clean_20260428.zip .
.\jitsi_ndi_gui_visual_v62_clean_20260428\apply_gui_visual_v62.ps1

Run:
powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1

Restore:
.\jitsi_ndi_gui_visual_v62_clean_20260428\restore_latest_gui_backup_v62.ps1
