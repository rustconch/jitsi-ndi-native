# revert_vp8_audio_v6

This patch undoes the experimental VP8-only Jingle/session-accept forcing, restores AV1 advertising in presence, enables NDI audio clocking, and adds video RTP payload-type logging plus a guard so VP8 RTP is not accidentally fed to the AV1/dav1d decoder.

Run from the project root:

```powershell
python .\revert_vp8_audio_v6\jitsi_ndi_native_revert_vp8_audio_v6\revert_vp8_audio_v6.py
cmake --build build --config Release
```
