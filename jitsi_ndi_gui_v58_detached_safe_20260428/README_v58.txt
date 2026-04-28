Jitsi NDI GUI v58 minimal detached safe

This patch changes only JitsiNdiGui.ps1.
Native/WebRTC/Jitsi/NDI code is not changed. Rebuild is not needed.

Main change:
- GUI no longer reads native stdout/stderr live.
- Native is launched with only: --room <room>
- No --nick, no --quality, no NDI scanning, no source tables.

This prevents PowerShell/WinForms GUI from crashing because of heavy native logs.
Native streams can keep running even if the GUI is closed.
Use Stop button to stop native.
