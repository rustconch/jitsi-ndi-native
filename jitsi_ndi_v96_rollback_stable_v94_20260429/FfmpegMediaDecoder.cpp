#include "FfmpegMediaDecoder.h"
#include "Logger.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libavutil/pixdesc.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
}

#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {


void filteredAvLogCallback(void* ptr, int level, const char* fmt, va_list vl) {
    char buffer[1024]{};
    va_list copy;
    va_copy(copy, vl);
    std::vsnprintf(buffer, sizeof(buffer), fmt ? fmt : "", copy);
    va_end(copy);

    const std::string message(buffer);
    if (message.find("Error parsing OBU data") != std::string::npos ||
        message.find("Error parsing frame header") != std::string::npos) {
        return;
    }

    av_log_default_callback(ptr, level, fmt, vl);
}

void installFfmpegLogFilterOnce() {
    static bool installed = false;
    if (!installed) {
        installed = true;
        av_log_set_callback(filteredAvLogCallback);
        Logger::info("FfmpegMediaDecoder: v96 installed FFmpeg log filter for transient libdav1d OBU parse noise");
    }
}

void throwIfNeg(int rc, const char* what) {
    if (rc >= 0) return;
    char err[AV_ERROR_MAX_STRING_SIZE]{};
    av_strerror(rc, err, sizeof(err));
    throw std::runtime_error(std::string(what) + ": " + err);
}

AVPixelFormat chooseSoftwarePixelFormat(AVCodecContext*, const AVPixelFormat* pixFmts) {
    if (!pixFmts) return AV_PIX_FMT_NONE;
    for (const AVPixelFormat* p = pixFmts; *p != AV_PIX_FMT_NONE; ++p) {
        const AVPixFmtDescriptor* desc = av_pix_fmt_desc_get(*p);
        if (!desc) continue;
        if ((desc->flags & AV_PIX_FMT_FLAG_HWACCEL) == 0) {
            return *p;
        }
    }
    return pixFmts[0];
}

const AVCodec* findDecoder(AVCodecID id) {
    if (id == AV_CODEC_ID_AV1) {
        if (const AVCodec* dav1d = avcodec_find_decoder_by_name("libdav1d")) {
            Logger::info("FfmpegMediaDecoder: using AV1 decoder libdav1d");
            return dav1d;
        }
        Logger::warn("FfmpegMediaDecoder: libdav1d decoder is not present in this FFmpeg build. Native AV1 fallback may fail on Windows.");
        if (const AVCodec* nativeAv1 = avcodec_find_decoder_by_name("av1")) {
            Logger::warn("FfmpegMediaDecoder: using native AV1 decoder fallback");
            return nativeAv1;
        }
    }

    const AVCodec* codec = avcodec_find_decoder(id);
    if (codec) {
        Logger::info("FfmpegMediaDecoder: using decoder ", codec->name ? codec->name : "<unknown>");
    }
    return codec;
}

AVCodecContext* openDecoder(AVCodecID id) {
    installFfmpegLogFilterOnce();
    const AVCodec* codec = findDecoder(id);
    if (!codec) throw std::runtime_error("FFmpeg decoder not found");

    AVCodecContext* ctx = avcodec_alloc_context3(codec);
    if (!ctx) throw std::runtime_error("avcodec_alloc_context3 failed");

    if (id == AV_CODEC_ID_AV1 || id == AV_CODEC_ID_VP8) {
        ctx->get_format = chooseSoftwarePixelFormat;
        ctx->thread_count = 0;
        ctx->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;
        ctx->hw_device_ctx = nullptr;
        ctx->hw_frames_ctx = nullptr;
    }

    AVDictionary* opts = nullptr;
    if (id == AV_CODEC_ID_AV1) {
        av_dict_set(&opts, "threads", "auto", 0);
    }

    const int rc = avcodec_open2(ctx, codec, &opts);
    av_dict_free(&opts);
    if (rc < 0) {
        avcodec_free_context(&ctx);
        throwIfNeg(rc, "avcodec_open2");
    }

    Logger::info(
        "FfmpegMediaDecoder: decoder opened name=",
        ctx->codec && ctx->codec->name ? ctx->codec->name : "<unknown>",
        " codec_id=", static_cast<int>(id)
    );
    return ctx;
}

std::vector<DecodedVideoFrameBGRA> decodeVideoPacket(
    AVCodecContext* dec,
    AVFrame* frame,
    SwsContext*& sws,
    int& swsW,
    int& swsH,
    AVPixelFormat& swsFmt,
    const EncodedVideoFrame& encoded
) {
    std::vector<DecodedVideoFrameBGRA> out;

    if (!encoded.bytes.empty()) {
        if (encoded.bytes.size() > static_cast<std::size_t>(std::numeric_limits<int>::max())) return out;

        AVPacket* pkt = av_packet_alloc();
        if (!pkt) return out;
        if (av_new_packet(pkt, static_cast<int>(encoded.bytes.size())) < 0) {
            av_packet_free(&pkt);
            return out;
        }

        std::memcpy(pkt->data, encoded.bytes.data(), encoded.bytes.size());
        pkt->pts = encoded.timestamp;
        pkt->dts = encoded.timestamp;

        const int sendRc = avcodec_send_packet(dec, pkt);
        av_packet_free(&pkt);
        if (sendRc < 0) return out;
    }

    while (true) {
        const int rc = avcodec_receive_frame(dec, frame);
        if (rc == AVERROR(EAGAIN) || rc == AVERROR_EOF) break;
        if (rc < 0) break;

        const int w = frame->width;
        const int h = frame->height;
        const auto fmt = static_cast<AVPixelFormat>(frame->format);

        if (w <= 0 || h <= 0 || fmt == AV_PIX_FMT_NONE) {
            av_frame_unref(frame);
            continue;
        }

        const AVPixFmtDescriptor* desc = av_pix_fmt_desc_get(fmt);
        if (desc && (desc->flags & AV_PIX_FMT_FLAG_HWACCEL)) {
            Logger::warn(
                "FfmpegMediaDecoder: dropped hardware pixel-format frame fmt=",
                av_get_pix_fmt_name(fmt) ? av_get_pix_fmt_name(fmt) : "<unknown>"
            );
            av_frame_unref(frame);
            continue;
        }

        if (!sws || swsW != w || swsH != h || swsFmt != fmt) {
            if (sws) sws_freeContext(sws);
            sws = sws_getContext(w, h, fmt, w, h, AV_PIX_FMT_BGRA, SWS_BILINEAR, nullptr, nullptr, nullptr);
            swsW = w;
            swsH = h;
            swsFmt = fmt;
        }

        if (!sws) {
            av_frame_unref(frame);
            continue;
        }

        DecodedVideoFrameBGRA f;
        f.width = w;
        f.height = h;
        f.stride = w * 4;
        f.pts90k = frame->best_effort_timestamp;
        f.bgra.resize(static_cast<std::size_t>(f.stride) * static_cast<std::size_t>(h));

        std::uint8_t* dstData[4] = { f.bgra.data(), nullptr, nullptr, nullptr };
        int dstLinesize[4] = { f.stride, 0, 0, 0 };
        sws_scale(sws, frame->data, frame->linesize, 0, h, dstData, dstLinesize);

        out.push_back(std::move(f));
        av_frame_unref(frame);
    }

    return out;
}

void resetVideoDecoderBuffers(
    AVCodecContext* dec,
    AVFrame* frame,
    SwsContext*& sws,
    int& swsW,
    int& swsH,
    AVPixelFormat& swsFmt,
    const char* label
) {
    if (dec) {
        avcodec_flush_buffers(dec);
    }
    if (frame) {
        av_frame_unref(frame);
    }
    if (sws) {
        sws_freeContext(sws);
        sws = nullptr;
    }
    swsW = 0;
    swsH = 0;
    swsFmt = AV_PIX_FMT_NONE;

    Logger::warn(
        "FfmpegMediaDecoder: v96 flushed ",
        label ? label : "video",
        " decoder buffers after source-local AV1 stall"
    );
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
    return decodeVideoPacket(impl_->dec, impl_->frame, impl_->sws, impl_->swsW, impl_->swsH, impl_->swsFmt, encoded);
}

void FfmpegVp8Decoder::reset() {
    resetVideoDecoderBuffers(impl_->dec, impl_->frame, impl_->sws, impl_->swsW, impl_->swsH, impl_->swsFmt, "VP8");
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
    return decodeVideoPacket(impl_->dec, impl_->frame, impl_->sws, impl_->swsW, impl_->swsH, impl_->swsFmt, encoded);
}

void FfmpegAv1Decoder::reset() {
    resetVideoDecoderBuffers(impl_->dec, impl_->frame, impl_->sws, impl_->swsW, impl_->swsH, impl_->swsFmt, "AV1");
}

struct FfmpegOpusDecoder::Impl {
    AVCodecContext* dec = nullptr;
    AVFrame* frame = nullptr;
    SwrContext* swr = nullptr;
    AVChannelLayout outLayout{};
    int swrInSampleRate = 0;
    int swrInChannels = 0;
    AVSampleFormat swrInFormat = AV_SAMPLE_FMT_NONE;

    Impl() {
        const AVCodec* codec = avcodec_find_decoder(AV_CODEC_ID_OPUS);
        if (!codec) throw std::runtime_error("FFmpeg Opus decoder not found");

        dec = avcodec_alloc_context3(codec);
        if (!dec) throw std::runtime_error("avcodec_alloc_context3 failed");

        dec->sample_rate = 48000;
        av_channel_layout_default(&dec->ch_layout, 2);

        const int rc = avcodec_open2(dec, codec, nullptr);
        if (rc < 0) {
            avcodec_free_context(&dec);
            throwIfNeg(rc, "avcodec_open2 opus");
        }

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
        AVChannelLayout inLayout{};
        if (in->ch_layout.nb_channels > 0) {
            throwIfNeg(av_channel_layout_copy(&inLayout, &in->ch_layout), "av_channel_layout_copy");
        } else {
            av_channel_layout_default(&inLayout, 2);
        }

        const int inSampleRate = in->sample_rate > 0 ? in->sample_rate : 48000;
        const int inChannels = inLayout.nb_channels > 0 ? inLayout.nb_channels : 2;
        const auto inFormat = static_cast<AVSampleFormat>(in->format);

        if (swr && swrInSampleRate == inSampleRate && swrInChannels == inChannels && swrInFormat == inFormat) {
            av_channel_layout_uninit(&inLayout);
            return;
        }

        if (swr) swr_free(&swr);

        int rc = swr_alloc_set_opts2(
            &swr,
            &outLayout,
            AV_SAMPLE_FMT_FLTP,
            48000,
            &inLayout,
            inFormat,
            inSampleRate,
            0,
            nullptr
        );
        av_channel_layout_uninit(&inLayout);
        throwIfNeg(rc, "swr_alloc_set_opts2");
        throwIfNeg(swr_init(swr), "swr_init");

        swrInSampleRate = inSampleRate;
        swrInChannels = inChannels;
        swrInFormat = inFormat;
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
    if (payloadSize > static_cast<std::size_t>(std::numeric_limits<int>::max())) return out;

    AVPacket* pkt = av_packet_alloc();
    if (!pkt) return out;
    if (av_new_packet(pkt, static_cast<int>(payloadSize)) < 0) {
        av_packet_free(&pkt);
        return out;
    }

    std::memcpy(pkt->data, payload, payloadSize);
    pkt->pts = rtpTimestamp;
    pkt->dts = rtpTimestamp;

    const int sendRc = avcodec_send_packet(impl_->dec, pkt);
    av_packet_free(&pkt);
    if (sendRc < 0) return out;

    while (true) {
        const int rc = avcodec_receive_frame(impl_->dec, impl_->frame);
        if (rc == AVERROR(EAGAIN) || rc == AVERROR_EOF) break;
        if (rc < 0) break;

        try {
            impl_->ensureSwr(impl_->frame);
        } catch (const std::exception& e) {
            Logger::warn("Opus resampler init failed: ", e.what());
            av_frame_unref(impl_->frame);
            break;
        }

        const int inSamples = impl_->frame->nb_samples;
        if (inSamples <= 0) {
            av_frame_unref(impl_->frame);
            continue;
        }

        int outCapacity = swr_get_out_samples(impl_->swr, inSamples);
        if (outCapacity <= 0) outCapacity = inSamples;

        DecodedAudioFrameFloat32Planar f;
        f.sampleRate = 48000;
        f.channels = 2;
        f.samples = outCapacity;
        f.pts48k = impl_->frame->best_effort_timestamp >= 0 ? impl_->frame->best_effort_timestamp : rtpTimestamp;
        f.planar.resize(static_cast<std::size_t>(f.channels) * static_cast<std::size_t>(outCapacity));

        std::uint8_t* outPlanes[2] = {
            reinterpret_cast<std::uint8_t*>(f.planar.data()),
            reinterpret_cast<std::uint8_t*>(f.planar.data() + outCapacity)
        };

        const int converted = swr_convert(
            impl_->swr,
            outPlanes,
            outCapacity,
            const_cast<const std::uint8_t**>(impl_->frame->extended_data),
            inSamples
        );

        if (converted > 0) {
            f.samples = converted;
            f.planar.resize(static_cast<std::size_t>(f.channels) * static_cast<std::size_t>(converted));

            for (auto& sample : f.planar) {
                if (!std::isfinite(sample)) sample = 0.0f;
                else if (sample > 1.0f) sample = 1.0f;
                else if (sample < -1.0f) sample = -1.0f;
            }

            static std::uint64_t decodedAudioFrames = 0;
            ++decodedAudioFrames;
            if (decodedAudioFrames == 1 || (decodedAudioFrames % 500) == 0) {
                Logger::info("FfmpegOpusDecoder: decoded audio frame samples=", f.samples, " channels=", f.channels, " format=fltp");
            }

            out.push_back(std::move(f));
        }

        av_frame_unref(impl_->frame);
    }

    return out;
}

