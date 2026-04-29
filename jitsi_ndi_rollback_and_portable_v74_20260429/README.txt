Jitsi NDI v74 rollback and portable packager

Use after v72c made audio/video worse.

1) Roll back v72c:
   powershell -ExecutionPolicy Bypass -File .\jitsi_ndi_rollback_and_portable_v74_20260429\rollback_stability_v74.ps1

2) Rebuild native:
   .\rebuild_with_dav1d_v21.ps1

3) Build new portable EXE archive:
   powershell -ExecutionPolicy Bypass -File .\jitsi_ndi_rollback_and_portable_v74_20260429\make_portable_v74.ps1
