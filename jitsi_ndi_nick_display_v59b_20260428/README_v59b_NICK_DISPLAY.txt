Jitsi NDI Native v59b nick display fix

This patch fixes the PowerShell GUI encoding/parser issue from v59.
The GUI script is ASCII-only to avoid codepage problems.

Files changed:
- JitsiNdiGui.ps1
- src/JitsiSignaling.cpp
- src/main.cpp

GUI stays detached: it does not read native stdout/stderr and does not scan NDI logs.
Launch args are only --room and optional --nick.

Apply:
cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_nick_display_v59b_20260428.zip .
.\jitsi_ndi_nick_display_v59b_20260428\apply_nick_display_v59b.ps1

Rebuild native if v59 native changes were not already rebuilt:
.\rebuild_with_dav1d_v21.ps1

Run GUI:
powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1

Rollback:
.\jitsi_ndi_nick_display_v59b_20260428\restore_latest_nick_display_v59b_backup.ps1
.\rebuild_with_dav1d_v21.ps1
