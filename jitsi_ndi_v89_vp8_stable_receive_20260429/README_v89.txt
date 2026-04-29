v89 VP8-stable receive patch

Why:
- v88 did soft-resume after AV1 RTP gaps, but the log still shows bridge datachannel closed immediately after AV1 recovery.
- Audio is stable, so the main issue is the AV1 multi-stream video receive path, not Opus/audio routing.

Changes:
- Disable AV1 advertising in presence/session-accept/SDP.
- Force video receive negotiation to VP8 only.
- Keep screen-share as separate NDI source.
- Keep screen-share at 1080p / 30 fps.
- Keep cameras at 720p / 30 fps.
- Keep total receive cap at 6.7 Mbps.

Expected logs:
- NativeWebRTCAnswerer: v89 VP8-only receive enabled...
- NativeWebRTCAnswerer: v89 stripped AV1/VP9/H264 from remote offer...
- Jingle session-accept should show VP8 video payload but not AV1 payload.

If video disappears completely, rollback using the .bak_v89_* files or re-apply v88.
