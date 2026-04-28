v59 nickname display patch

Purpose:
- Keep the current stable detached GUI behavior.
- Let the GUI pass --nick again, but only as a display name.
- Keep the technical Jitsi MUC resource fixed to the previously working "probe123".
- Read Windows command-line arguments through wmain and UTF-8 conversion, so Cyrillic nicknames are not mojibake.

Changed files:
- JitsiNdiGui.ps1
- src/JitsiSignaling.cpp
- src/main.cpp

What it does not change:
- Quality constraints
- NDI sender
- Rejoin/renegotiation v49 logic
- GUI stdout capture behavior

Use:
cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_nick_display_v59_20260428.zip .
.\jitsi_ndi_nick_display_v59_20260428\apply_nick_display_v59.ps1
.\rebuild_with_dav1d_v21.ps1

Run:
powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1

Rollback:
.\jitsi_ndi_nick_display_v59_20260428\restore_latest_nick_display_v59_backup.ps1
.\rebuild_with_dav1d_v21.ps1
