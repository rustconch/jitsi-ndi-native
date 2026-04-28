Jitsi NDI GUI v61 visual-only patch

Changes only JitsiNdiGui.ps1.
No native/WebRTC/Jitsi/NDI changes. No rebuild required.

Changes:
- empty meeting link field by default
- default nick: STREAM
- orange #FF9900 is the main UI color
- purple is secondary accent
- resizable window with adaptive horizontal layout
- Jitsi NDI title uses the Circe ExtraBold file first when available

Apply:
  cd D:\MEDIA\Desktop\jitsi-ndi-native
  Expand-Archive -Force .\jitsi_ndi_gui_visual_v61_20260428.zip .
  .\jitsi_ndi_gui_visual_v61_20260428\apply_gui_visual_v61.ps1

Run:
  powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1

Rollback:
  .\jitsi_ndi_gui_visual_v61_20260428\restore_latest_gui_backup_v61.ps1

Fonts are not included in this patch. Keep your provided gui folder in the repo root if you want Circe loaded from files.
