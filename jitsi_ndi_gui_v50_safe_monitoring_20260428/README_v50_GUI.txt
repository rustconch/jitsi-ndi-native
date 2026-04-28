Jitsi NDI Native GUI v50 safe monitoring

This patch replaces only JitsiNdiGui.ps1.
It does not change native/WebRTC/Jitsi/NDI code and does not require rebuild.

Safety rules:
- launch arguments stay --room only
- no --nick
- no --quality
- no --width / --height
- no --ndi-name
- no settings.json
- no saved exe path

Apply:
cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_gui_v50_safe_monitoring_20260428.zip .
.\jitsi_ndi_gui_v50_safe_monitoring_20260428pply_gui_v50.ps1

Run:
powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1

Rollback:
.\jitsi_ndi_gui_v50_safe_monitoring_20260428estore_latest_gui_backup_v50.ps1
