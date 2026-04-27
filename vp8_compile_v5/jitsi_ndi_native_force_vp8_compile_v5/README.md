# jitsi-ndi-native force VP8 compile hotfix v5

This patch fixes the v4 compile error in `NativeWebRTCAnswerer.cpp` where a generated line used an undeclared `sdp` variable.

It removes the broken remote-SDP filter line and keeps the safer Jingle `session-accept` XML filter, which should make the sent `session-accept XML` advertise VP8 only.

Run from project root:

```powershell
python .\vp8_compile_v5\jitsi_ndi_native_force_vp8_compile_v5\fix_force_vp8_compile_v5.py
cmake --build build --config Release
```
