# jitsi-ndi-native force VP8 real v4

Run from the repository root:

```powershell
cd D:\MEDIA\Desktop\jitsi-ndi-native

Remove-Item .\vp8_real_v4 -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive .\jitsi_ndi_native_force_vp8_real_v4.zip -DestinationPath .\vp8_real_v4 -Force

python .\vp8_real_v4\jitsi_ndi_native_force_vp8_real_v4\fix_force_vp8_real_v4.py

cmake --build build --config Release
```

Expected runtime signs:

- `session-accept XML` video section should no longer include `AV1`, `H264`, or `VP9` payload-types.
- Console should no longer spam `[libdav1d] Error parsing frame header / OBU data`.
- Video RTP should be payload type VP8/100.
