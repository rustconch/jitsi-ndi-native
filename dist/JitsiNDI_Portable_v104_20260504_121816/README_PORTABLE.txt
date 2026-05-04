Jitsi NDI Native - Portable v104
=================================

LAUNCH:  JitsiNDI.exe

On first run you will be asked to allow Windows Firewall access.
Click YES (admin required, one-time only).
If you skipped it - run SETUP_FIREWALL.cmd as Administrator.

FILES:
  JitsiNDI.exe             - launcher (stays in tray while running)
  JitsiNdiGui.ps1          - GUI
  jitsi-ndi-native.exe     - native engine
  SETUP_FIREWALL.cmd       - firewall setup (run as Admin if needed)
  CHECK_PORTABLE.ps1       - diagnostics

NDI NOT VISIBLE ON OTHER PCs:
  1. Run SETUP_FIREWALL.cmd as Administrator
  2. All PCs must be on the same LAN (no VPN without multicast)
  3. Wait 10-15 seconds after connecting
  4. Refresh sources in NDI Studio Monitor

LOGS: logs\ folder next to JitsiNDI.exe
