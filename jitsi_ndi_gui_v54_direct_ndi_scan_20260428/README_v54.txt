Jitsi NDI GUI v54 direct NDI scan

This patch changes only JitsiNdiGui.ps1.

Main change:
- The "NDI имена" button no longer depends on the live table or internal registry.
- When clicked, it scans the current session log file directly and parses:
  - Real NDI sender started:
  - created NDI participant source:
  - NDI video frame sent:
  - NDI sender stopped:
- The dialog shows diagnostics: scanned lines, raw NDI-like lines, parsed sources.
- Active NDI names are copied to clipboard.

Native/WebRTC/Jitsi/NDI code is not changed.
Launch args remain safe: --room only.
