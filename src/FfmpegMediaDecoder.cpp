#include "FfmpegMediaDecoder.h"
#include "Logger.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libavutil/hwcontext.h>
#include <libavutil/pixdesc.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
}

#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

// ---------------------------------------------------------------------------
// FFmpeg log filter
// ---------------------------------------------------------------------------

void filteredAvLogCallback(void* ptr, int level, const char* fmt, va_list vl) {
    char buffer[1024]{};
    va_list copy;
    va_copy(copy, vl);
    std::vsnprintf(buffer, sizeof(buffer), fmt ? fmt : "", copy);
    va_end(copy);

    // v102: use std::strstr instead of constructing a std::string — avoids a
    // heap allocation on every FFmpeg log call (which can be frequent for
    // transient AV1 parse errors). std::strstr operates on the stack buffer.
    if (std::strstr(buffer, "Error parsing OBU data") ||
        std::strstr(buffer, "Error parsing frame header")) {
        return;
    }

    av_log_default_callback(ptr, level, fmt, vl);
}

void installFfmpegLogFilterOnce() {
    static bool installed = false;
    if (!installed) {
        installed = true;
        av_log_set_callback(filteredAvLogCallback);
        Logger::info("FfmpegMediaDecoder: installed FFmpeg log filter (v99)");
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

void throwIfNeg(int rc, const char* what) {
    if (rc >= 0) return;
    char err[AV_ERROR_MAX_STRING_SIZE]{};
    av_strerror(rc, err, sizeof(err));
    throw std::runtime_error(std::string(what) + ": " + err);
}

// get_format callback: software-only — skips all hardware-accelerated formats.
AVPixelFormat chooseSoftwarePixelFormat(AVCodecContext*, const AVPixelFormat* pixFmts) {
    if (!pixFmts) return AV_PIX_FMT_NONE;
    for (const AVPixelFormat* p = pixFmts; *p != AV_PIX_FMT_NONE; ++p) {
        const AVPixFmtDescriptor* desc = av_pix_fmt_desc_get(*p);
        if (!desc) continue;
        if ((desc->flags & AV_PIX_FMT_FLAG_HWACCEL) == 0) return *p;
    }
    return pixFmts[0];
}

// get_format callback: prefers the hw pixel format stored in ctx->opaque
// (as (void*)(uintptr_t)hwFmt), falling back to the first software format.
AVPixelFormat choosePixelFormatWithHwPref(AVCodecContext* ctx, const AVPixelFormat* fmts) {
    if (!fmts) return AV_PIX_FMT_NONE;
    const auto preferred = static_cast<AVPixelFormat>(
        static_cast<int>(reinterpret_cast<std::uintptr_t>(ctx->opaque)));
    if (preferred != AV_PIX_FMT_NONE) {
        for (const AVPixelFormat* p = fmts; *p != AV_PIX_FMT_NONE; ++p) {
            if (*p == preferred) return preferred;
        }
    }
    return chooseSoftwarePixelFormat(ctx, fmts);
}

// ---------------------------------------------------------------------------
// Hardware decode setup
// ---------------------------------------------------------------------------

// Try to attach D3D11VA (preferred) or DXVA2 hardware decoding to ctx,
// which must be allocated but NOT yet opened with avcodec_open2.
//
// On success: ctx->hw_device_ctx, ctx->get_format, and ctx->opaque are set;
//             hwPixFmtOut is set to AV_PIX_FMT_D3D11 or AV_PIX_FMT_DXVA2_VLD;
//             returns a new AVBufferRef* the caller owns (used to create hwSwFrame).
// On failure: returns nullptr, ctx is unchanged, hwPixFmtOut = AV_PIX_FMT_NONE.
AVBufferRef* tryAttachHwDecode(const AVCodec* codec, AVCodecContext* ctx,
                                AVPixelFormat& hwPixFmtOut) {
    hwPixFmtOut = AV_PIX_FMT_NONE;

    struct HwOpt { AVHWDeviceType type; AVPixelFormat fmt; };
    static const HwOpt kOptions[] = {
        { AV_HWDEVICE_TYPE_D3D11VA, AV_PIX_FMT_D3D11     },
        { AV_HWDEVICE_TYPE_DXVA2,   AV_PIX_FMT_DXVA2_VLD },
    };

    for (const auto& opt : kOptions) {
        // Verify the codec advertises support for this hw type via hw_device_ctx.
        bool supported = false;
        for (int i = 0; ; ++i) {
            const AVCodecHWConfig* cfg = avcodec_get_hw_config(codec, i);
            if (!cfg) break;
            if (cfg->device_type == opt.type &&
                (cfg->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)) {
                supported = true;
                break;
            }
        }
        if (!supported) continue;

        AVBufferRef* devCtx = nullptr;
        if (av_hwdevice_ctx_create(&devCtx, opt.type, nullptr, nullptr, 0) < 0) {
            Logger::warn("FfmpegMediaDecoder: hw device create failed type=",
                         av_hwdevice_get_type_name(opt.type)
                             ? av_hwdevice_get_type_name(opt.type) : "?");
            continue;
        }

        ctx->hw_device_ctx = av_buffer_ref(devCtx);
        ctx->get_format    = choosePixelFormatWithHwPref;
        // Store the preferred hw pixel format in opaque (no allocation needed).
        ctx->opaque        = reinterpret_cast<void*>(
                                 static_cast<std::uintptr_t>(
                                     static_cast<unsigned>(opt.fmt)));
        hwPixFmtOut = opt.fmt;

        Logger::info("FfmpegMediaDecoder: hw decode attached type=",
                     av_hwdevice_get_type_name(opt.type)
                         ? av_hwdevice_get_type_name(opt.type) : "?",
                     " pixFmt=",
                     av_get_pix_fmt_name(opt.fmt)
                         ? av_get_pix_fmt_name(opt.fmt) : "?");
        return devCtx;
    }

    Logger::info("FfmpegMediaDecoder: no hw decode available, using software");
    return nullptr;
}

// ---------------------------------------------------------------------------
// Codec lookup
// ---------------------------------------------------------------------------

const AVCodec* findDecoder(AVCodecID id) {
    if (id == AV_CODEC_ID_AV1) {
        // Prefer named D3D11VA AV1 hw decoders if present in this FFmpeg build.
        // Most vcpkg builds won't have them, so we fall back to libdav1d quickly.
        for (const char* name : { "av1_d3d11va2", "av1_d3d11va" }) {
            if (const AVCodec* c = avcodec_find_decoder_by_name(name)) {
                Logger::info("FfmpegMediaDecoder: found hw AV1 decoder: ", name);
                return c;
            }
        }
        if (const AVCodec* dav1d = avcodec_find_decoder_by_name("libdav1d")) {
            Logger::info("FfmpegMediaDecoder: using AV1 decoder libdav1d");
            return dav1d;
        }
        Logger::warn("FfmpegMediaDecoder: libdav1d not found, trying native av1");
        if (const AVCodec* nativeAv1 = avcodec_find_decoder_by_name("av1")) {
            return nativeAv1;
        }
    }

    const AVCodec* codec = avcodec_find_decoder(id);
    if (codec) {
        Logger::info("FfmpegMediaDecoder: using decoder ",
                     codec->name ? codec->name : "<unknown>");
    }
    return codec;
}

// ---------------------------------------------------------------------------
// Decoder open
// ---------------------------------------------------------------------------

// Opens the decoder for the given codec id.
// Attempts to attach hardware decoding (D3D11VA/DXVA2) before avcodec_open2.
// hwDeviceCtxOut and hwPixFmtOut carry the hw state on success; both are
// AV_PIX_FMT_NONE/nullptr if only software decoding is available.
AVCodecContext* openDecoder(AVCodecID id,
                             AVBufferRef*&   hwDeviceCtxOut,
                             AVPixelFormat&  hwPixFmtOut) {
    installFfmpegLogFilterOnce();

    hwDeviceCtxOut = nullptr;
    hwPixFmtOut    = AV_PIX_FMT_NONE;

    const AVCodec* codec = findDecoder(id);
    if (!codec) throw std::runtime_error("FFmpeg decoder not found");

    AVCodecContext* ctx = avcodec_alloc_context3(codec);
    if (!ctx) throw std::runtime_error("avcodec_alloc_context3 failed");

    if (id == AV_CODEC_ID_AV1 || id == AV_CODEC_ID_VP8) {
        // v103: try hardware decode first.
        // tryAttachHwDecode sets hw_device_ctx, get_format, and opaque on ctx.
        hwDeviceCtxOut = tryAttachHwDecode(codec, ctx, hwPixFmtOut);

        if (!hwDeviceCtxOut) {
            // Pure software path — use the software-only get_format selector.
            ctx->get_format    = chooseSoftwarePixelFormat;
            ctx->hw_device_ctx = nullptr;
            ctx->hw_frames_ctx = nullptr;
        }

        // v102: FF_THREAD_SLICE only — avoids inter-frame buffering latency.
        // thread_count=1: each pipeline worker thread drives its own decoder
        // directly; FFmpeg threads would add OS overhead for no benefit at
        // these resolutions when hw decode handles the heavy lifting.
        ctx->thread_type  = FF_THREAD_SLICE;
        ctx->thread_count = 1;
    }

    AVDictionary* opts = nullptr;
    if (id == AV_CODEC_ID_AV1 || id == AV_CODEC_ID_VP8) {
        av_dict_set(&opts, "threads", "1", 0);
    }

    const int rc = avcodec_open2(ctx, codec, &opts);
    av_dict_free(&opts);
    if (rc < 0) {
        if (hwDeviceCtxOut) {
            av_buffer_unref(&hwDeviceCtxOut);
            hwDeviceCtxOut = nullptr;
        }
        avcodec_free_context(&ctx);
        throwIfNeg(rc, "avcodec_open2");
    }

    Logger::info("FfmpegMediaDecoder: decoder opened name=",
                 ctx->codec && ctx->codec->name ? ctx->codec->name : "<unknown>",
                 " codec_id=", static_cast<int>(id),
                 " hw=", hwDeviceCtxOut ? "yes" : "no");
    return ctx;
}

// ---------------------------------------------------------------------------
// Video packet decode
// ---------------------------------------------------------------------------

// Decodes one encoded video packet and returns all decoded frames.
// hwSwFrame: a pre-allocated AVFrame used for GPU→CPU transfer (nullptr = sw-only).
// hwPixFmt:  the expected hw surface format (AV_PIX_FMT_NONE = sw-only).
//
// Frame lifecycle per iteration:
//   avcodec_receive_frame fills `frame` (may be a hw surface or sw buffer).
//   If hw: av_hwframe_transfer_data copies to hwSwFrame; then frame is unrefed.
//   src points at the sw frame to process (either `frame` or `hwSwFrame`).
//   At end of each iteration, av_frame_unref(frame) is called.
//   hwSwFrame holds its data until the next iteration where it is unrefed before reuse.
std::vector<DecodedVideoFrameBGRA> decodeVideoPacket(
    AVCodecContext* dec,
    AVFrame*        frame,
    SwsContext*&    sws,
    int&            swsW,
    int&            swsH,
    AVPixelFormat&  swsFmt,
    AVFrame*        hwSwFrame,
    AVPixelFormat   hwPixFmt,
    const EncodedVideoFrame& encoded
) {
    std::vector<DecodedVideoFrameBGRA> out;

    if (!encoded.bytes.empty()) {
        if (encoded.bytes.size() > static_cast<std::size_t>(std::numeric_limits<int>::max()))
            return out;

        // v102: stack-allocated AVPacket — avoids one heap alloc/free per frame.
        // Zero-init is equivalent to av_packet_init (works with all FFmpeg versions).
        AVPacket pkt = {};
        if (av_new_packet(&pkt, static_cast<int>(encoded.bytes.size())) < 0)
            return out;

        std::memcpy(pkt.data, encoded.bytes.data(), encoded.bytes.size());
        pkt.pts = encoded.timestamp;
        pkt.dts = encoded.timestamp;

        const int sendRc = avcodec_send_packet(dec, &pkt);
        av_packet_unref(&pkt);
        if (sendRc < 0) return out;
    }

    while (true) {
        const int rc = avcodec_receive_frame(dec, frame);
        if (rc == AVERROR(EAGAIN) || rc == AVERROR_EOF) break;
        if (rc < 0) break;

        // ---- HW → SW transfer (D3D11VA / DXVA2) --------------------------------
        // If the decoded frame lives on the GPU, copy it to a CPU buffer first.
        // `src` is the frame we will actually read pixel data from.
        AVFrame* src = frame;
        if (hwSwFrame) {
            const AVPixFmtDescriptor* d = av_pix_fmt_desc_get(
                static_cast<AVPixelFormat>(frame->format));
            if (d && (d->flags & AV_PIX_FMT_FLAG_HWACCEL)) {
                av_frame_unref(hwSwFrame); // release previous transfer buffers
                if (av_hwframe_transfer_data(hwSwFrame, frame, 0) == 0) {
                    hwSwFrame->best_effort_timestamp = frame->best_effort_timestamp;
                    src = hwSwFrame;
                } else {
                    Logger::warn("FfmpegMediaDecoder: hw→sw frame transfer failed, dropping");
                    av_frame_unref(frame);
                    continue;
                }
            }
        }

        const int w   = src->width;
        const int h   = src->height;
        const auto fmt = static_cast<AVPixelFormat>(src->format);

        if (w <= 0 || h <= 0 || fmt == AV_PIX_FMT_NONE) {
            av_frame_unref(frame);
            continue;
        }

        // If any residual hw frame slipped through (shouldn't happen), drop it.
        {
            const AVPixFmtDescriptor* desc = av_pix_fmt_desc_get(fmt);
            if (desc && (desc->flags & AV_PIX_FMT_FLAG_HWACCEL)) {
                Logger::warn("FfmpegMediaDecoder: dropped unexpected hw frame fmt=",
                             av_get_pix_fmt_name(fmt) ? av_get_pix_fmt_name(fmt) : "<unknown>");
                av_frame_unref(frame);
                continue;
            }
        }

        // ---- I420 / YUV420P fast path ------------------------------------------
        // v102: standard output of libdav1d (AV1) and FFmpeg VP8 software decoder.
        // Skip sws_scale entirely — NDI accepts I420 natively.
        if (fmt == AV_PIX_FMT_YUV420P || fmt == AV_PIX_FMT_YUVJ420P) {
            const int uvW = (w + 1) / 2;
            const int uvH = (h + 1) / 2;

            DecodedVideoFrameBGRA f;
            f.width       = w;
            f.height      = h;
            f.stride      = w; // Y-plane stride for I420
            f.pts90k      = src->best_effort_timestamp;
            f.pixelFormat = VideoPixelFormat::I420;
            f.data.resize(static_cast<std::size_t>(w)   * h +
                          static_cast<std::size_t>(uvW) * uvH * 2);

            std::uint8_t* dst = f.data.data();

            // Y plane
            if (src->linesize[0] == w) {
                std::memcpy(dst, src->data[0],
                    static_cast<std::size_t>(w) * h);
            } else {
                for (int row = 0; row < h; ++row)
                    std::memcpy(dst + static_cast<std::size_t>(row) * w,
                                src->data[0] + static_cast<std::size_t>(row) * src->linesize[0],
                                static_cast<std::size_t>(w));
            }
            dst += static_cast<std::size_t>(w) * h;

            // U plane
            if (src->linesize[1] == uvW) {
                std::memcpy(dst, src->data[1],
                    static_cast<std::size_t>(uvW) * uvH);
            } else {
                for (int row = 0; row < uvH; ++row)
                    std::memcpy(dst + static_cast<std::size_t>(row) * uvW,
                                src->data[1] + static_cast<std::size_t>(row) * src->linesize[1],
                                static_cast<std::size_t>(uvW));
            }
            dst += static_cast<std::size_t>(uvW) * uvH;

            // V plane
            if (src->linesize[2] == uvW) {
                std::memcpy(dst, src->data[2],
                    static_cast<std::size_t>(uvW) * uvH);
            } else {
                for (int row = 0; row < uvH; ++row)
                    std::memcpy(dst + static_cast<std::size_t>(row) * uvW,
                                src->data[2] + static_cast<std::size_t>(row) * src->linesize[2],
                                static_cast<std::size_t>(uvW));
            }

            out.push_back(std::move(f));
            av_frame_unref(frame);
            continue;
        }

        // ---- NV12 fast path (D3D11VA / DXVA2 output) --------------------------
        // v103: hardware decoders output NV12 = Y plane + interleaved UV (UVUVUV...).
        // Deinterleave UV into separate U and V planes to produce packed I420
        // without any colour-space conversion — NDI SDK accepts I420 natively.
        if (fmt == AV_PIX_FMT_NV12) {
            const int uvW = (w + 1) / 2;
            const int uvH = (h + 1) / 2;

            DecodedVideoFrameBGRA f;
            f.width       = w;
            f.height      = h;
            f.stride      = w;
            f.pts90k      = src->best_effort_timestamp;
            f.pixelFormat = VideoPixelFormat::I420;
            f.data.resize(static_cast<std::size_t>(w)   * h +
                          static_cast<std::size_t>(uvW) * uvH * 2);

            std::uint8_t* dst = f.data.data();

            // Copy Y plane (strip any decoder row padding)
            const int yStride = src->linesize[0];
            if (yStride == w) {
                std::memcpy(dst, src->data[0], static_cast<std::size_t>(w) * h);
            } else {
                for (int row = 0; row < h; ++row)
                    std::memcpy(dst + static_cast<std::size_t>(row) * w,
                                src->data[0] + static_cast<std::size_t>(row) * yStride,
                                static_cast<std::size_t>(w));
            }
            dst += static_cast<std::size_t>(w) * h;

            // Deinterleave UV: UVUVUV... → separate U then V planes.
            // The compiler with /Ot auto-vectorises this inner loop on x86.
            std::uint8_t* dstU = dst;
            std::uint8_t* dstV = dst + static_cast<std::size_t>(uvW) * uvH;
            const int uvStride = src->linesize[1];
            for (int row = 0; row < uvH; ++row) {
                const std::uint8_t* uvRow =
                    src->data[1] + static_cast<std::size_t>(row) * uvStride;
                std::uint8_t* uRow = dstU + static_cast<std::size_t>(row) * uvW;
                std::uint8_t* vRow = dstV + static_cast<std::size_t>(row) * uvW;
                for (int col = 0; col < uvW; ++col) {
                    uRow[col] = uvRow[2 * col];
                    vRow[col] = uvRow[2 * col + 1];
                }
            }

            out.push_back(std::move(f));
            av_frame_unref(frame);
            continue;
        }

        // ---- Fallback: sws_scale → BGRA ----------------------------------------
        // Rare path for exotic pixel formats (e.g. YUV444P, 10-bit AV1 profiles).
        if (!sws || swsW != w || swsH != h || swsFmt != fmt) {
            if (sws) sws_freeContext(sws);
            sws    = sws_getContext(w, h, fmt, w, h, AV_PIX_FMT_BGRA,
                                    SWS_FAST_BILINEAR, nullptr, nullptr, nullptr);
            swsW   = w;
            swsH   = h;
            swsFmt = fmt;
        }

        if (!sws) { av_frame_unref(frame); continue; }

        DecodedVideoFrameBGRA f;
        f.width       = w;
        f.height      = h;
        f.stride      = w * 4;
        f.pts90k      = src->best_effort_timestamp;
        f.pixelFormat = VideoPixelFormat::BGRA;
        f.data.resize(static_cast<std::size_t>(f.stride) * h);

        std::uint8_t* dstData[4] = { f.data.data(), nullptr, nullptr, nullptr };
        int           dstLines[4] = { f.stride, 0, 0, 0 };
        sws_scale(sws, src->data, src->linesize, 0, h, dstData, dstLines);

        out.push_back(std::move(f));
        av_frame_unref(frame);
    }

    return out;
}

// ---------------------------------------------------------------------------
// Decoder flush helper
// ---------------------------------------------------------------------------

void resetVideoDecoderBuffers(
    AVCodecContext* dec,
    AVFrame*        frame,
    SwsContext*&    sws,
    int&            swsW,
    int&            swsH,
    AVPixelFormat&  swsFmt,
    AVFrame*        hwSwFrame,
    const char*     label
) {
    if (dec)      avcodec_flush_buffers(dec);
    if (frame)    av_frame_unref(frame);
    if (hwSwFrame) av_frame_unref(hwSwFrame); // release hw transfer buffers
    if (sws)      { sws_freeContext(sws); sws = nullptr; }
    swsW   = 0;
    swsH   = 0;
    swsFmt = AV_PIX_FMT_NONE;

    Logger::warn("FfmpegMediaDecoder: flushed ",
                 label ? label : "video",
                 " decoder buffers after stall");
}

} // namespace

// ===========================================================================
// VP8 decoder
// ===========================================================================

struct FfmpegVp8Decoder::Impl {
    AVCodecContext* dec       = nullptr;
    AVFrame*        frame     = nullptr;
    SwsContext*     sws       = nullptr;
    int             swsW      = 0;
    int             swsH      = 0;
    AVPixelFormat   swsFmt    = AV_PIX_FMT_NONE;

    // v103: hardware decode state
    AVBufferRef*    hwDeviceCtx = nullptr; // D3D11VA / DXVA2 device (owned)
    AVPixelFormat   hwPixFmt    = AV_PIX_FMT_NONE;
    AVFrame*        hwSwFrame   = nullptr; // reusable CPU frame for GPU→CPU transfer

    Impl() {
        dec = openDecoder(AV_CODEC_ID_VP8, hwDeviceCtx, hwPixFmt);
        if (hwDeviceCtx) {
            hwSwFrame = av_frame_alloc();
            if (!hwSwFrame) {
                // Non-fatal: disable hw to avoid NULL dereference later.
                Logger::warn("FfmpegVp8Decoder: av_frame_alloc for hwSwFrame failed, disabling hw");
                av_buffer_unref(&hwDeviceCtx);
                hwDeviceCtx = nullptr;
                hwPixFmt    = AV_PIX_FMT_NONE;
            }
        }
        frame = av_frame_alloc();
        if (!frame) throw std::runtime_error("av_frame_alloc failed");
    }

    ~Impl() {
        if (sws)         sws_freeContext(sws);
        if (hwSwFrame)   av_frame_free(&hwSwFrame);
        if (frame)       av_frame_free(&frame);
        if (dec)         avcodec_free_context(&dec);
        if (hwDeviceCtx) av_buffer_unref(&hwDeviceCtx);
    }
};

FfmpegVp8Decoder::FfmpegVp8Decoder() : impl_(std::make_unique<Impl>()) {}
FfmpegVp8Decoder::~FfmpegVp8Decoder() = default;

std::vector<DecodedVideoFrameBGRA> FfmpegVp8Decoder::decode(const EncodedVideoFrame& encoded) {
    return decodeVideoPacket(
        impl_->dec, impl_->frame,
        impl_->sws, impl_->swsW, impl_->swsH, impl_->swsFmt,
        impl_->hwSwFrame, impl_->hwPixFmt,
        encoded);
}

void FfmpegVp8Decoder::reset() {
    resetVideoDecoderBuffers(
        impl_->dec, impl_->frame,
        impl_->sws, impl_->swsW, impl_->swsH, impl_->swsFmt,
        impl_->hwSwFrame, "VP8");
}

// ===========================================================================
// AV1 decoder
// ===========================================================================

struct FfmpegAv1Decoder::Impl {
    AVCodecContext* dec       = nullptr;
    AVFrame*        frame     = nullptr;
    SwsContext*     sws       = nullptr;
    int             swsW      = 0;
    int             swsH      = 0;
    AVPixelFormat   swsFmt    = AV_PIX_FMT_NONE;

    // v103: hardware decode state
    AVBufferRef*    hwDeviceCtx = nullptr;
    AVPixelFormat   hwPixFmt    = AV_PIX_FMT_NONE;
    AVFrame*        hwSwFrame   = nullptr;

    Impl() {
        dec = openDecoder(AV_CODEC_ID_AV1, hwDeviceCtx, hwPixFmt);
        if (hwDeviceCtx) {
            hwSwFrame = av_frame_alloc();
            if (!hwSwFrame) {
                Logger::warn("FfmpegAv1Decoder: av_frame_alloc for hwSwFrame failed, disabling hw");
                av_buffer_unref(&hwDeviceCtx);
                hwDeviceCtx = nullptr;
                hwPixFmt    = AV_PIX_FMT_NONE;
            }
        }
        frame = av_frame_alloc();
        if (!frame) throw std::runtime_error("av_frame_alloc failed");
    }

    ~Impl() {
        if (sws)         sws_freeContext(sws);
        if (hwSwFrame)   av_frame_free(&hwSwFrame);
        if (frame)       av_frame_free(&frame);
        if (dec)         avcodec_free_context(&dec);
        if (hwDeviceCtx) av_buffer_unref(&hwDeviceCtx);
    }
};

FfmpegAv1Decoder::FfmpegAv1Decoder() : impl_(std::make_unique<Impl>()) {}
FfmpegAv1Decoder::~FfmpegAv1Decoder() = default;

std::vector<DecodedVideoFrameBGRA> FfmpegAv1Decoder::decode(const EncodedVideoFrame& encoded) {
    return decodeVideoPacket(
        impl_->dec, impl_->frame,
        impl_->sws, impl_->swsW, impl_->swsH, impl_->swsFmt,
        impl_->hwSwFrame, impl_->hwPixFmt,
        encoded);
}

void FfmpegAv1Decoder::reset() {
    resetVideoDecoderBuffers(
        impl_->dec, impl_->frame,
        impl_->sws, impl_->swsW, impl_->swsH, impl_->swsFmt,
        impl_->hwSwFrame, "AV1");
}

// ===========================================================================
// Opus decoder (unchanged)
// ===========================================================================

struct FfmpegOpusDecoder::Impl {
    AVCodecContext* dec = nullptr;
    AVFrame*        frame = nullptr;
    SwrContext*     swr = nullptr;
    AVChannelLayout outLayout{};
    int             swrInSampleRate = 0;
    int             swrInChannels   = 0;
    AVSampleFormat  swrInFormat     = AV_SAMPLE_FMT_NONE;

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
        if (swr)   swr_free(&swr);
        if (frame) av_frame_free(&frame);
        if (dec)   avcodec_free_context(&dec);
        av_channel_layout_uninit(&outLayout);
    }

    void ensureSwr(const AVFrame* in) {
        AVChannelLayout inLayout{};
        if (in->ch_layout.nb_channels > 0) {
            throwIfNeg(av_channel_layout_copy(&inLayout, &in->ch_layout),
                       "av_channel_layout_copy");
        } else {
            av_channel_layout_default(&inLayout, 2);
        }

        const int inSampleRate = in->sample_rate > 0 ? in->sample_rate : 48000;
        const int inChannels   = inLayout.nb_channels > 0 ? inLayout.nb_channels : 2;
        const auto inFormat    = static_cast<AVSampleFormat>(in->format);

        if (swr &&
            swrInSampleRate == inSampleRate &&
            swrInChannels   == inChannels   &&
            swrInFormat     == inFormat) {
            av_channel_layout_uninit(&inLayout);
            return;
        }

        if (swr) swr_free(&swr);

        int rc = swr_alloc_set_opts2(
            &swr,
            &outLayout, AV_SAMPLE_FMT_FLTP, 48000,
            &inLayout,  inFormat,             inSampleRate,
            0, nullptr);
        av_channel_layout_uninit(&inLayout);
        throwIfNeg(rc, "swr_alloc_set_opts2");
        throwIfNeg(swr_init(swr), "swr_init");

        swrInSampleRate = inSampleRate;
        swrInChannels   = inChannels;
        swrInFormat     = inFormat;
    }
};

FfmpegOpusDecoder::FfmpegOpusDecoder() : impl_(std::make_unique<Impl>()) {}
FfmpegOpusDecoder::~FfmpegOpusDecoder() = default;

std::vector<DecodedAudioFrameFloat32Planar> FfmpegOpusDecoder::decodeRtpPayload(
    const std::uint8_t* payload,
    std::size_t         payloadSize,
    std::uint32_t       rtpTimestamp
) {
    std::vector<DecodedAudioFrameFloat32Planar> out;
    if (!payload || payloadSize == 0) return out;
    if (payloadSize > static_cast<std::size_t>(std::numeric_limits<int>::max())) return out;

    // v102: stack AVPacket — eliminates one malloc/free per Opus RTP packet.
    AVPacket pkt = {};
    if (av_new_packet(&pkt, static_cast<int>(payloadSize)) < 0) return out;

    std::memcpy(pkt.data, payload, payloadSize);
    pkt.pts = rtpTimestamp;
    pkt.dts = rtpTimestamp;

    const int sendRc = avcodec_send_packet(impl_->dec, &pkt);
    av_packet_unref(&pkt);
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
        f.channels   = 2;
        f.samples    = outCapacity;
        f.pts48k     = impl_->frame->best_effort_timestamp >= 0
                           ? impl_->frame->best_effort_timestamp
                           : rtpTimestamp;
        f.planar.resize(static_cast<std::size_t>(f.channels) * outCapacity);

        std::uint8_t* outPlanes[2] = {
            reinterpret_cast<std::uint8_t*>(f.planar.data()),
            reinterpret_cast<std::uint8_t*>(f.planar.data() + outCapacity)
        };

        const int converted = swr_convert(
            impl_->swr,
            outPlanes, outCapacity,
            const_cast<const std::uint8_t**>(impl_->frame->extended_data),
            inSamples);

        if (converted > 0) {
            f.samples = converted;
            f.planar.resize(static_cast<std::size_t>(f.channels) * converted);

            // v102: plain min/max — branchless MINSS/MAXSS on x86, auto-vectorised.
            for (auto& sample : f.planar) {
                if (sample >  1.0f) sample =  1.0f;
                else if (sample < -1.0f) sample = -1.0f;
            }

            static std::uint64_t decodedAudioFrames = 0;
            ++decodedAudioFrames;
            if (decodedAudioFrames == 1 || (decodedAudioFrames % 500) == 0) {
                Logger::info("FfmpegOpusDecoder: decoded audio frame samples=",
                             f.samples, " channels=", f.channels, " format=fltp");
            }

            out.push_back(std::move(f));
        }

        av_frame_unref(impl_->frame);
    }

    return out;
}
