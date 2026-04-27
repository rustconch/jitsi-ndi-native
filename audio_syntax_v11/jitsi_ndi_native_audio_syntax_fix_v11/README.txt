Patch v11: fixes malformed if-brace left by v10 in PerParticipantNdiRouter.cpp.

Run from project root:
  cd D:\MEDIA\Desktop\jitsi-ndi-native
  Expand-Archive .\jitsi_ndi_native_audio_syntax_fix_v11.zip -DestinationPath .\audio_syntax_v11 -Force
  python .\audio_syntax_v11\jitsi_ndi_native_audio_syntax_fix_v11\apply_audio_syntax_fix_v11.py
  cmake --build build --config Release
