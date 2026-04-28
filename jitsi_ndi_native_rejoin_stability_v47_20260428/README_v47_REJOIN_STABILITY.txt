v47 rejoin stability patch

Goal:
- Keep the stable v42/v43 quality/audio behavior.
- Keep the v45/v46 fixes that ignore participant P2P session-terminate and preserve existing conference inputs.
- Improve the case where a new/rejoined participant is announced but does not appear in NDI.
- Avoid mojibake/garbage symbols in NDI source names.

Changes:
- JitsiSourceMap.cpp
  - NDI source names are now ASCII-safe.
  - Common Cyrillic display names are transliterated to Latin instead of passing raw UTF-8 bytes to NDI receivers that may show mojibake.

- PerParticipantNdiRouter.cpp
  - On source-add/source metadata update, video NDI pipelines are pre-created from Jingle metadata before first RTP arrives.
  - This makes the rejoined speaker visible in NDI/vMix earlier. It does not synthesize media frames; real video/audio still requires RTP from Jitsi/JVB.

- NativeWebRTCAnswerer.cpp
  - After source-add/presence SourceInfo updates, receiver video constraints and audio subscription are sent immediately and then re-sent three delayed times: 600 ms, 1800 ms, 4500 ms.
  - This is a bounded re-ask, not the old infinite refresh loop that caused DataChannel instability.

Expected logs:
- NativeWebRTCAnswerer: v47 rejoin stability mode
- ReceiverVideoConstraints/v42-stable-selected-only-1080p30/source-update-known-sources-retry1
- ReceiverAudioSubscription/Include-endpoint-audio/source-update-known-sources-retry1
- PerParticipantNdiRouter: created NDI participant source: JitsiNativeNDI - <name> camera endpoint=<new-endpoint>-v0

Important:
- If EndpointStats for the new participant still shows upload=0 for video/audio for many seconds, Jitsi/JVB is not receiving media from that browser yet. This patch can request and pre-create the NDI source, but it cannot decode media that the bridge is not sending.
