Jitsi NDI Native GUI v38 - visual monitoring only

This patch replaces only JitsiNdiGui.ps1.
It does not touch native/WebRTC/Jitsi/NDI/CMake/build files and does not require rebuild.

Safe behavior preserved from working v37:
- no settings JSON
- no saved exe path
- no quality flags
- no width/height flags
- no ndi-name flag
- launch remains: --room <room> and optionally --nick <nick>

New UI-only features:
- parsed room preview
- source counters: total/camera/screen
- resolution counters: 1080p/720p/<=540p/unknown
- last NDI frame timestamp
- quality request status from logs only
- buttons: copy launch command, current log, clear visible log
- right-click grid menu: copy name/endpoint/resolution/source key
- better resolution update without duplicate rows when native logs include source creation first

Apply:
  cd D:\MEDIA\Desktop\jitsi-ndi-native
  Expand-Archive -Force .\jitsi_ndi_gui_v38_visual_monitoring_20260428.zip .
  .\jitsi_ndi_gui_v38_visual_monitoring_20260428pply_gui_v38.ps1

Run:
  powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1

Rollback:
  .\jitsi_ndi_gui_v38_visual_monitoring_20260428estore_latest_gui_backup_v38.ps1
