# jitsi-ndi-native force VP8 hotfix

This hotfix forces the native receiver to negotiate VP8 instead of AV1.

Use when logs show:

```text
RAW RTP video packets=...
[libdav1d] Error parsing frame header
[libdav1d] Error parsing OBU data
PerParticipantNdiRouter: AV1 video packets ... producedFrames=0
```

Run from project root:

```powershell
cd D:\MEDIA\Desktop\jitsi-ndi-native
python .\vp8_hotfix\jitsi_ndi_native_force_vp8_hotfix\fix_force_vp8.py
cmake --build build --config Release
```

After launch, verify that `session-accept XML` no longer contains `name='AV1'` / `id='41'` in the video content. It should keep VP8 payload type `100`.
