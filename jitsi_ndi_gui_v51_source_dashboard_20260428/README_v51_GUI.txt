Jitsi NDI Native GUI v51 - source dashboard

This patch changes only:
  JitsiNdiGui.ps1

It does NOT change native/WebRTC/Jitsi/NDI code and does NOT require rebuild.

Safety rules kept from working GUI:
  - launch args are still only: --room <room>
  - --nick is NOT sent
  - --quality / --width / --height / --ndi-name are NOT sent
  - no settings JSON is created or loaded
  - exe path is not saved permanently

New UI-only functionality:
  - source filter field above the table
  - hide inactive/stale rows checkbox
  - passive stale/waiting-media detection from logs
  - row colors for 1080p/720p/stale/stopped
  - Copy NDI source list button
  - Export source table to CSV button
  - stopped NDI sources are marked instead of silently staying active

Apply:
  cd D:\MEDIA\Desktop\jitsi-ndi-native
  Expand-Archive -Force .\jitsi_ndi_gui_v51_source_dashboard_20260428.zip .
  .\jitsi_ndi_gui_v51_source_dashboard_20260428\apply_gui_v51.ps1

Run:
  powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1

Rollback:
  .\jitsi_ndi_gui_v51_source_dashboard_20260428\restore_latest_gui_backup_v51.ps1
