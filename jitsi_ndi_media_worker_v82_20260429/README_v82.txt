jitsi_ndi_media_worker_v82_20260429

Purpose:
- Keep libdatachannel/WebRTC RTP callbacks fast.
- Move RTP decoding + NDI sending into a dedicated media worker queue.
- This is intended to reduce RTP callback blocking when one NDI/video source lags.

Touches:
- src/NativeWebRTCAnswerer.cpp only.

Does not touch:
- Jitsi receiver video constraints / 1080p
- Native reconnect logic
- JitsiSignaling
- PerParticipantNdiRouter
- AV1 assembler
- NDI sender
- GUI
- audio decoder

Expected log:
NativeWebRTCAnswerer: v82 media worker queue enabled; WebRTC RTP callback will not decode/send NDI synchronously

If overloaded, you may see:
NativeWebRTCAnswerer: v82 media queue full; dropping incoming video RTP before decode...
