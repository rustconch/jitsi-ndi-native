jitsi-ndi-native v17 patch

Purpose:
- Audio is already fixed.
- Video currently fails because Jitsi sends AV1 RTP payload type 41.
- Your FFmpeg build has no libdav1d and its native AV1 decoder fails with hardware pixel format errors.
- This patch forces VP8-only negotiation with Jitsi so the bridge should send payload type 100 instead of 41.

Apply:
cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_native_force_vp8_negotiation_v17.zip .
powershell -ExecutionPolicy Bypass -File .\patch_force_vp8_negotiation_v17.ps1
cmake --build build --config Release
.\build\Release\jitsi-ndi-native.exe --room 6767676766767penxyi

Expected log after patch:
- JitsiSignaling: forced video codec negotiation to VP8 only
- session-accept video description contains payload-type id='100' name='VP8'
- video RTP endpoint=... pt=100
- no repeated [av1] hardware decode errors
