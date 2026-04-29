v80 AV1 loss gate patch

Purpose:
- Do not feed AV1 delta temporal units into dav1d after RTP sequence gaps.
- After any RTP gap/corruption, the assembler waits for a real in-band sequence header/keyframe before resuming AV1 decode.
- Does not change Jitsi signaling, reconnect logic, NDI routing, GUI, audio, or quality constraints.

Apply:
  .\jitsi_ndi_av1_loss_gate_v80_20260429\apply_av1_loss_gate_v80.ps1
  .\rebuild_with_dav1d_v21.ps1

Restore:
  .\jitsi_ndi_av1_loss_gate_v80_20260429\restore_latest_av1_loss_gate_v80_backup.ps1
  .\rebuild_with_dav1d_v21.ps1
