// Add this to FfmpegMediaDecoder.cpp only if apply_av1_patch.py could not
// duplicate FfmpegVp8Decoder automatically.
//
// The safest manual method is to copy the whole FfmpegVp8Decoder::Impl block
// and its constructor/destructor/decode methods, then replace:
//
//     FfmpegVp8Decoder -> FfmpegAv1Decoder
//     AV_CODEC_ID_VP8  -> AV_CODEC_ID_AV1
//
// In many versions of this project the final result looks like this:

FfmpegAv1Decoder::FfmpegAv1Decoder()
    : impl_(std::make_unique<Impl>(AV_CODEC_ID_AV1)) {
}

FfmpegAv1Decoder::~FfmpegAv1Decoder() = default;

std::vector<DecodedVideoFrameBGRA> FfmpegAv1Decoder::decode(const EncodedVideoFrame& frame) {
    return impl_->decode(frame);
}
