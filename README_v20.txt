jitsi-ndi-native v20 dav1d rebuild fix

The v19 archive had scripts inside a subfolder, while the command expected the script in the repository root. v20 fixes that and also calls helper scripts via the script's own folder.

Use from the repository root:

cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_native_dav1d_rebuild_v20_flat.zip .
powershell -ExecutionPolicy Bypass -File .\rebuild_with_dav1d_v20.ps1
.\build\Release\jitsi-ndi-native.exe --room 6767676766767penxyi

Good log signs:
- FfmpegMediaDecoder: using AV1 decoder libdav1d
- no line: libdav1d decoder is not present
- no spam: Your platform doesn't support hardware accelerated AV1 decoding / Failed to get pixel format
