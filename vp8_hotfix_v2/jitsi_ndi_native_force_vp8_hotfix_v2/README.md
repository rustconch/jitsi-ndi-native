# Force VP8 hotfix v2

This fixes a broken v1 VP8 hotfix insertion and re-applies VP8-only negotiation more safely.

Run from project root:

```powershell
cd D:\MEDIA\Desktop\jitsi-ndi-native
python .\vp8_hotfix_v2\jitsi_ndi_native_force_vp8_hotfix_v2\fix_force_vp8_v2.py
cmake --build build --config Release
```

After launch, check `session-accept XML`: video should not advertise `AV1/41`.
