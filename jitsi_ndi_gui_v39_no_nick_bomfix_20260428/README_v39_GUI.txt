Jitsi NDI Native GUI v39 no-nick BOM fix

This patch changes only JitsiNdiGui.ps1.
It does not touch native/WebRTC/Jitsi/NDI/quality code and does not require rebuild.

Fixes:
- removed accidental double BOM at the start of JitsiNdiGui.ps1;
- disables GUI --nick sending completely, because the checkbox breaks working conference/NDI in the current build;
- the nick field remains visible but is UI-only for now;
- launch command is safe: --room only;
- quality remains monitoring-only.

Apply:
cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_gui_v39_no_nick_bomfix_20260428.zip .
.\jitsi_ndi_gui_v39_no_nick_bomfix_20260428\apply_gui_v39.ps1

Run:
powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1

Rollback:
.\jitsi_ndi_gui_v39_no_nick_bomfix_20260428\restore_latest_gui_backup_v39.ps1
