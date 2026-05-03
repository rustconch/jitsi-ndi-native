#include <napi.h>

#include <cstdint>
#include <memory>
#include <string>

#include "ndi_sender.h"

using salutejazz_ndi::NdiSender;

// FourCC tags exposed to JS as a constants object. JS code converts
// VideoFrame.format string ("NV12", "I420", "RGBA"...) to one of these values
// before calling sendVideo.
namespace {

uint32_t MakeFourCC(char a, char b, char c, char d) {
    return  (uint32_t(a))
          | (uint32_t(b) << 8)
          | (uint32_t(c) << 16)
          | (uint32_t(d) << 24);
}

void Finalizer(Napi::Env, NdiSender* sender) {
    delete sender;
}

Napi::Value CreateSender(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    if (info.Length() < 1 || !info[0].IsString()) {
        Napi::TypeError::New(env, "createSender(name, options?) requires string name")
            .ThrowAsJavaScriptException();
        return env.Null();
    }
    std::string name = info[0].As<Napi::String>().Utf8Value();

    bool clockVideo = true;
    bool clockAudio = false;
    if (info.Length() >= 2 && info[1].IsObject()) {
        Napi::Object opts = info[1].As<Napi::Object>();
        if (opts.Has("clockVideo")) clockVideo = opts.Get("clockVideo").ToBoolean();
        if (opts.Has("clockAudio")) clockAudio = opts.Get("clockAudio").ToBoolean();
    }

    auto sender = std::make_unique<NdiSender>(name, clockVideo, clockAudio);
    if (!sender->IsValid()) {
        Napi::Error::New(env, "Failed to create NDI sender — check NDI runtime/SDK installation")
            .ThrowAsJavaScriptException();
        return env.Null();
    }

    NdiSender* raw = sender.release();
    return Napi::External<NdiSender>::New(env, raw, Finalizer);
}

// Releases the NDI side immediately (NDIlib_send_destroy) but leaves the
// JS-owned wrapper object intact. The Finalizer (Finalizer above) is the sole
// owner of the heap object — it will free it when V8 GCs the External handle.
Napi::Value DestroySender(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    if (info.Length() < 1 || !info[0].IsExternal()) {
        Napi::TypeError::New(env, "destroySender(handle) requires external handle")
            .ThrowAsJavaScriptException();
        return env.Undefined();
    }
    auto ext = info[0].As<Napi::External<NdiSender>>();
    NdiSender* sender = ext.Data();
    if (sender) sender->Reset();
    return env.Undefined();
}

// sendVideo(handle, buffer, width, height, strideOrSize, fourCC, fpsN, fpsD, timecode?)
Napi::Value SendVideo(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    if (info.Length() < 8) {
        Napi::TypeError::New(env, "sendVideo: expected 8+ args")
            .ThrowAsJavaScriptException();
        return env.Undefined();
    }
    auto ext = info[0].As<Napi::External<NdiSender>>();
    NdiSender* sender = ext.Data();
    if (!sender) {
        return Napi::Boolean::New(env, false);
    }

    const uint8_t* data = nullptr;
    size_t dataSize = 0;

    if (info[1].IsTypedArray()) {
        auto ta = info[1].As<Napi::Uint8Array>();
        data = ta.Data();
        dataSize = ta.ByteLength();
    } else if (info[1].IsBuffer()) {
        auto buf = info[1].As<Napi::Buffer<uint8_t>>();
        data = buf.Data();
        dataSize = buf.Length();
    } else {
        Napi::TypeError::New(env, "sendVideo: arg[1] must be Buffer or Uint8Array")
            .ThrowAsJavaScriptException();
        return Napi::Boolean::New(env, false);
    }

    int width      = info[2].As<Napi::Number>().Int32Value();
    int height     = info[3].As<Napi::Number>().Int32Value();
    int strideOrSz = info[4].As<Napi::Number>().Int32Value();
    uint32_t fcc   = info[5].As<Napi::Number>().Uint32Value();
    int fpsN       = info[6].As<Napi::Number>().Int32Value();
    int fpsD       = info[7].As<Napi::Number>().Int32Value();
    int64_t tc     = (info.Length() >= 9 && info[8].IsNumber())
                     ? info[8].As<Napi::Number>().Int64Value() : 0;

    bool ok = sender->SendVideo(data, dataSize, width, height, strideOrSz, fcc, fpsN, fpsD, tc);
    return Napi::Boolean::New(env, ok);
}

// sendAudio(handle, planarFloat32, sampleRate, numChannels, numSamples, channelStrideBytes?, timecode?)
Napi::Value SendAudio(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    if (info.Length() < 5) {
        Napi::TypeError::New(env, "sendAudio: expected 5+ args")
            .ThrowAsJavaScriptException();
        return env.Undefined();
    }
    auto ext = info[0].As<Napi::External<NdiSender>>();
    NdiSender* sender = ext.Data();
    if (!sender) return Napi::Boolean::New(env, false);

    const float* data = nullptr;
    if (info[1].IsTypedArray()) {
        auto ta = info[1].As<Napi::Float32Array>();
        data = ta.Data();
    } else if (info[1].IsBuffer()) {
        auto buf = info[1].As<Napi::Buffer<float>>();
        data = buf.Data();
    } else {
        Napi::TypeError::New(env, "sendAudio: arg[1] must be Float32Array or Buffer<float>")
            .ThrowAsJavaScriptException();
        return Napi::Boolean::New(env, false);
    }

    int sampleRate = info[2].As<Napi::Number>().Int32Value();
    int numChannels = info[3].As<Napi::Number>().Int32Value();
    int numSamples = info[4].As<Napi::Number>().Int32Value();
    int chStride = (info.Length() >= 6 && info[5].IsNumber())
                   ? info[5].As<Napi::Number>().Int32Value() : 0;
    int64_t tc   = (info.Length() >= 7 && info[6].IsNumber())
                   ? info[6].As<Napi::Number>().Int64Value() : 0;

    bool ok = sender->SendAudio(data, sampleRate, numChannels, numSamples, chStride, tc);
    return Napi::Boolean::New(env, ok);
}

Napi::Object Init(Napi::Env env, Napi::Object exports) {
    exports.Set("createSender", Napi::Function::New(env, CreateSender));
    exports.Set("destroySender", Napi::Function::New(env, DestroySender));
    exports.Set("sendVideo", Napi::Function::New(env, SendVideo));
    exports.Set("sendAudio", Napi::Function::New(env, SendAudio));

    Napi::Object fourCCs = Napi::Object::New(env);
    fourCCs.Set("NV12", Napi::Number::New(env, MakeFourCC('N','V','1','2')));
    fourCCs.Set("I420", Napi::Number::New(env, MakeFourCC('I','4','2','0')));
    fourCCs.Set("YV12", Napi::Number::New(env, MakeFourCC('Y','V','1','2')));
    fourCCs.Set("UYVY", Napi::Number::New(env, MakeFourCC('U','Y','V','Y')));
    fourCCs.Set("BGRA", Napi::Number::New(env, MakeFourCC('B','G','R','A')));
    fourCCs.Set("BGRX", Napi::Number::New(env, MakeFourCC('B','G','R','X')));
    fourCCs.Set("RGBA", Napi::Number::New(env, MakeFourCC('R','G','B','A')));
    fourCCs.Set("RGBX", Napi::Number::New(env, MakeFourCC('R','G','B','X')));
    exports.Set("FourCC", fourCCs);

    return exports;
}

NODE_API_MODULE(salutejazz_ndi_bridge, Init)

} // namespace
