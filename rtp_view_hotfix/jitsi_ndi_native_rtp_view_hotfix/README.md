# RTP PacketView hotfix

Fixes this compile error after the AV stability patch:

```text
error C2665: Av1RtpFrameAssembler::pushRtp: cannot convert const RtpPacketView
```

## Apply

From project root:

```powershell
cd D:\MEDIA\Desktop\jitsi-ndi-native

Remove-Item .\rtp_view_hotfix -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive .\jitsi_ndi_native_rtp_view_hotfix.zip -DestinationPath .\rtp_view_hotfix -Force

python .\rtp_view_hotfix\jitsi_ndi_native_rtp_view_hotfix\fix_rtp_packet_view_overload.py

cmake --build build --config Release
```

If it still fails, send the first 30-50 compiler lines and the `struct RtpPacketView` definition.
