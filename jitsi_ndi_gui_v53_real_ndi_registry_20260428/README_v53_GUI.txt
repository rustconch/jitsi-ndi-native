Jitsi NDI Native GUI v53 - real NDI registry

Changes only JitsiNdiGui.ps1. No native/WebRTC/NDI rebuild required.

What changed:
- The NDI names button now opens a real dialog with actual NDI source names.
- Names are gathered from real native log events:
  Real NDI sender started
  created NDI participant source
  NDI video frame sent
- Active NDI names are copied to clipboard automatically when the dialog opens.
- A registry counter is shown in the stats bar: NDI active/total.
- No --nick, --quality, --width, --height, or --ndi-name are passed.
- Launch remains --room only.

Apply:
  cd D:\MEDIA\Desktop\jitsi-ndi-native
  Expand-Archive -Force .\jitsi_ndi_gui_v53_real_ndi_registry_20260428.zip .
  .\jitsi_ndi_gui_v53_real_ndi_registry_20260428\apply_gui_v53.ps1

Run:
  powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1

Restore:
  .\jitsi_ndi_gui_v53_real_ndi_registry_20260428\restore_latest_gui_backup_v53.ps1
