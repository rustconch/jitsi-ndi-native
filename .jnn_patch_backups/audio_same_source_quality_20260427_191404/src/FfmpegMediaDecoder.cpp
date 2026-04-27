#include "FfmpegMediaDecoder.h"
#include "Logger.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
}

#include <algorithm>
#include <cstring>
#include <stdexcept>

namespace {
void throwIfNeg(int rc, const char* what) {
    if (rc >= 0) return;
    char err[AV_ERROR_MAX_STRING_SIZE]{};
    av_strerror(rc, err, sizeof(err));
    throw std::runtime_error(std::string(what) + ": " + err);
}

AVCodecContext* openDecoder(AVCodecID id) {
    const AVCodec* codec = avcodec_find_decoder(id);
    if (!codec) throw std::runtime_error("FFmpeg decoder not found");
    AVCodecContext* ctx = avcodec_alloc_context3(codec);
    if (!ctx) throw std::runtime_error("avcodec_alloc_context3 failed");
    const int rc = avcodec_open2(ctx, codec, nullptr);
    if (rc < 0) {
        avcodec_free_context(&ctx);
        throwIfNeg(rc, "avcodec_open2");
    }
    return ctx;
}
} // namespace

struct FfmpegVp8Decoder::Impl {
    AVCodecContext* dec = nullptr;
    AVFrame* frame = nullptr;
    SwsContext* sws = nullptr;
    int swsW = 0;
    int swsH = 0;
    AVPixelFormat swsFmt = AV_PIX_FMT_NONE;

    Impl() {
        dec = openDecoder(AV_CODEC_ID_VP8);
        frame = av_frame_alloc();
        if (!frame) throw std::runtime_error("av_frame_alloc failed");
    }

    ~Impl() {
        if (sws) sws_freeContext(sws);
        if (frame) av_frame_free(&frame);
        if (dec) avcodec_free_context(&dec);
    }
};

FfmpegVp8Decoder::FfmpegVp8Decoder() : impl_(std::make_unique<Impl>()) {}
FfmpegVp8Decoder::~FfmpegVp8Decoder() = default;

std::vector<DecodedVideoFrameBGRA> FfmpegVp8Decoder::decode(const EncodedVideoFrame& encoded) {
    std::vector<DecodedVideoFrameBGRA> out;
    if (!encoded.bytes.empty()) {
        AVPacket* pkt = av_packet_alloc();
        if (!pkt) return out;
        av_new_packet(pkt, static_cast<int>(encoded.bytes.size()));
        std::memcpy(pkt->data, encoded.bytes.data(), encoded.bytes.size());
        pkt->pts = encoded.timestamp;
        pkt->dts = encoded.timestamp;
        const int sendRc = avcodec_send_packet(impl_->dec, pkt);
        av_packet_free(&pkt);
        if (sendRc < 0) return out;
    }

    while (true) {
        const int rc = avcodec_receive_frame(impl_->dec, impl_->frame);
        if (rc == AVERROR(EAGAIN) || rc == AVERROR_EOF) break;
        if (rc < 0) break;

        const int w = impl_->frame->width;
        const int h = impl_->frame->height;
        if (w <= 0 || h <= 0) {
            av_frame_unref(impl_->frame);
            continue;
        }

        if (!impl_->sws || impl_->swsW != w || impl_->swsH != h || impl_->swsFmt != static_cast<AVPixelFormat>(impl_->frame->format)) {
            if (impl_->sws) sws_freeContext(impl_->sws);
            impl_->sws = sws_getContext(
                w, h, static_cast<AVPixelFormat>(impl_->frame->format),
                w, h, AV_PIX_FMT_BGRA,
                SWS_BILINEAR, nullptr, nullptr, nullptr
            );
            impl_->swsW = w;
            impl_->swsH = h;
            impl_->swsFmt = static_cast<AVPixelFormat>(impl_->frame->format);
        }

        DecodedVideoFrameBGRA f;
        f.width = w;
        f.height = h;
        f.stride = w * 4;
        f.pts90k = impl_->frame->best_effort_timestamp;
        f.bgra.resize(static_cast<std::size_t>(f.stride) * h);
        std::uint8_t* dstData[4] = { f.bgra.data(), nullptr, nullptr, nullptr };
        int dstLinesize[4] = { f.stride, 0, 0, 0 };
        sws_scale(impl_->sws, impl_->frame->data, impl_->frame->linesize, 0, h, dstData, dstLinesize);
        out.push_back(std::move(f));
        av_frame_unref(impl_->frame);
    }

    return out;
}

struct FfmpegAv1Decoder::Impl {
    AVCodecContext* dec = nullptr;
    AVFrame* frame = nullptr;
    SwsContext* sws = nullptr;
    int swsW = 0;
    int swsH = 0;
    AVPixelFormat swsFmt = AV_PIX_FMT_NONE;

    Impl() {
        dec = openDecoder(AV_CODEC_ID_AV1);
        frame = av_frame_alloc();
        if (!frame) throw std::runtime_error("av_frame_alloc failed");
    }

    ~Impl() {
        if (sws) sws_freeContext(sws);
        if (frame) av_frame_free(&frame);
        if (dec) avcodec_free_context(&dec);
    }
};

FfmpegAv1Decoder::FfmpegAv1Decoder() : impl_(std::make_unique<Impl>()) {}
FfmpegAv1Decoder::~FfmpegAv1Decoder() = default;

std::vector<DecodedVideoFrameBGRA> FfmpegAv1Decoder::decode(const EncodedVideoFrame& encoded) {
    std::vector<DecodedVideoFrameBGRA> out;
    if (!encoded.bytes.empty()) {
        AVPacket* pkt = av_packet_alloc();
        if (!pkt) return out;
        av_new_packet(pkt, static_cast<int>(encoded.bytes.size()));
        std::memcpy(pkt->data, encoded.bytes.data(), encoded.bytes.size());
        pkt->pts = encoded.timestamp;
        pkt->dts = encoded.timestamp;
        const int sendRc = avcodec_send_packet(impl_->dec, pkt);
        av_packet_free(&pkt);
        if (sendRc < 0) return out;
    }

    while (true) {
        const int rc = avcodec_receive_frame(impl_->dec, impl_->frame);
        if (rc == AVERROR(EAGAIN) || rc == AVERROR_EOF) break;
        if (rc < 0) break;

        const int w = impl_->frame->width;
        const int h = impl_->frame->height;
        if (w <= 0 || h <= 0) {
            av_frame_unref(impl_->frame);
            continue;
        }

        if (!impl_->sws || impl_->swsW != w || impl_->swsH != h || impl_->swsFmt != static_cast<AVPixelFormat>(impl_->frame->format)) {
            if (impl_->sws) sws_freeContext(impl_->sws);
            impl_->sws = sws_getContext(
                w, h, static_cast<AVPixelFormat>(impl_->frame->format),
                w, h, AV_PIX_FMT_BGRA,
                SWS_BILINEAR, nullptr, nullptr, nullptr
            );
            impl_->swsW = w;
            impl_->swsH = h;
            impl_->swsFmt = static_cast<AVPixelFormat>(impl_->frame->format);
        }

        DecodedVideoFrameBGRA f;
        f.width = w;
        f.height = h;
        f.stride = w * 4;
        f.pts90k = impl_->frame->best_effort_timestamp;
        f.bgra.resize(static_cast<std::size_t>(f.stride) * h);
        std::uint8_t* dstData[4] = { f.bgra.data(), nullptr, nullptr, nullptr };
        int dstLinesize[4] = { f.stride, 0, 0, 0 };
        sws_scale(impl_->sws, impl_->frame->data, impl_->frame->linesize, 0, h, dstData, dstLinesize);
        out.push_back(std::move(f));
        av_frame_unref(impl_->frame);
    }

    return out;
}

struct FfmpegOpusDecoder::Impl {
    AVCodecContext* dec = nullptr;
    AVFrame* frame = nullptr;
    SwrContext* swr = nullptr;
    AVChannelLayout outLayout{};

    Impl() {
        dec = openDecoder(AV_CODEC_ID_OPUS);
        dec->sample_rate = 48000;
        av_channel_layout_default(&dec->ch_layout, 2);
        frame = av_frame_alloc();
        if (!frame) throw std::runtime_error("av_frame_alloc failed");
        av_channel_layout_default(&outLayout, 2);
    }

    ~Impl() {
        if (swr) swr_free(&swr);
        if (frame) av_frame_free(&frame);
        if (dec) avcodec_free_context(&dec);
        av_channel_layout_uninit(&outLayout);
    }

    void ensureSwr(const AVFrame* in) {
        if (swr) return;
        int rc = swr_alloc_set_opts2(
            &swr,
            &outLayout,
            AV_SAMPLE_FMT_FLTP,
            48000, // PATCH_V10_AUDIO_PLANAR_CLOCK: planar float for NDI
            &in->ch_layout,
            static_cast<AVSampleFormat>(in->format),
            in->sample_rate > 0 ? in->sample_rate : 48000,
            0,
            nullptr
        );
        throwIfNeg(rc, "swr_alloc_set_opts2");
        throwIfNeg(swr_init(swr), "swr_init");
    }
};

FfmpegOpusDecoder::FfmpegOpusDecoder() : impl_(std::make_unique<Impl>()) {}
FfmpegOpusDecoder::~FfmpegOpusDecoder() = default;

std::vector<DecodedAudioFrameFloat32Planar> FfmpegOpusDecoder::decodeRtpPayload(
    const std::uint8_t* payload,
    std::size_t payloadSize,
    std::uint32_t rtpTimestamp
) {
    std::vector<DecodedAudioFrameFloat32Planar> out;
    if (!payload || payloadSize == 0) return out;

    AVPacket* pkt = av_packet_alloc();
    if (!pkt) return out;
    av_new_packet(pkt, static_cast<int>(payloadSize));
    std::memcpy(pkt->data, payload, payloadSize);
    pkt->pts = rtpTimestamp;
    const int sendRc = avcodec_send_packet(impl_->dec, pkt);
    av_packet_free(&pkt);
    if (sendRc < 0) return out;

    while (true) {
        const int rc = avcodec_receive_frame(impl_->dec, impl_->frame);
        if (rc == AVERROR(EAGAIN) || rc == AVERROR_EOF) break;
        if (rc < 0) break;

        try { impl_->ensureSwr(impl_->frame); } catch (const std::exception& e) {
            Logger::warn("Opus resampler init failed: ", e.what());
            av_frame_unref(impl_->frame);
            break;
        }

        const int samples = impl_->frame->nb_samples;
        DecodedAudioFrameFloat32Planar f;
        f.sampleRate = 48000;
        f.channels = 2;
        f.samples = samples;
        f.pts48k = impl_->frame->best_effort_timestamp >= 0 ? impl_->frame->best_effort_timestamp : rtpTimestamp;
        f.planar.resize(static_cast<std::size_t>(f.channels) * samples);

        std::uint8_t* outPlanes[2] = {
            reinterpret_cast<std::uint8_t*>(f.planar.data()),
            reinterpret_cast<std::uint8_t*>(f.planar.data() + samples)
        };
        const int converted = swr_convert(
            impl_->swr,
            outPlanes,
            samples,
            const_cast<const std::uint8_t**>(impl_->frame->extended_data),
            impl_->frame->nb_samples
        );
        if (converted > 0) {
            f.samples = converted;
            f.planar.resize(static_cast<std::size_t>(f.channels) * converted);
            static std::uint64_t decodedAudioFrames = 0;
                ++decodedAudioFrames;
                // PATCH_V10_AUDIO_PLANAR_CLOCK_DECODE_LOG
                if (decodedAudioFrames == 1 || (decodedAudioFrames % 500) == 0) {
                    Logger::info(
                        "FfmpegOpusDecoder: decoded audio frame samples=",
                        f.samples,
                        " channels=",
                        f.channels,
                        " format=fltp"
                    );
                }
                out.push_back(std::move(f));
        }
        av_frame_unref(impl_->frame);
    }

    return out;
}
