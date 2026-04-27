Rescue for jitsi-ndi-native after jitsi_ndi_native_nudnye_fixes_20260427.zip

What it does:
1. Backs up src/NDISender.cpp and src/PerParticipantNdiRouter.cpp.
2. Reverts only the experimental NDI runtime refcount changes from NDISender.cpp.
3. Keeps the safe AV1 syntax fix in PerParticipantNdiRouter.cpp.
4. Writes files as UTF-8 without BOM.

Run from PowerShell:

cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_native_rescue_after_nudnye_20260427.zip .
.\rescue_after_nudnye.ps1
cmake --build build --config Release
.\build\Release\jitsi-ndi-native.exe --room 6767676766767penxyi

If you need to restore the exact files before this script, use the backup folder printed by the script:

Copy-Item -Force .\_jnn_rescue_backup_YYYYMMDD_HHMMSS\NDISender.cpp .\src\NDISender.cpp
Copy-Item -Force .\_jnn_rescue_backup_YYYYMMDD_HHMMSS\PerParticipantNdiRouter.cpp .\src\PerParticipantNdiRouter.cpp
