Jitsi NDI GUI v52 clear dashboard

Scope:
- Changes only JitsiNdiGui.ps1.
- Does not touch native/WebRTC/Jitsi/NDI/v49.
- Does not rebuild anything.
- Does not pass --nick, --quality, --width, --height or --ndi-name.
- Native launch remains: --room <room>

What changed from v51:
- Added "Что это?" help button that explains which GUI functions are real and which are only monitoring.
- Added "Снимок" button with a visible summary of the current table.
- NDI list now shows a confirmation and explains when there are no active sources.
- CSV export now shows the saved file path.
- Labels now explicitly say nickname is not applied and quality is log-only.

Apply:
cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_gui_v52_clear_dashboard_20260428.zip .
.\jitsi_ndi_gui_v52_clear_dashboard_20260428\apply_gui_v52.ps1

Run:
powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1

Restore:
.\jitsi_ndi_gui_v52_clear_dashboard_20260428\restore_latest_gui_backup_v52.ps1
