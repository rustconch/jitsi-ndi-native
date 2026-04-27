// Add this declaration to FfmpegMediaDecoder.h after FfmpegVp8Decoder.

class FfmpegAv1Decoder {
public:
    FfmpegAv1Decoder();
    ~FfmpegAv1Decoder();

    FfmpegAv1Decoder(const FfmpegAv1Decoder&) = delete;
    FfmpegAv1Decoder& operator=(const FfmpegAv1Decoder&) = delete;

    std::vector<DecodedVideoFrameBGRA> decode(const EncodedVideoFrame& frame);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
