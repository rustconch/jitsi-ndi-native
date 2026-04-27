jitsi-ndi-native dav1d rebuild v21

Fixes the v20 vcpkg error by adding --recurse to the FFmpeg+dav1d install command.

Run from repository root:

cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_native_dav1d_rebuild_v21_recurse.zip .
powershell -ExecutionPolicy Bypass -File .\rebuild_with_dav1d_v21.ps1
.\build\Release\jitsi-ndi-native.exe --room 6767676766767penxyi

Expected successful runtime log:
FfmpegMediaDecoder: using AV1 decoder libdav1d

If you still see native AV1 fallback, run:
powershell -ExecutionPolicy Bypass -File .\check_dav1d_runtime_v21.ps1
