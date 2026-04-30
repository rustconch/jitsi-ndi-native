jitsi-ndi-native v97 same-device cold AV1 recovery

Base: v96 / stable v94 rollback.

What changed from v96:
- Keeps observer-safe ReceiverVideoConstraints: no selectedSources/onStageSources and no legacy LastNChangedEvent.
- Keeps camera and screen-share request at 1080p / 30fps.
- Keeps global reconnect disabled for source-local stability testing.
- Adds source-local cold AV1 recovery for streams that produce AV1 temporal units but never produce the first decoded dav1d frame.

Why:
- Logs show the participant from the same PC as the receiver behaves differently:
  e75b990c-v0/v1 producedFrames=1 decodedFrames=0.
- Remote participant f0a014ae decodes normally: decodedFrames=1.
- v96 recovery only handled warm stalls after a source had decoded at least once.

New log markers:
- v97 cold AV1 decoder nudge
- v97 cold AV1 hard re-prime
- v97Worker=1

How to apply:
1. Extract this folder into the repo root.
2. Run apply_v97_same_device_cold_av1_recovery.ps1.
3. Rebuild with rebuild_with_dav1d_v21.ps1.
