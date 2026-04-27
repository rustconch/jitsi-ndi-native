jitsi-ndi-native repo patch v8
==============================

This patch is meant for the current rustconch/jitsi-ndi-native repository state.
It makes the media path internally consistent by selecting the VP8-stable path:

- SDP offer/answer video is filtered to VP8 only.
- Jingle session-accept advertises only VP8 for video.
- Presence codecList is normalized to vp8,opus.
- PerParticipantNdiRouter no longer skips VP8 packets and no longer feeds AV1 packets to dav1d in this mode.
- NDI audio clocking is disabled so the network/RTP callback thread is not blocked by NDI audio pacing.

Usage from repo root:

    cd D:\MEDIA\Desktop\jitsi-ndi-native
    Expand-Archive .\jitsi_ndi_native_repo_patch_v8.zip -DestinationPath .\repo_patch_v8 -Force
    python .\repo_patch_v8\jitsi_ndi_native_repo_patch_v8\apply_repo_patch_v8.py
    cmake --build build --config Release

Expected runtime signs:

    <jitsi_participant_codecList>vp8,opus</jitsi_participant_codecList>
    session-accept video should include VP8/100 only
    PerParticipantNdiRouter: video RTP ... pt=100
    No libdav1d spam, because AV1/dav1d branch is disabled in this patch

If JVB still sends pt=41 after this, the next problem is not decoder-side anymore: it means the Jingle session-accept still advertises AV1 somewhere or the bridge is not accepting the filtered codec list.
