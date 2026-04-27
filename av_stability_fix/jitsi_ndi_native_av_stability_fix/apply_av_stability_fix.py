#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AV/audio stability patch for jitsi-ndi-native.

Fixes attempted:
  1) Replaces Av1RtpFrameAssembler with a reorder-safe assembler.
  2) Adds SSRC->Jitsi endpoint registry so video ssrc-* sources can be resolved to d277e069-style endpoints.
  3) Tries to force NDI audio v3 into planar float just before NDIlib_send_send_audio_v3.
"""
from __future__ import annotations

import datetime
import re
import shutil
import sys
from pathlib import Path

ROOT = Path.cwd()
SRC = ROOT / "src"
BACKUP = ROOT / ("av_stability_backup_" + datetime.datetime.now().strftime("%Y%m%d_%H%M%S"))


def info(msg: str) -> None:
    print(f"[AV STABILITY PATCH] {msg}")


def warn(msg: str) -> None:
    print(f"[AV STABILITY PATCH] WARN: {msg}")


def die(msg: str) -> None:
    print(f"[AV STABILITY PATCH] ERROR: {msg}")
    sys.exit(1)


def read(p: Path) -> str:
    return p.read_text(encoding="utf-8", errors="replace")


def write(p: Path, s: str) -> None:
    p.write_text(s, encoding="utf-8", newline="")


def backup(p: Path) -> None:
    if not p.exists():
        return
    rel = p.relative_to(ROOT)
    dst = BACKUP / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(p, dst)


def ensure_include(text: str, include_line: str) -> str:
    if include_line in text:
        return text
    lines = text.splitlines(True)
    insert_at = 0
    for i, line in enumerate(lines):
        if line.startswith("#include"):
            insert_at = i + 1
    lines.insert(insert_at, include_line + "\n")
    return "".join(lines)


def detect_encoded_video_fields() -> tuple[str, str | None, str | None]:
    h = SRC / "Vp8RtpDepacketizer.h"
    if not h.exists():
        warn("src/Vp8RtpDepacketizer.h not found; assuming EncodedVideoFrame.payload/timestamp/keyFrame")
        return ("payload", "timestamp", "keyFrame")

    t = read(h)
    m = re.search(r"struct\s+EncodedVideoFrame\s*\{(?P<body>.*?)\};", t, re.S)
    if not m:
        warn("Could not parse EncodedVideoFrame; assuming payload/timestamp/keyFrame")
        return ("payload", "timestamp", "keyFrame")

    body = m.group("body")
    vector_fields = re.findall(r"std::vector\s*<\s*(?:std::)?uint8_t\s*>\s+([A-Za-z_]\w*)", body)
    payload_field = None
    for name in ["payload", "bytes", "buffer", "data", "encoded", "frame"]:
        if name in vector_fields:
            payload_field = name
            break
    if payload_field is None and vector_fields:
        payload_field = vector_fields[0]
    if payload_field is None:
        warn("No std::vector<uint8_t> field found in EncodedVideoFrame; using payload")
        payload_field = "payload"

    ts_field = None
    for name in ["timestamp", "rtpTimestamp", "timestamp90k", "pts", "pts90k"]:
        if re.search(r"\b" + re.escape(name) + r"\b", body):
            ts_field = name
            break

    key_field = None
    for name in ["keyFrame", "isKeyFrame", "keyframe", "is_keyframe"]:
        if re.search(r"\b" + re.escape(name) + r"\b", body):
            key_field = name
            break

    info(f"Detected EncodedVideoFrame fields: payload={payload_field}, timestamp={ts_field}, keyframe={key_field}")
    return (payload_field, ts_field, key_field)


def make_av1_header() -> str:
    return r'''#pragma once

#include "Vp8RtpDepacketizer.h"

#include <cstddef>
#include <cstdint>
#include <map>
#include <vector>

class Av1RtpFrameAssembler {
public:
    std::vector<EncodedVideoFrame> pushRtp(const uint8_t* data, size_t size);
    std::vector<EncodedVideoFrame> pushRtp(const std::vector<uint8_t>& packet) {
        return pushRtp(packet.data(), packet.size());
    }

    // Compatibility aliases for older call sites.
    std::vector<EncodedVideoFrame> depacketize(const uint8_t* data, size_t size) {
        return pushRtp(data, size);
    }
    std::vector<EncodedVideoFrame> depacketize(const std::vector<uint8_t>& packet) {
        return pushRtp(packet);
    }

    uint64_t producedFrames() const { return producedFrames_; }
    uint64_t sequenceGaps() const { return sequenceGaps_; }

    void reset();

private:
    struct RtpPacket {
        uint16_t sequence = 0;
        uint32_t timestamp = 0;
        bool marker = false;
        std::vector<uint8_t> payload;
    };

    std::vector<EncodedVideoFrame> drainReorderBuffer();
    std::vector<EncodedVideoFrame> processOrderedPacket(const RtpPacket& packet);

    bool parseRtp(const uint8_t* data, size_t size, RtpPacket& out);
    bool appendAv1Payload(const uint8_t* data, size_t size, uint32_t timestamp, bool marker, std::vector<EncodedVideoFrame>& out);
    bool readLeb128(const uint8_t* data, size_t size, size_t& pos, size_t& value);
    void markCorruptUntilMarker();
    void clearCurrentFrameState();

    static uint16_t nextSeq(uint16_t v) { return static_cast<uint16_t>(v + 1); }

    std::map<uint16_t, RtpPacket> reorder_;
    bool haveExpectedSeq_ = false;
    uint16_t expectedSeq_ = 0;

    std::vector<uint8_t> currentFrame_;
    std::vector<uint8_t> continuationObu_;

    bool waitingContinuation_ = false;
    bool corruptFrame_ = false;
    bool haveFrameTimestamp_ = false;
    uint32_t frameTimestamp_ = 0;
    bool currentFrameKey_ = false;

    uint64_t producedFrames_ = 0;
    uint64_t sequenceGaps_ = 0;
};
'''


def make_av1_cpp(payload_field: str, ts_field: str | None, key_field: str | None) -> str:
    ts_set = f"    frame.{ts_field} = timestamp;\n" if ts_field else ""
    key_set = f"    frame.{key_field} = currentFrameKey_;\n" if key_field else ""
    return f'''#include "Av1RtpFrameAssembler.h"

#include <algorithm>
#include <cstring>

namespace {{

constexpr size_t kMaxReorderPackets = 8;
constexpr uint8_t kAv1Z = 0x80;
constexpr uint8_t kAv1Y = 0x40;
constexpr uint8_t kAv1WMask = 0x30;
constexpr uint8_t kAv1N = 0x08;

}} // namespace

void Av1RtpFrameAssembler::reset() {{
    reorder_.clear();
    haveExpectedSeq_ = false;
    expectedSeq_ = 0;
    clearCurrentFrameState();
    sequenceGaps_ = 0;
}}

void Av1RtpFrameAssembler::clearCurrentFrameState() {{
    currentFrame_.clear();
    continuationObu_.clear();
    waitingContinuation_ = false;
    corruptFrame_ = false;
    haveFrameTimestamp_ = false;
    frameTimestamp_ = 0;
    currentFrameKey_ = false;
}}

void Av1RtpFrameAssembler::markCorruptUntilMarker() {{
    currentFrame_.clear();
    continuationObu_.clear();
    waitingContinuation_ = false;
    corruptFrame_ = true;
}}

bool Av1RtpFrameAssembler::parseRtp(const uint8_t* data, size_t size, RtpPacket& out) {{
    if (!data || size < 12) return false;
    const uint8_t vpxcc = data[0];
    if ((vpxcc >> 6) != 2) return false;
    const bool extension = (vpxcc & 0x10) != 0;
    const uint8_t csrcCount = static_cast<uint8_t>(vpxcc & 0x0F);
    size_t pos = 12 + static_cast<size_t>(csrcCount) * 4;
    if (pos > size) return false;

    out.marker = (data[1] & 0x80) != 0;
    out.sequence = static_cast<uint16_t>((static_cast<uint16_t>(data[2]) << 8) | data[3]);
    out.timestamp =
        (static_cast<uint32_t>(data[4]) << 24) |
        (static_cast<uint32_t>(data[5]) << 16) |
        (static_cast<uint32_t>(data[6]) << 8) |
        static_cast<uint32_t>(data[7]);

    if (extension) {{
        if (pos + 4 > size) return false;
        const uint16_t extLenWords = static_cast<uint16_t>((static_cast<uint16_t>(data[pos + 2]) << 8) | data[pos + 3]);
        pos += 4 + static_cast<size_t>(extLenWords) * 4;
        if (pos > size) return false;
    }}

    out.payload.assign(data + pos, data + size);
    return !out.payload.empty();
}}

std::vector<EncodedVideoFrame> Av1RtpFrameAssembler::pushRtp(const uint8_t* data, size_t size) {{
    RtpPacket packet;
    if (!parseRtp(data, size, packet)) return {{}};

    if (!haveExpectedSeq_) {{
        haveExpectedSeq_ = true;
        expectedSeq_ = packet.sequence;
    }}

    if (reorder_.find(packet.sequence) != reorder_.end()) return {{}};
    reorder_.emplace(packet.sequence, std::move(packet));
    return drainReorderBuffer();
}}

std::vector<EncodedVideoFrame> Av1RtpFrameAssembler::drainReorderBuffer() {{
    std::vector<EncodedVideoFrame> out;
    while (!reorder_.empty()) {{
        auto it = reorder_.find(expectedSeq_);
        if (it == reorder_.end()) {{
            if (reorder_.size() < kMaxReorderPackets) break;
            ++sequenceGaps_;
            markCorruptUntilMarker();
            expectedSeq_ = reorder_.begin()->first;
            it = reorder_.find(expectedSeq_);
            if (it == reorder_.end()) break;
        }}

        RtpPacket packet = std::move(it->second);
        reorder_.erase(it);
        expectedSeq_ = nextSeq(packet.sequence);
        auto frames = processOrderedPacket(packet);
        out.insert(out.end(), frames.begin(), frames.end());
    }}
    return out;
}}

std::vector<EncodedVideoFrame> Av1RtpFrameAssembler::processOrderedPacket(const RtpPacket& packet) {{
    std::vector<EncodedVideoFrame> out;
    appendAv1Payload(packet.payload.data(), packet.payload.size(), packet.timestamp, packet.marker, out);
    return out;
}}

bool Av1RtpFrameAssembler::readLeb128(const uint8_t* data, size_t size, size_t& pos, size_t& value) {{
    value = 0;
    unsigned shift = 0;
    while (pos < size && shift <= 28) {{
        const uint8_t byte = data[pos++];
        value |= static_cast<size_t>(byte & 0x7F) << shift;
        if ((byte & 0x80) == 0) return true;
        shift += 7;
    }}
    return false;
}}

bool Av1RtpFrameAssembler::appendAv1Payload(const uint8_t* data, size_t size, uint32_t timestamp, bool marker, std::vector<EncodedVideoFrame>& out) {{
    if (!data || size < 1) return false;

    if (haveFrameTimestamp_ && timestamp != frameTimestamp_) {{
        clearCurrentFrameState();
    }}
    if (!haveFrameTimestamp_) {{
        haveFrameTimestamp_ = true;
        frameTimestamp_ = timestamp;
    }}

    if (corruptFrame_) {{
        if (marker) clearCurrentFrameState();
        return false;
    }}

    const uint8_t aggr = data[0];
    const bool z = (aggr & kAv1Z) != 0;
    const bool y = (aggr & kAv1Y) != 0;
    const uint8_t w = static_cast<uint8_t>((aggr & kAv1WMask) >> 4);
    const bool n = (aggr & kAv1N) != 0;
    if (n) currentFrameKey_ = true;

    size_t pos = 1;
    size_t elementIndex = 0;

    if (z && !waitingContinuation_) {{
        markCorruptUntilMarker();
        if (marker) clearCurrentFrameState();
        return false;
    }}

    while (pos < size) {{
        ++elementIndex;
        size_t obuLen = 0;
        const bool lastElement = (w != 0 && elementIndex == static_cast<size_t>(w));

        if (w != 0 && lastElement) {{
            obuLen = size - pos;
        }} else {{
            if (!readLeb128(data, size, pos, obuLen)) {{ markCorruptUntilMarker(); return false; }}
            if (obuLen > size - pos) {{ markCorruptUntilMarker(); return false; }}
        }}

        const uint8_t* obuData = data + pos;
        pos += obuLen;
        const bool thisElementContinues = y && (pos >= size);

        if ((z && elementIndex == 1) || waitingContinuation_) {{
            continuationObu_.insert(continuationObu_.end(), obuData, obuData + obuLen);
            if (!thisElementContinues) {{
                currentFrame_.insert(currentFrame_.end(), continuationObu_.begin(), continuationObu_.end());
                continuationObu_.clear();
                waitingContinuation_ = false;
            }} else {{
                waitingContinuation_ = true;
            }}
        }} else {{
            if (thisElementContinues) {{
                continuationObu_.assign(obuData, obuData + obuLen);
                waitingContinuation_ = true;
            }} else {{
                currentFrame_.insert(currentFrame_.end(), obuData, obuData + obuLen);
            }}
        }}

        if (w != 0 && elementIndex >= static_cast<size_t>(w)) break;
    }}

    if (marker) {{
        if (!waitingContinuation_ && !currentFrame_.empty() && !corruptFrame_) {{
            EncodedVideoFrame frame{{}};
            frame.{payload_field} = std::move(currentFrame_);
{ts_set}{key_set}            out.push_back(std::move(frame));
            ++producedFrames_;
        }}
        clearCurrentFrameState();
    }}
    return true;
}}
'''


def write_av1_assembler() -> None:
    payload_field, ts_field, key_field = detect_encoded_video_fields()
    h = SRC / "Av1RtpFrameAssembler.h"
    cpp = SRC / "Av1RtpFrameAssembler.cpp"
    backup(h); backup(cpp)
    write(h, make_av1_header())
    write(cpp, make_av1_cpp(payload_field, ts_field, key_field))
    info("replaced src/Av1RtpFrameAssembler.h/.cpp with reorder-safe assembler")


def write_registry_header() -> None:
    h = SRC / "RtpSourceRegistry.h"
    if h.exists() and "AV_STABILITY_RTP_SOURCE_REGISTRY" in read(h):
        info("RtpSourceRegistry.h already present")
        return
    backup(h)
    write(h, r'''#pragma once
// AV_STABILITY_RTP_SOURCE_REGISTRY

#include <cstdint>
#include <mutex>
#include <regex>
#include <string>
#include <unordered_map>

namespace RtpSourceRegistry {

struct SourceInfo { std::string owner; std::string name; };

inline std::mutex& mutexRef() { static std::mutex m; return m; }
inline std::unordered_map<uint32_t, SourceInfo>& mapRef() { static std::unordered_map<uint32_t, SourceInfo> m; return m; }

inline std::string ownerFromSourceName(const std::string& name) {
    const auto dash = name.find('-');
    if (dash != std::string::npos && dash > 0) return name.substr(0, dash);
    return {};
}

inline void setSsrcOwner(uint32_t ssrc, const std::string& owner, const std::string& name = std::string()) {
    if (ssrc == 0) return;
    std::string resolved = owner;
    if (resolved.empty() || resolved == "jvb") {
        const std::string fromName = ownerFromSourceName(name);
        if (!fromName.empty() && fromName != "jvb") resolved = fromName;
    }
    if (resolved.empty() || resolved == "jvb") return;
    std::lock_guard<std::mutex> lock(mutexRef());
    mapRef()[ssrc] = SourceInfo{resolved, name};
}

inline std::string ownerForSsrc(uint32_t ssrc, const std::string& fallback) {
    std::lock_guard<std::mutex> lock(mutexRef());
    const auto it = mapRef().find(ssrc);
    if (it == mapRef().end() || it->second.owner.empty()) return fallback;
    return it->second.owner;
}

inline void registerFromSdp(const std::string& sdp) {
    static const std::regex msidRe(R"(a=ssrc:([0-9]+)\s+msid:([A-Za-z0-9]+)-(?:audio|video)-[^\r\n\s]*)", std::regex::icase);
    auto begin = std::sregex_iterator(sdp.begin(), sdp.end(), msidRe);
    auto end = std::sregex_iterator();
    for (auto it = begin; it != end; ++it) {
        const uint32_t ssrc = static_cast<uint32_t>(std::stoull((*it)[1].str()));
        const std::string owner = (*it)[2].str();
        setSsrcOwner(ssrc, owner, owner);
    }
}

} // namespace RtpSourceRegistry
''')
    info("added src/RtpSourceRegistry.h")


def patch_jingle_source_registration() -> None:
    p = SRC / "JingleSession.cpp"
    if not p.exists():
        warn("JingleSession.cpp not found; skipping Jingle SSRC registry patch")
        return
    t = read(p)
    if "RtpSourceRegistry.h" not in t:
        t = ensure_include(t, '#include "RtpSourceRegistry.h"')
    if "AV_STABILITY_REGISTER_JINGLE_SSRC" in t:
        write(p, t); info("JingleSession.cpp already has SSRC registry patch"); return

    patched = False
    def repl(m: re.Match) -> str:
        nonlocal patched
        var = m.group(2)
        patched = True
        return (m.group(1) + f'\n        // AV_STABILITY_REGISTER_JINGLE_SSRC\n'
                f'        RtpSourceRegistry::setSsrcOwner(static_cast<uint32_t>({var}.ssrc), {var}.owner, {var}.name);')

    for pat in [
        r'(for\s*\(\s*const\s+auto\s*&\s+([A-Za-z_]\w*)\s*:\s*([A-Za-z_]\w*)\.sources\s*\)\s*\{)',
        r'(for\s*\(\s*auto\s+const\s*&\s+([A-Za-z_]\w*)\s*:\s*([A-Za-z_]\w*)\.sources\s*\)\s*\{)',
    ]:
        if re.search(pat, t):
            t = re.sub(pat, repl, t, count=1)
            break

    backup(p); write(p, t)
    if patched: info("patched JingleSession.cpp to register Jingle SSRC -> owner/name map")
    else: warn("Could not auto-insert Jingle SSRC registration. Will rely on SDP registration if available.")


def patch_native_sdp_registration() -> None:
    p = SRC / "NativeWebRTCAnswerer.cpp"
    if not p.exists():
        warn("NativeWebRTCAnswerer.cpp not found; skipping SDP registry patch")
        return
    t = read(p)
    if "RtpSourceRegistry.h" not in t:
        t = ensure_include(t, '#include "RtpSourceRegistry.h"')
    if "AV_STABILITY_REGISTER_SDP_SSRC" in t:
        write(p, t); info("NativeWebRTCAnswerer.cpp already has SDP registry patch"); return

    pat = r'((?:[A-Za-z_]\w*(?:->|\.)\s*)?setRemoteDescription\s*\(\s*rtc::Description\s*\(\s*([A-Za-z_]\w*)\s*,)'
    m = re.search(pat, t)
    if m:
        var = m.group(2)
        insert = f'RtpSourceRegistry::registerFromSdp({var}); // AV_STABILITY_REGISTER_SDP_SSRC\n    '
        t = t[:m.start()] + insert + t[m.start():]
        backup(p); write(p, t)
        info(f"patched NativeWebRTCAnswerer.cpp to register SSRC map from SDP variable '{var}'")
        return

    pat2 = r'(rtc::Description\s+([A-Za-z_]\w*)\s*\(\s*([A-Za-z_]\w*)\s*,\s*(?:"offer"|rtc::Description::Type::Offer)[^;]*;)'
    m = re.search(pat2, t)
    if m:
        var = m.group(3)
        insert = m.group(1) + f'\n    RtpSourceRegistry::registerFromSdp({var}); // AV_STABILITY_REGISTER_SDP_SSRC'
        t = t[:m.start()] + insert + t[m.end():]
        backup(p); write(p, t)
        info(f"patched NativeWebRTCAnswerer.cpp to register SSRC map from SDP variable '{var}'")
        return

    backup(p); write(p, t)
    warn("Could not find remote SDP setRemoteDescription pattern. SSRC owner mapping may still work via Jingle patch.")


def patch_ssrc_endpoint_resolution() -> None:
    targets = [SRC / "PerParticipantNdiRouter.cpp", SRC / "NativeWebRTCAnswerer.cpp"]
    total = 0
    for p in targets:
        if not p.exists(): continue
        t = read(p); original = t
        if "RtpSourceRegistry.h" not in t:
            t = ensure_include(t, '#include "RtpSourceRegistry.h"')

        def replace_plain(m: re.Match) -> str:
            expr = m.group(1).strip()
            if "RtpSourceRegistry" in expr:
                return m.group(0)
            return f'RtpSourceRegistry::ownerForSsrc(static_cast<uint32_t>({expr}), std::string("ssrc-") + std::to_string({expr}))'

        t = re.sub(r'"ssrc-"\s*\+\s*std::to_string\s*\(\s*([A-Za-z_][A-Za-z0-9_\.>\-]*)\s*\)', replace_plain, t)
        t = re.sub(r'std::string\s*\(\s*"ssrc-"\s*\)\s*\+\s*std::to_string\s*\(\s*([A-Za-z_][A-Za-z0-9_\.>\-]*)\s*\)', replace_plain, t)

        if t != original:
            backup(p); write(p, t)
            total += max(0, t.count("ownerForSsrc") - original.count("ownerForSsrc"))
            info(f"patched SSRC endpoint fallback in {p.name}")
    if total == 0:
        warn("Did not find SSRC fallback expressions to patch. If video still appears as ssrc-* source, send PerParticipantNdiRouter.cpp and NativeWebRTCAnswerer.cpp.")


def patch_ndi_audio_planar() -> None:
    patched_files = 0
    for p in SRC.glob("*.cpp"):
        t = read(p)
        if "NDIlib_send_send_audio_v3" not in t or "NDIlib_audio_frame_v3_t" not in t:
            continue
        if "AV_STABILITY_AUDIO_PLANAR_FIX" in t:
            continue
        original = t
        t = ensure_include(t, "#include <vector>")
        m = re.search(r'(NDIlib_send_send_audio_v3\s*\(\s*[^,]+,\s*&\s*([A-Za-z_]\w*)\s*\)\s*;)', t)
        if not m:
            warn(f"{p.name}: found NDI audio v3 usage but could not identify send call variable")
            continue
        frame_var = m.group(2)
        block = f'''
    // AV_STABILITY_AUDIO_PLANAR_FIX
    // NDI audio v3 uses planar float. Convert common interleaved FLT to planar FLTP.
    std::vector<float> ndiPlanarAudio;
    if ({frame_var}.p_data && {frame_var}.no_channels > 1 && {frame_var}.no_samples > 0) {{
        const int ndiChannels = {frame_var}.no_channels;
        const int ndiSamples = {frame_var}.no_samples;
        const float* interleaved = {frame_var}.p_data;
        ndiPlanarAudio.resize(static_cast<size_t>(ndiChannels) * static_cast<size_t>(ndiSamples));
        for (int s = 0; s < ndiSamples; ++s) {{
            for (int c = 0; c < ndiChannels; ++c) {{
                float v = interleaved[static_cast<size_t>(s) * static_cast<size_t>(ndiChannels) + static_cast<size_t>(c)];
                if (v > 1.0f) v = 1.0f;
                if (v < -1.0f) v = -1.0f;
                ndiPlanarAudio[static_cast<size_t>(c) * static_cast<size_t>(ndiSamples) + static_cast<size_t>(s)] = v;
            }}
        }}
        {frame_var}.p_data = ndiPlanarAudio.data();
        {frame_var}.FourCC = NDIlib_FourCC_audio_type_FLTP;
        {frame_var}.channel_stride_in_bytes = sizeof(float) * ndiSamples;
    }}
'''
        t = t[:m.start()] + block + "\n    " + t[m.start():]
        backup(p); write(p, t)
        patched_files += 1
        info(f"patched {p.name}: force NDI audio v3 planar float before send")
    if patched_files == 0:
        warn("No NDIlib_send_send_audio_v3 call patched. If audio remains distorted, send the NDI sender .cpp file.")


def main() -> None:
    if not SRC.exists():
        die(r"Run this from the project root, e.g. D:\MEDIA\Desktop\jitsi-ndi-native")
    info(f"project root: {ROOT}")
    BACKUP.mkdir(parents=True, exist_ok=True)
    write_registry_header()
    write_av1_assembler()
    patch_jingle_source_registration()
    patch_native_sdp_registration()
    patch_ssrc_endpoint_resolution()
    patch_ndi_audio_planar()
    info(f"backup written to: {BACKUP}")
    info("done")
    info("now build:")
    info("    cmake --build build --config Release")


if __name__ == "__main__":
    main()
