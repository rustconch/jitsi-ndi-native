Patch v9 for jitsi-ndi-native

Run from project root:

  cd D:\MEDIA\Desktop\jitsi-ndi-native
  python .\repo_patch_v9\jitsi_ndi_native_repo_patch_v9\apply_repo_patch_v9.py
  cmake --build build --config Release

This patch restores AV1 routing because meet.jit.si/JVB is forwarding PT=41/AV1 despite VP8-only session-accept.
It also fixes malformed MUC presence left by the previous patch and sets NDI clock_audio=false.
