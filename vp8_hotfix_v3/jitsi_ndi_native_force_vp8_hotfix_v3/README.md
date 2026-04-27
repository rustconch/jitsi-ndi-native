# jitsi-ndi-native VP8 hotfix v3

This fixes the v2 compile error in `JitsiSignaling.cpp` where the patch tried to assign into a `const std::string`.

Run from project root:

```powershell
cd D:\MEDIA\Desktop\jitsi-ndi-native
python .\vp8_hotfix_v3\jitsi_ndi_native_force_vp8_hotfix_v3\fix_force_vp8_v3.py
cmake --build build --config Release
```
