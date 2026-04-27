Jitsi NDI Native GUI-only safe patch v32

This patch replaces only JitsiNdiGui.ps1.
It does not modify C++ sources, CMake, build folders, DLLs, WebRTC/Jitsi signaling, or NDI sender logic.

What changed:
- Removed the visible exe path row from the main UI.
- Added a small Exe... button only for manual exe override.
- Added a Logs button.
- Every session writes a separate log file to ./logs/.
- Jitsi link/room field remains.
- Jitsi nickname field is passed with --nick by default.
- There is a checkbox to disable --nick and return to the old --room-only launch mode.
- Participant/quality table stays log-only: it reads existing native logs and does not change native behavior.
- Quality dropdown is currently visual/monitoring-only and does NOT pass --quality, --width, or --height.

Apply:
cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_gui_only_safe_v32_20260428.zip .
.\jitsi_ndi_gui_only_safe_v32_20260428\apply_gui_only_safe_v32.ps1

Run:
powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1

Safe fallback:
If nickname passing causes any issue, uncheck "передавать ник в конференцию".
Then GUI launches native with only:
--room <room>
