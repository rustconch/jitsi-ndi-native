jitsi-ndi-native v19 dav1d rebuild fix

What this fixes:
- Audio and RTP are already alive.
- Video is AV1 payload type 41.
- Your current FFmpeg says: libdav1d decoder is not present in this FFmpeg build.
- The built-in FFmpeg AV1 decoder path fails on Windows with: Your platform doesn't support hardware accelerated AV1 decoding / Failed to get pixel format.

Use this from the repository root:

cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_native_dav1d_rebuild_v19.zip .
powershell -ExecutionPolicy Bypass -File .\rebuild_with_dav1d_v19.ps1
.\build\Release\jitsi-ndi-native.exe --room 6767676766767penxyi

Do not run only cmake --build after this bug. You must let vcpkg install ffmpeg[dav1d] and then clean-reconfigure the build.

Good log signs:
- FfmpegMediaDecoder: using AV1 decoder libdav1d
- no line: libdav1d decoder is not present
- no spam: Your platform doesn't support hardware accelerated AV1 decoding / Failed to get pixel format
