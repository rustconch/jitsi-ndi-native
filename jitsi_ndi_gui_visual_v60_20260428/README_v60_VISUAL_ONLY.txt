Jitsi NDI GUI v60 visual redesign only

What changed:
- Only JitsiNdiGui.ps1 is replaced.
- No native/WebRTC/Jitsi/NDI code is changed.
- No rebuild is required.
- Existing functions remain: meeting link/room, display nick, send nick checkbox, Connect, Stop, Exe, Copy command, Open log, Logs folder.
- No NDI scanning, no quality controls, no live native stdout reading.

Visual design:
- Layout follows the supplied REF image: large centered title, central setup card, dark bottom action bar.
- Palette uses supplied colors: #641FF1, #FF9900, #FFFA7D/#FFFED6, #EEE5FF, dark footer.
- The script tries to load Circe from ./gui/Circe-Regular.otf, ./gui/Circe-Bold.otf, ./gui/Circe-ExtraBold.otf, or ./fonts/*.otf.
- Font files are NOT included in this patch. Keep your supplied gui folder in the repository root if you want Circe loaded from files.

Apply:
cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_gui_visual_v60_20260428.zip .
.\jitsi_ndi_gui_visual_v60_20260428pply_gui_visual_v60.ps1

Run:
powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1

Rollback:
.\jitsi_ndi_gui_visual_v60_20260428estore_latest_gui_backup_v60.ps1
