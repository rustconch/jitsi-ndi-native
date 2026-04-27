# jitsi-ndi-native AV/audio stability fix

Apply after the previous AV1/audio subscription patches.

It tries to fix:

1. AV1 freezes caused by RTP packets arriving slightly out of order.
2. Video NDI sources named `ssrc-*` instead of Jitsi endpoint ids, causing audio and video to land in different NDI sources.
3. Distorted NDI audio when `NDIlib_audio_frame_v3_t` is fed interleaved float samples instead of planar float samples.

## Apply

```powershell
cd D:\MEDIA\Desktop\jitsi-ndi-native

Remove-Item .\av_stability_fix -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive .\jitsi_ndi_native_av_stability_fix.zip -DestinationPath .\av_stability_fix -Force

python .\av_stability_fix\jitsi_ndi_native_av_stability_fix\apply_av_stability_fix.py

cmake --build build --config Release
```

## Good runtime signs

NDI sources should ideally become endpoint-based:

```text
JitsiNativeNDI - d277e069
JitsiNativeNDI - d734b933
```

instead of:

```text
JitsiNativeNDI - ssrc-3211553111
```

If build fails, send the first 30-50 error lines.
If sources are still named `ssrc-*`, send:

- `src/PerParticipantNdiRouter.cpp`
- `src/NativeWebRTCAnswerer.cpp`
- `src/JingleSession.cpp`
