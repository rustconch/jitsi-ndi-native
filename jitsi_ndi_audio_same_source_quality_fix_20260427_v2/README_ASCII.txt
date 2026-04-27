Audio same-source + quality fix patch.

How to apply:

cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_audio_same_source_quality_fix_20260427_v2.zip .
.\jitsi_ndi_audio_same_source_quality_fix_20260427_v2\apply_audio_fix_ascii.ps1
cmake --build build --config Release

This script intentionally contains ASCII only to avoid Windows PowerShell UTF-8 parsing issues.
