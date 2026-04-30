jitsi-ndi-native v98 no-cap decoder stability

Base: v97 tested source-local/observer-safe branch.

What changed from v97:
- Does NOT reduce quality or FPS: camera and screen-share requests stay 1080p / 30fps.
- Removes the artificial 6 Mbps ReceiverVideoConstraints bandwidth assumption and restores a high receiver estimate (250 Mbps) so JVB does not treat 2 cameras + 2 screen shares as a narrow receiver.
- Keeps observer-safe mode: selectedSources/onStageSources remain empty and legacy LastNChangedEvent is still not sent, so normal conference participants should not lose each other's video because of our receiver.
- Caps AV1 decoder worker fan-out per source: libdav1d threads are fixed to 2 instead of auto. This is CPU/decoder scheduling only; it does not change stream quality, resolution, or FPS.
- Adds warm-stall source-local hard re-prime: if a source decoded before, then keeps producing AV1 temporal units but no decoded frames for a while, only that source's decoder/assembler is re-primed.
- Hard re-prime now preserves the cached AV1 sequence header, instead of throwing it away and waiting forever for a fresh keyframe.
- Keeps global reconnect disabled.

New log markers:
- NativeWebRTCAnswerer: v98 AV1 receive enabled
- ReceiverVideoConstraints/v98-observer-safe-no-cap250mbps-1080p30-local-smooth
- FfmpegMediaDecoder: decoder opened name=libdav1d
- PerParticipantNdiRouter: v98 source-local AV1 warm hard re-prime
- PerParticipantNdiRouter: v98 cold AV1 decoder nudge
- PerParticipantNdiRouter: v98 cold AV1 hard re-prime
- v98Worker=1

How to apply:
1. Extract this folder into the repo root.
2. Run apply_v98_no_cap_decoder_stability.ps1.
3. Rebuild with rebuild_with_dav1d_v21.ps1.
