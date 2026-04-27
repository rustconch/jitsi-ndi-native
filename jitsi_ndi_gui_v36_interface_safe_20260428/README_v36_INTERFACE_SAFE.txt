Jitsi NDI Native GUI v36 - interface-only safe patch

This patch replaces only JitsiNdiGui.ps1.
It does not change C++/WebRTC/Jitsi/NDI/CMake/build files.

Apply from repo root:
  cd D:\MEDIA\Desktop\jitsi-ndi-native
  Expand-Archive -Force .\jitsi_ndi_gui_v36_interface_safe_20260428.zip .
  .\jitsi_ndi_gui_v36_interface_safe_20260428\apply_gui_v36.ps1

Run:
  powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1

What changed:
- Settings are saved to JitsiNdiGui.settings.json.
- GUI still launches native only with --room and optionally --nick.
- GUI does not send --quality, --width, --height, or --ndi-name.
- Jitsi link/room preview is shown before start.
- Participant table avoids duplicate rows by mapping NDI source name to endpoint.
- Summary row shows source counts and resolution counts.
- Right-click the participant table to copy NDI name, endpoint, or resolution.
- Log panel has buttons for copying the exact launch command, clearing log view, and opening current log file.
- Current session logs still go to the logs folder.

Rollback:
  .\jitsi_ndi_gui_v36_interface_safe_20260428\restore_latest_gui_backup_v36.ps1
