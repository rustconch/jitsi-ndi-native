// Insert this block inside the existing video branch, before the current
// "if (rtp.payloadType != 100)" / "dropping non-VP8 video RTP" block.

if (rtp.payloadType == 41) {
    const auto frames = p.av1.pushRtp(rtp);

    for (const auto& encoded : frames) {
        for (const auto& decoded : p.av1Decoder.decode(encoded)) {
            p.ndi->sendVideoFrame(decoded, 30, 1);
        }
    }

    if ((p.videoPackets % 300) == 0) {
        Logger::info(
            "PerParticipantNdiRouter: AV1 video packets endpoint=",
            p.endpointId,
            " count=",
            p.videoPackets,
            " producedFrames=",
            frames.size()
        );
    }

    return;
}
