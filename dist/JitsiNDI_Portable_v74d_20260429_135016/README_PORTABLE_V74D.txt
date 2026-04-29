Jitsi NDI Portable v74d safe

Main launch:
  JitsiNDI.exe

What changed from v70:
  - removed video watchdog;
  - removed automatic native restart;
  - GUI does not read native stdout/stderr directly;
  - native is started by a hidden PowerShell runner;
  - native stdout/stderr is redirected to logs\jitsi-ndi-native_YYYYMMDD_HHMMSS.log.
  - no START_*.cmd launcher is created; JitsiNDI.exe is the only main launcher.

If video freezes:
  1) do not rely on GUI watchdog; stop/start manually;
  2) send the newest logs\jitsi-ndi-native_*.log around the freeze time.
