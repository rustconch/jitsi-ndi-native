Jitsi NDI Portable EXE v73 packager

Run from repo root after building Release:

cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_portable_exe_v73_20260429.zip .
.\jitsi_ndi_portable_exe_v73_20260429\make_portable.ps1

The resulting portable zip appears in .\dist.
Inside the portable folder, use JitsiNDI.exe as the main launcher.
