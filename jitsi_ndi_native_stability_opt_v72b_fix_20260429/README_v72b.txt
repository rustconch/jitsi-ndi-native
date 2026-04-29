Jitsi NDI Native v72b stability optimization patch
==================================================

v72b is the same conservative optimization patch as v72, but fixes a PowerShell/.NET path issue.
The previous v72 script could run from the right PowerShell folder while .NET still resolved
relative file paths against the old process directory. v72b detects the repository root and uses
absolute paths everywhere.

Scope:
- Native-only stability/latency optimization.
- Does not touch GUI.
- Does not touch Jitsi signaling logic, room join, nick, source mapping, rejoin handling, or NDI source naming.
- Requires native rebuild after applying.

Apply:
  cd D:\MEDIA\Desktop\jitsi-ndi-native
  Expand-Archive -Force .\jitsi_ndi_native_stability_opt_v72b_fix_20260429.zip .
  .\jitsi_ndi_native_stability_opt_v72b_fix_20260429\apply_stability_opt_v72b.ps1
  .\rebuild_with_dav1d_v21.ps1

Restore:
  .\jitsi_ndi_native_stability_opt_v72b_fix_20260429\restore_latest_stability_opt_v72b_backup.ps1
  .\rebuild_with_dav1d_v21.ps1
