Apply:
  cd D:\MEDIA\Desktop\jitsi-ndi-native
  powershell -ExecutionPolicy Bypass -File .\patch_av1_software_decode_v15.ps1
  cmake --build build --config Release
  .\build\Release\jitsi-ndi-native.exe --room 6767676766767penxyi

Expected: no more FFmpeg lines like:
  Your platform doesn't support hardware accelerated AV1 decoding
  Failed to get pixel format
